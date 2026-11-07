package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/gob"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
)

type testAPI struct {
	plugin.API
	data   map[string][]byte
	member bool
	events int
}

func (a *testAPI) GetChannel(id string) (*model.Channel, *model.AppError) {
	return &model.Channel{Id: id}, nil
}
func (a *testAPI) GetChannelMember(channel, user string) (*model.ChannelMember, *model.AppError) {
	if !a.member {
		return nil, model.NewAppError("test", "forbidden", nil, "", 403)
	}
	return &model.ChannelMember{ChannelId: channel, UserId: user}, nil
}
func (a *testAPI) GetUser(id string) (*model.User, *model.AppError) {
	return &model.User{Id: id, Username: "tester"}, nil
}
func (a *testAPI) HasPermissionTo(string, *model.Permission) bool { return false }
func (a *testAPI) KVGet(key string) ([]byte, *model.AppError)     { return a.data[key], nil }
func (a *testAPI) KVSet(key string, value []byte) *model.AppError { a.data[key] = value; return nil }
func (a *testAPI) KVDelete(key string) *model.AppError            { delete(a.data, key); return nil }
func (a *testAPI) PublishWebSocketEvent(_ string, value map[string]interface{}, _ *model.WebsocketBroadcast) {
	if err := gob.NewEncoder(&bytes.Buffer{}).Encode(value); err != nil {
		panic(err)
	}
	a.events++
}

func setup(t *testing.T) (*Plugin, *testAPI, *int) {
	t.Helper()
	api := &testAPI{data: map[string][]byte{}, member: true}
	created := 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "), ".")
		if len(parts) != 3 {
			t.Error("missing server authorization")
			w.WriteHeader(401)
			return
		}
		switch {
		case strings.HasSuffix(r.URL.Path, "/CreateRoom"):
			created++
			_, _ = w.Write([]byte(`{}`))
		case strings.HasSuffix(r.URL.Path, "/ListRooms"):
			_, _ = w.Write([]byte(`{"rooms":[{"name":"room","num_participants":2}]}`))
		case strings.HasSuffix(r.URL.Path, "/DeleteRoom"):
			_, _ = w.Write([]byte(`{}`))
		default:
			t.Errorf("unexpected room operation %s", r.URL.Path)
		}
	}))
	t.Cleanup(server.Close)
	p := &Plugin{config: configuration{LiveKitURL: "wss://calls.example.com", LiveKitInternalURL: server.URL, LiveKitAPIKey: "test-key", LiveKitAPISecret: "test-secret", MaxParticipants: 25}, client: server.Client()}
	p.SetAPI(api)
	return p, api, &created
}

func invoke(p *Plugin, user, method, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Mattermost-User-Id", user)
	w := httptest.NewRecorder()
	p.ServeHTTP(nil, w, r)
	return w
}

func TestChannelAuthorization(t *testing.T) {
	p, api, created := setup(t)
	path := "/channels/" + model.NewId() + "/join"
	if r := invoke(p, "", "POST", path, "{}"); r.Code != 401 {
		t.Fatalf("unauthenticated join: %d", r.Code)
	}
	api.member = false
	if r := invoke(p, model.NewId(), "POST", path, "{}"); r.Code != 403 {
		t.Fatalf("non-member join: %d", r.Code)
	}
	if *created != 0 {
		t.Fatal("unauthorized request created a room")
	}
}

func TestJoinUsesOneRoomAndScopedTokens(t *testing.T) {
	p, _, created := setup(t)
	channel, user := model.NewId(), model.NewId()
	first := invoke(p, user, "POST", "/channels/"+channel+"/join", "{}")
	if first.Code != 200 {
		t.Fatalf("join: %d %s", first.Code, first.Body.String())
	}
	var a, b joinResponse
	if err := json.Unmarshal(first.Body.Bytes(), &a); err != nil {
		t.Fatal(err)
	}
	second := invoke(p, model.NewId(), "POST", "/channels/"+channel+"/join", "{}")
	if err := json.Unmarshal(second.Body.Bytes(), &b); err != nil {
		t.Fatal(err)
	}
	if *created != 1 || a.Call.ID != b.Call.ID || a.Call.Room != b.Call.Room {
		t.Fatal("members did not join the same call")
	}
	if !a.Call.CanEnd || b.Call.CanEnd {
		t.Fatal("call owner permissions leaked")
	}
	claimsData, _ := base64.RawURLEncoding.DecodeString(strings.Split(a.Token, ".")[1])
	var claims map[string]any
	_ = json.Unmarshal(claimsData, &claims)
	grant := claims["video"].(map[string]any)
	if grant["room"] != a.Call.Room || grant["roomJoin"] != true || grant["roomAdmin"] != nil || grant["roomCreate"] != nil {
		t.Fatal("join token grants excess access")
	}
	if !strings.HasPrefix(claims["sub"].(string), user+":") {
		t.Fatal("token identity is not the authenticated user")
	}
	if a.Token == b.Token || strings.Contains(first.Body.String(), "test-secret") {
		t.Fatal("token or secret leaked")
	}
}

