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

const (
	pluginID           = "org.relaychat.calls"
	contractVersion    = 2
	defaultRingTimeout = 45
)

// configuration comes from the plugin settings. When LiveKitAPISecret is empty there, the whole secret file
// (RELAY_CALLS_CONFIG_FILE, default /opt/relay-calls/plugin-config.json) is applied over it, as in version 1;
// otherwise only the APNs keys are taken from that file.
type configuration struct {
	LiveKitURL         string
	LiveKitInternalURL string
	LiveKitAPIKey      string
	LiveKitAPISecret   string
	MaxParticipants    int
	AnnounceCalls      bool
	RingTimeoutSeconds int
	APNsKeyID          string
	APNsTeamID         string
	APNsKeyPath        string
	APNsBaseURL        string
}

type joinResponse struct {
	URL   string   `json:"url"`
	Token string   `json:"token"`
	Call  callView `json:"call"`
}

type callInput struct {
	CallID      string `json:"call_id"`
	DeviceID    string `json:"device_id"`
	Video       bool   `json:"video"`
	Reason      string `json:"reason"`
	Token       string `json:"token"`
	Environment string `json:"environment"`
	BundleID    string `json:"bundle_id"`
}

type Plugin struct {
	plugin.MattermostPlugin

	// mu serializes every call operation (single-node deployment).
	mu     sync.Mutex
	config configuration
	client *http.Client

	now           func() time.Time
	sweepEvery    time.Duration
	sweepStop     chan struct{}
	sweepDone     chan struct{}
	lastReconcile time.Time
	index         *callIndex

	voip       *apnsSender
	apnsClient *http.Client
	voipLogged bool

	// pushMu guards the push hook's state; the hook never takes mu.
	pushMu         sync.Mutex
	recordChannels map[string]int64
	allowedPushes  map[string]int64

	pending sync.WaitGroup
}

func main() { plugin.ClientMain(&Plugin{}) }

func (p *Plugin) OnActivate() error {
	if p.client == nil {
		p.client = &http.Client{Timeout: 15 * time.Second}
	}
	if err := p.OnConfigurationChange(); err != nil {
		return err
	}
	p.mu.Lock()
	p.index = nil
	if _, err := p.loadIndex(); err != nil {
		p.API.LogWarn("Could not load the Relay Calls index", "error", err.Error())
	}
	p.mu.Unlock()
	p.startSweeper()
	return nil
}

func (p *Plugin) OnDeactivate() error {
	p.stopSweeper()
	p.pending.Wait()
	return nil
}

func (p *Plugin) OnConfigurationChange() error {
	var c configuration
	if err := p.API.LoadPluginConfiguration(&c); err != nil {
		return err
	}
	path := os.Getenv("RELAY_CALLS_CONFIG_FILE")
	if path == "" {
		path = "/opt/relay-calls/plugin-config.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if !os.IsNotExist(err) && c.LiveKitAPISecret == "" {
			return errors.New("could not read Relay Calls configuration file")
		}
		data = nil
	}
	if len(data) > 0 {
		if c.LiveKitAPISecret == "" {
			if err := json.Unmarshal(data, &c); err != nil {
				return errors.New("invalid Relay Calls configuration file")
			}
		} else if c.APNsKeyPath == "" {
			var file configuration
			if json.Unmarshal(data, &file) == nil {
				c.APNsKeyID, c.APNsTeamID, c.APNsKeyPath = file.APNsKeyID, file.APNsTeamID, file.APNsKeyPath
				if c.APNsBaseURL == "" {
					c.APNsBaseURL = file.APNsBaseURL
				}
			}
		}
	}
	if c.MaxParticipants < 2 {
		c.MaxParticipants = 25
	}
	if c.LiveKitInternalURL == "" {
		c.LiveKitInternalURL = "http://127.0.0.1:7880"
	}
	if c.RingTimeoutSeconds <= 0 {
		c.RingTimeoutSeconds = defaultRingTimeout
	} else if c.RingTimeoutSeconds < 10 {
		c.RingTimeoutSeconds = 10
	} else if c.RingTimeoutSeconds > 300 {
		c.RingTimeoutSeconds = 300
	}
	if c.LiveKitURL != "" {
		u, err := url.Parse(c.LiveKitURL)
		if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "wss") || u.User != nil {
			return errors.New("LiveKitURL must be an HTTPS or WSS URL without credentials")
		}
	}
	p.mu.Lock()
	sender, voipErr := newAPNsSender(c, p.apnsClient)
	p.config = c
	p.voip = sender
	logDisabled := sender == nil && voipErr == nil && !p.voipLogged
	if logDisabled {
		p.voipLogged = true
	}
	p.mu.Unlock()
	if voipErr != nil {
		p.API.LogError("Relay Calls VoIP push is disabled: the APNs key could not be loaded", "error", voipErr.Error())
	} else if logDisabled {
		p.API.LogInfo("Relay Calls VoIP push is disabled: no APNs key is configured")
	}
	return nil
}

