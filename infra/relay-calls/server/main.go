package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
)

const pluginID = "org.relaychat.calls"

type configuration struct {
	LiveKitURL         string
	LiveKitInternalURL string
	LiveKitAPIKey      string
	LiveKitAPISecret   string
	MaxParticipants    int
	AnnounceCalls      bool
}

type callState struct {
	ID           string `json:"id"`
	ChannelID    string `json:"channel_id"`
	Room         string `json:"room"`
	StartedBy    string `json:"started_by"`
	StartedAt    int64  `json:"started_at"`
	PostID       string `json:"post_id,omitempty"`
	Participants int    `json:"participants"`
	CanEnd       bool   `json:"can_end"`
}

type joinResponse struct {
	URL   string    `json:"url"`
	Token string    `json:"token"`
	Call  callState `json:"call"`
}

type Plugin struct {
	plugin.MattermostPlugin
	mu     sync.Mutex
	config configuration
	client *http.Client
}

func main() { plugin.ClientMain(&Plugin{}) }

func (p *Plugin) OnActivate() error {
	p.client = &http.Client{Timeout: 15 * time.Second}
	return p.OnConfigurationChange()
}

func (p *Plugin) OnConfigurationChange() error {
	var c configuration
	if err := p.API.LoadPluginConfiguration(&c); err != nil {
		return err
	}
	if c.LiveKitAPISecret == "" {
		path := os.Getenv("RELAY_CALLS_CONFIG_FILE")
		if path == "" {
			path = "/opt/relay-calls/plugin-config.json"
		}
		if data, err := os.ReadFile(path); err == nil {
			if err := json.Unmarshal(data, &c); err != nil {
				return errors.New("invalid Relay Calls configuration file")
			}
		} else if !os.IsNotExist(err) {
			return errors.New("could not read Relay Calls configuration file")
		}
	}
	if c.MaxParticipants < 2 {
		c.MaxParticipants = 25
	}
	if c.LiveKitInternalURL == "" {
		c.LiveKitInternalURL = "http://127.0.0.1:7880"
	}
	if c.LiveKitURL != "" {
		u, err := url.Parse(c.LiveKitURL)
		if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "wss") || u.User != nil {
			return errors.New("LiveKitURL must be an HTTPS or WSS URL without credentials")
		}
	}
	p.mu.Lock()
	p.config = c
	p.mu.Unlock()
	return nil
}