func TestOnlyOwnerCanEndCurrentCall(t *testing.T) {
	p, api, _ := setup(t)
	channel, owner := model.NewId(), model.NewId()
	r := invoke(p, owner, "POST", "/channels/"+channel+"/join", "{}")
	var response joinResponse
	_ = json.Unmarshal(r.Body.Bytes(), &response)
	body := `{"call_id":"` + response.Call.ID + `"}`
	if r := invoke(p, model.NewId(), "POST", "/channels/"+channel+"/end", body); r.Code != 403 {
		t.Fatalf("non-owner end: %d", r.Code)
	}
	if r := invoke(p, owner, "POST", "/channels/"+channel+"/end", `{"call_id":"`+model.NewId()+`"}`); r.Code != 409 {
		t.Fatalf("stale end: %d", r.Code)
	}
	if r := invoke(p, owner, "POST", "/channels/"+channel+"/end", body); r.Code != 200 {
		t.Fatalf("owner end: %d", r.Code)
	}
	if len(api.data) != 0 {
		t.Fatal("ended call remains joinable")
	}
}

func TestWebhookRequiresSignedUnmodifiedBody(t *testing.T) {
	body := []byte(`{"event":"room_finished","room":{"name":"relay_test"}}`)
	digest := sha256.Sum256(body)
	token, _ := signToken("key", "secret", "", "", nil, time.Minute, base64.StdEncoding.EncodeToString(digest[:]))
	if !verifyWebhook(token, body, "key", "secret") {
		t.Fatal("valid webhook rejected")
	}
	if verifyWebhook(token, append(body, ' '), "key", "secret") || verifyWebhook(token, body, "key", "other") || verifyWebhook(token, body, "wrong", "secret") {
		t.Fatal("forged webhook accepted")
	}
	expired, _ := signToken("key", "secret", "", "", nil, -time.Minute, base64.StdEncoding.EncodeToString(digest[:]))
	if verifyWebhook(expired, body, "key", "secret") {
		t.Fatal("expired webhook accepted")
	}
}

func TestLeavingChannelRevokesEveryDeviceAndStaleJoin(t *testing.T) {
	p, api, _ := setup(t)
	channel, user, other := model.NewId(), model.NewId(), model.NewId()
	first, second := user+":"+model.NewId(), user+":"+model.NewId()
	call := &callState{ID: model.NewId(), ChannelID: channel, Room: "relay_test", StartedBy: user}
	if err := p.saveCall(call); err != nil {
		t.Fatal(err)
	}
	removed := []string{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/ListParticipants") {
			writeJSON(w, map[string]any{"participants": []map[string]string{{"identity": first}, {"identity": second}, {"identity": other + ":" + model.NewId()}}})
			return
		}
		if !strings.HasSuffix(r.URL.Path, "/RemoveParticipant") {
			t.Errorf("unexpected method %s", r.URL.Path)
		}
		var input struct {
			Room     string `json:"room"`
			Identity string `json:"identity"`
		}
		if err := json.NewDecoder(r.Body).Decode(&input); err != nil {
			t.Error(err)
		}
		if input.Room != call.Room {
			t.Error("incorrect room")
		}
		removed = append(removed, input.Identity)
		writeJSON(w, map[string]bool{"ok": true})
	}))
	defer server.Close()
	p.config.LiveKitInternalURL = server.URL
	api.member = false
	p.UserHasLeftChannel(nil, &model.ChannelMember{ChannelId: channel, UserId: user}, nil)
	if len(removed) != 2 || removed[0] != first || removed[1] != second {
		t.Fatal("not all former member devices were removed")
	}
	body, _ := json.Marshal(map[string]any{"event": "participant_joined", "room": map[string]string{"name": call.Room}, "participant": map[string]string{"identity": first}})
	digest := sha256.Sum256(body)
	token, _ := signToken(p.config.LiveKitAPIKey, p.config.LiveKitAPISecret, "", "", nil, time.Minute, base64.StdEncoding.EncodeToString(digest[:]))
	req := httptest.NewRequest("POST", "/webhook", strings.NewReader(string(body)))
	req.Header.Set("Authorization", token)
	result := httptest.NewRecorder()
	p.ServeHTTP(nil, result, req)
	if result.Code != 200 || len(removed) != 3 || removed[2] != first {
		t.Fatal("stale join token retained channel access")
	}
}