func (p *Plugin) ServeHTTP(c *plugin.Context, w http.ResponseWriter, r *http.Request) {
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
	sessionID := ""
	if c != nil {
		sessionID = c.SessionId
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.ready() {
		fail(w, http.StatusServiceUnavailable, "Calling is not configured on this server.")
		return
	}
	parts := strings.Split(strings.Trim(r.URL.Path, "/"), "/")
	switch parts[0] {
	case "config":
		if len(parts) == 1 && r.Method == http.MethodGet {
			writeJSON(w, map[string]any{
				"enabled": true, "version": contractVersion, "max_participants": p.config.MaxParticipants,
				"screen_sharing": true, "camera": true, "ringing": true, "ring_timeout_seconds": p.config.RingTimeoutSeconds,
			})
			return
		}
	case "channels":
		p.serveChannel(w, r, userID, parts)
		return
	case "calls":
		p.serveCall(w, r, userID, parts)
		return
	case "devices":
		p.serveDevices(w, r, userID, sessionID, parts)
		return
	}
	fail(w, http.StatusNotFound, "Unknown call endpoint.")
}

func (p *Plugin) ready() bool {
	return p.config.LiveKitURL != "" && p.config.LiveKitAPIKey != "" && p.config.LiveKitAPISecret != ""
}

func (p *Plugin) clock() time.Time {
	if p.now != nil {
		return p.now()
	}
	return time.Now()
}

// goAsync runs outbound pushes off the request path; OnDeactivate and tests wait for them.
func (p *Plugin) goAsync(task func()) {
	p.pending.Add(1)
	go func() {
		defer p.pending.Done()
		task()
	}()
}

func (p *Plugin) UserHasLeftChannel(_ *plugin.Context, member *model.ChannelMember, _ *model.User) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.ready() {
		return
	}
	call, err := p.loadCall(member.ChannelId)
	if err != nil || call == nil || call.State == stateEnded {
		return
	}
	identities, err := p.listIdentities(context.Background(), call.Room)
	if err != nil {
		p.API.LogWarn("Could not refresh call membership", "channel_id", member.ChannelId)
		return
	}
	for _, identity := range identities {
		if strings.HasPrefix(identity, member.UserId+":") {
			if p.roomRequest(context.Background(), "RemoveParticipant", map[string]any{"room": call.Room, "identity": identity}, nil) != nil {
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

func (p *Plugin) activeUser(userID string) (*model.User, bool) {
	user, appErr := p.API.GetUser(userID)
	if appErr != nil || user == nil || user.DeleteAt != 0 {
		return nil, false
	}
	return user, true
}

func displayName(user *model.User) string {
	name := strings.TrimSpace(user.FirstName + " " + user.LastName)
	if name == "" {
		name = user.Username
	}
	return name
}

func (p *Plugin) roomToken(call *callState, user *model.User, deviceID string) (string, error) {
	grant := map[string]any{
		"roomJoin": true, "room": call.Room, "canPublish": true, "canSubscribe": true, "canPublishData": true,
		"canPublishSources": []string{"microphone", "camera", "screen_share", "screen_share_audio"},
	}
	return signToken(p.config.LiveKitAPIKey, p.config.LiveKitAPISecret, user.Id+":"+deviceID, displayName(user), grant, 5*time.Minute, "")
}

func (p *Plugin) writeJoin(w http.ResponseWriter, call *callState, user *model.User, deviceID string, v *viewer) {
	token, err := p.roomToken(call, user, deviceID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "Could not authorize the call.")
		return
	}
	writeJSON(w, joinResponse{URL: p.config.LiveKitURL, Token: token, Call: viewOf(call, v)})
}

// validDeviceID accepts the per-install UUIDs clients send (and similar short tokens).
func validDeviceID(id string) bool {
	if id == "" || len(id) > 64 {
		return false
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_') {
			return false
		}
	}
	return true
}

func decodeInput(w http.ResponseWriter, r *http.Request, input *callInput) bool {
	if r.Body == nil {
		return true
	}
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096))
	if err := decoder.Decode(input); err != nil && err != io.EOF {
		fail(w, http.StatusBadRequest, "Invalid call request.")
		return false
	}
	return true
}

type roomList struct {
	Rooms []struct {
		Name            string `json:"name"`
		NumParticipants int    `json:"num_participants"`
	} `json:"rooms"`
}

// listIdentities returns the room's participant identities in LiveKit's order.
func (p *Plugin) listIdentities(ctx context.Context, room string) ([]string, error) {
	var result struct {
		Participants []struct {
			Identity string `json:"identity"`
		} `json:"participants"`
	}
	if err := p.roomRequest(ctx, "ListParticipants", map[string]any{"room": room}, &result); err != nil {
		return nil, err
	}
	identities := make([]string, 0, len(result.Participants))
	for _, participant := range result.Participants {
		identities = append(identities, participant.Identity)
	}
	return identities, nil
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
	call, err := p.loadCallByRoom(event.Room.Name)
	if err != nil {
		fail(w, http.StatusInternalServerError, "Could not load call.")
		return
	}
	if call != nil && call.State != stateEnded {
		identity := event.Participant.Identity
		switch event.Event {
		case "participant_joined":
			if !p.participantAllowed(call.ChannelID, identity) {
				if err := p.roomRequest(r.Context(), "RemoveParticipant", map[string]any{"room": call.Room, "identity": identity}, nil); err != nil {
					fail(w, http.StatusBadGateway, "Could not enforce call membership.")
					return
				}
			} else {
				p.participantJoined(call, identity)
			}
		case "participant_left":
			p.participantLeft(call, identity)
		case "room_finished":
			p.finishCall(call, roomGoneReason(call), false)
		}
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func writeJSON(w http.ResponseWriter, value any) { _ = json.NewEncoder(w).Encode(value) }
func fail(w http.ResponseWriter, status int, message string) {
	w.WriteHeader(status)
	writeJSON(w, map[string]string{"message": message})
}

func failWithCall(w http.ResponseWriter, status int, message string, call *callState, v *viewer) {
	w.WriteHeader(status)
	writeJSON(w, map[string]any{"message": message, "call": viewOf(call, v)})
}