func (p *Plugin) ServeHTTP(_ *plugin.Context, w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.URL.Path == "/webhook" && r.Method == http.MethodPost {
		p.webhook(w, r)
		return
	}
	userID := r.Header.Get("Mattermost-User-Id")
	if !model.IsValidId(userID) {
		fail(w, http.StatusUnauthorized, "Sign in to Mattermost to use calls.")
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.ready() {
		fail(w, http.StatusServiceUnavailable, "Calling is not configured on this server.")
		return
	}
	if r.URL.Path == "/config" && r.Method == http.MethodGet {
		writeJSON(w, map[string]any{"enabled": true, "version": 1, "max_participants": p.config.MaxParticipants, "screen_sharing": true})
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	if len(parts) < 2 || len(parts) > 3 || parts[0] != "channels" || !model.IsValidId(parts[1]) {
		fail(w, http.StatusNotFound, "Unknown call endpoint.")
		return
	}
	channelID := parts[1]
	channel, appErr := p.API.GetChannel(channelID)
	if appErr != nil || channel == nil || channel.DeleteAt != 0 {
		fail(w, http.StatusNotFound, "This channel is unavailable.")
		return
	}
	member, appErr := p.API.GetChannelMember(channelID, userID)
	if appErr != nil || member == nil {
		fail(w, http.StatusForbidden, "Join this channel before joining its call.")
		return
	}
	call, err := p.loadCall(channelID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "Could not load this call.")
		return
	}
	if call != nil {
		if err := p.refreshCall(r.Context(), call); err != nil {
			fail(w, http.StatusBadGateway, "The calling service is temporarily unavailable.")
			return
		}
		if call.ID == "" {
			call = nil
		}
	}
	canEnd := func(c *callState) bool {
		return c != nil && (c.StartedBy == userID || member.SchemeAdmin || p.API.HasPermissionTo(userID, model.PermissionManageSystem))
	}
	if len(parts) == 2 && r.Method == http.MethodGet {
		if call != nil {
			call.CanEnd = canEnd(call)
		}
		writeJSON(w, map[string]any{"call": call})
		return
	}
	if len(parts) != 3 || r.Method != http.MethodPost {
		fail(w, http.StatusMethodNotAllowed, "This call action requires POST.")
		return
	}
	var input struct {
		CallID string `json:"call_id"`
	}
	if r.Body != nil {
		decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
		if err := decoder.Decode(&input); err != nil && err != io.EOF {
			fail(w, http.StatusBadRequest, "Invalid call request.")
			return
		}
	}
	if input.CallID != "" && (call == nil || call.ID != input.CallID) {
		fail(w, http.StatusConflict, "This call has ended. Refresh the channel to join a new call.")
		return
	}
	switch parts[2] {
	case "join":
		user, appErr := p.API.GetUser(userID)
		if appErr != nil || user == nil || user.DeleteAt != 0 {
			fail(w, http.StatusForbidden, "This account is unavailable.")
			return
		}
		if call == nil {
			call = &callState{ID: model.NewId(), ChannelID: channelID, StartedBy: userID, StartedAt: time.Now().UnixMilli()}
			call.Room = "relay_" + call.ID
			if err := p.roomRequest(r.Context(), "CreateRoom", map[string]any{"name": call.Room, "empty_timeout": 120, "departure_timeout": 30, "max_participants": p.config.MaxParticipants, "metadata": channelID}, nil); err != nil {
				fail(w, http.StatusBadGateway, "Could not start the call. Please try again.")
				return
			}
			if err := p.saveCall(call); err != nil {
				_ = p.roomRequest(r.Context(), "DeleteRoom", map[string]any{"room": call.Room}, nil)
				fail(w, http.StatusInternalServerError, "Could not save the call.")
				return
			}
			if p.config.AnnounceCalls {
				post, err := p.API.CreatePost(&model.Post{UserId: userID, ChannelId: channelID, Message: "Started a voice call. Open this conversation in Relay to join.", Props: model.StringInterface{"relay_call": map[string]any{"v": 1, "call_id": call.ID, "channel_id": channelID}}})
				if err == nil {
					call.PostID = post.Id
					_ = p.saveCall(call)
				}
			}
			p.broadcast(call)
		}
		if call.Participants >= p.config.MaxParticipants {
			fail(w, http.StatusConflict, "This call has reached the server's participant limit.")
			return
		}
		name := strings.TrimSpace(user.FirstName + " " + user.LastName)
		if name == "" {
			name = user.Username
		}
		identity := userID + ":" + model.NewId()
		token, err := signToken(p.config.LiveKitAPIKey, p.config.LiveKitAPISecret, identity, name, map[string]any{"roomJoin": true, "room": call.Room, "canPublish": true, "canSubscribe": true, "canPublishData": true, "canPublishSources": []string{"microphone", "screen_share", "screen_share_audio"}}, 5*time.Minute, "")
		if err != nil {
			fail(w, http.StatusInternalServerError, "Could not authorize the call.")
			return
		}
		responseCall := *call
		responseCall.CanEnd = canEnd(call)
		writeJSON(w, joinResponse{URL: p.config.LiveKitURL, Token: token, Call: responseCall})
	case "end":
		if !canEnd(call) {
			fail(w, http.StatusForbidden, "Only the call starter or a channel administrator can end this call.")
			return
		}
		if err := p.roomRequest(r.Context(), "DeleteRoom", map[string]any{"room": call.Room}, nil); err != nil {
			fail(w, http.StatusBadGateway, "Could not end the call. Please try again.")
			return
		}
		p.finishCall(call)
		writeJSON(w, map[string]bool{"ok": true})
	default:
		fail(w, http.StatusNotFound, "Unknown call action.")
	}
}

func (p *Plugin) ready() bool {
	return p.config.LiveKitURL != "" && p.config.LiveKitAPIKey != "" && p.config.LiveKitAPISecret != ""
}

func (p *Plugin) UserHasLeftChannel(_ *plugin.Context, member *model.ChannelMember, _ *model.User) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.ready() {
		return
	}
	call, err := p.loadCall(member.ChannelId)
	if err != nil || call == nil {
		return
	}
	var result struct {
		Participants []struct {
			Identity string `json:"identity"`
		} `json:"participants"`
	}
	if p.roomRequest(context.Background(), "ListParticipants", map[string]any{"room": call.Room}, &result) != nil {
		p.API.LogWarn("Could not refresh call membership", "channel_id", member.ChannelId)
		return
	}
	for _, participant := range result.Participants {
		if strings.HasPrefix(participant.Identity, member.UserId+":") {
			if p.roomRequest(context.Background(), "RemoveParticipant", map[string]any{"room": call.Room, "identity": participant.Identity}, nil) != nil {
				p.API.LogWarn("Could not remove call participant", "channel_id", member.ChannelId)
			}
		}
	}
}

func (p *Plugin) participantAllowed(channelID, identity string) bool {
	userID, _, found := strings.Cut(identity, ":")
	if !found || !model.IsValidId(userID) {
		return false
	}
	user, appErr := p.API.GetUser(userID)
	if appErr != nil || user == nil || user.DeleteAt != 0 {
		return false
	}
	member, appErr := p.API.GetChannelMember(channelID, userID)
	return appErr == nil && member != nil
}

func (p *Plugin) loadCall(channelID string) (*callState, error) {
	data, err := p.API.KVGet("channel:" + channelID)
	if err != nil {
		return nil, err
	}
	if len(data) == 0 {
		return nil, nil
	}
	var call callState
	if err := json.Unmarshal(data, &call); err != nil {
		return nil, err
	}
	return &call, nil
}

func (p *Plugin) saveCall(call *callState) error {
	call.CanEnd = false
	data, err := json.Marshal(call)
	if err != nil {
		return err
	}
	if err := p.API.KVSet("channel:"+call.ChannelID, data); err != nil {
		return err
	}
	if err := p.API.KVSet("room:"+call.Room, []byte(call.ChannelID)); err != nil {
		return err
	}
	return nil
}

func (p *Plugin) refreshCall(ctx context.Context, call *callState) error {
	var result struct {
		Rooms []struct {
			Name            string `json:"name"`
			NumParticipants int    `json:"num_participants"`
		} `json:"rooms"`
	}
	if err := p.roomRequest(ctx, "ListRooms", map[string]any{"names": []string{call.Room}}, &result); err != nil {
		return err
	}
	if len(result.Rooms) == 0 {
		p.finishCall(call)
		call.ID = ""
	} else {
		call.Participants = result.Rooms[0].NumParticipants
	}
	return nil
}

func (p *Plugin) finishCall(call *callState) {
	_ = p.API.KVDelete("channel:" + call.ChannelID)
	_ = p.API.KVDelete("room:" + call.Room)
	p.API.PublishWebSocketEvent("call_ended", map[string]any{"channel_id": call.ChannelID, "call_id": call.ID}, &model.WebsocketBroadcast{ChannelId: call.ChannelID})
}

func (p *Plugin) broadcast(call *callState) {
	value := map[string]any{
		"id": call.ID, "channel_id": call.ChannelID, "room": call.Room,
		"started_by": call.StartedBy, "started_at": call.StartedAt,
		"post_id": call.PostID, "participants": call.Participants, "can_end": false,
	}
	p.API.PublishWebSocketEvent("call_updated", map[string]any{"channel_id": call.ChannelID, "call": value}, &model.WebsocketBroadcast{ChannelId: call.ChannelID})
}

func (p *Plugin) roomRequest(ctx context.Context, method string, body any, result any) error {
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	token, err := signToken(p.config.LiveKitAPIKey, p.config.LiveKitAPISecret, "", "", map[string]any{"roomCreate": true, "roomList": true, "roomAdmin": true, "room": roomName(body)}, time.Minute, "")
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(p.config.LiveKitInternalURL, "/")+"/twirp/livekit.RoomService/"+method, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	response, err := p.client.Do(req)
	if err != nil {
		return errors.New("calling service request failed")
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return fmt.Errorf("calling service returned HTTP %d", response.StatusCode)
	}
	if result != nil {
		return json.NewDecoder(io.LimitReader(response.Body, 1<<20)).Decode(result)
	}
	return nil
}

func roomName(body any) string {
	if fields, ok := body.(map[string]any); ok {
		if room, ok := fields["room"].(string); ok {
			return room
		}
	}
	return ""
}

func signToken(key, secret, identity, name string, grant map[string]any, ttl time.Duration, digest string) (string, error) {
	now := time.Now().Unix()
	claims := map[string]any{"iss": key, "nbf": now - 10, "iat": now, "exp": now + int64(ttl.Seconds())}
	if identity != "" {
		claims["sub"] = identity
	}
	if name != "" {
		claims["name"] = name
	}
	if grant != nil {
		claims["video"] = grant
	}
	if digest != "" {
		claims["sha256"] = digest
	}
	data, err := json.Marshal(claims)
	if err != nil {
		return "", err
	}
	unsigned := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`)) + "." + base64.RawURLEncoding.EncodeToString(data)
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(unsigned))
	return unsigned + "." + base64.RawURLEncoding.EncodeToString(mac.Sum(nil)), nil
}

func verifyWebhook(token string, body []byte, key, secret string) bool {
	parts := strings.Split(strings.TrimPrefix(token, "Bearer "), ".")
	if len(parts) != 3 {
		return false
	}
	header, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil {
		return false
	}
	var alg struct {
		Algorithm string `json:"alg"`
	}
	if json.Unmarshal(header, &alg) != nil || alg.Algorithm != "HS256" {
		return false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(parts[0] + "." + parts[1]))
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || !hmac.Equal(signature, mac.Sum(nil)) {
		return false
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return false
	}
	var claims struct {
		Issuer    string `json:"iss"`
		Expiry    int64  `json:"exp"`
		NotBefore int64  `json:"nbf"`
		Digest    string `json:"sha256"`
	}
	if json.Unmarshal(data, &claims) != nil || claims.Issuer != key || claims.Expiry <= time.Now().Unix() || claims.NotBefore > time.Now().Unix()+10 {
		return false
	}
	digest := sha256.Sum256(body)
	return hmac.Equal([]byte(claims.Digest), []byte(base64.StdEncoding.EncodeToString(digest[:])))
}

func (p *Plugin) webhook(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 1<<20))
	if err != nil {
		fail(w, http.StatusBadRequest, "Invalid webhook.")
		return
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.ready() || !verifyWebhook(r.Header.Get("Authorization"), body, p.config.LiveKitAPIKey, p.config.LiveKitAPISecret) {
		fail(w, http.StatusUnauthorized, "Invalid webhook signature.")
		return
	}
	var event struct {
		Event string `json:"event"`
		Room  struct {
			Name string `json:"name"`
		} `json:"room"`
		Participant struct {
			Identity string `json:"identity"`
		} `json:"participant"`
	}
	if json.Unmarshal(body, &event) != nil {
		fail(w, http.StatusBadRequest, "Invalid webhook.")
		return
	}
	channelID, appErr := p.API.KVGet("room:" + event.Room.Name)
	if appErr != nil {
		fail(w, http.StatusInternalServerError, "Could not load call.")
		return
	}
	if len(channelID) > 0 {
		call, err := p.loadCall(string(channelID))
		if err != nil {
			fail(w, http.StatusInternalServerError, "Could not load call.")
			return
		}
		if call != nil && call.Room == event.Room.Name {
			if event.Event == "participant_joined" && !p.participantAllowed(call.ChannelID, event.Participant.Identity) {
				if err := p.roomRequest(r.Context(), "RemoveParticipant", map[string]any{"room": call.Room, "identity": event.Participant.Identity}, nil); err != nil {
					fail(w, http.StatusBadGateway, "Could not enforce call membership.")
					return
				}
			}
			if event.Event == "room_finished" {
				p.finishCall(call)
			} else {
				p.broadcast(call)
			}
		}
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func writeJSON(w http.ResponseWriter, value any) { _ = json.NewEncoder(w).Encode(value) }
func fail(w http.ResponseWriter, status int, message string) {
	w.WriteHeader(status)
	writeJSON(w, map[string]string{"message": message})
}
