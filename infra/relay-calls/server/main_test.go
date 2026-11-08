package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/gob"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
	"github.com/mattermost/mattermost/server/public/plugin"
)

type testEvent struct {
	name    string
	data    map[string]any
	userID  string
	channel string
	omit    map[string]bool
}

type testPush struct {
	userID       string
	notification *model.PushNotification
}

// testAPI is a goroutine-safe fake of the plugin API methods the plugin uses.
type testAPI struct {
	plugin.API
	mu        sync.Mutex
	data      map[string][]byte
	expiry    map[string]int64
	member    bool
	channels  map[string]*model.Channel
	members   map[string][]string
	users     map[string]*model.User
	sessions  map[string]*model.Session
	posts     map[string]*model.Post
	updates   int
	events    []testEvent
	pushes    []testPush
	logs      []string
	settings  configuration
	siteURL   string
	beforeCAS func()
}

func newTestAPI() *testAPI {
	return &testAPI{
		data: map[string][]byte{}, expiry: map[string]int64{}, member: true, channels: map[string]*model.Channel{},
		members: map[string][]string{}, users: map[string]*model.User{}, sessions: map[string]*model.Session{},
		posts: map[string]*model.Post{}, siteURL: "https://chat.example.com",
	}
}

func (a *testAPI) GetChannel(id string) (*model.Channel, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if channel, ok := a.channels[id]; ok {
		return channel, nil
	}
	return &model.Channel{Id: id, Type: "O"}, nil
}

func (a *testAPI) GetChannelMember(channel, user string) (*model.ChannelMember, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !a.member {
		return nil, model.NewAppError("test", "forbidden", nil, "", 403)
	}
	if list, ok := a.members[channel]; ok && !containsString(list, user) {
		return nil, model.NewAppError("test", "not_member", nil, "", 404)
	}
	return &model.ChannelMember{ChannelId: channel, UserId: user}, nil
}

func (a *testAPI) GetChannelMembers(channel string, page, perPage int) (model.ChannelMembers, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	list := a.members[channel]
	members := model.ChannelMembers{}
	for i := page * perPage; i < len(list) && i < (page+1)*perPage; i++ {
		members = append(members, model.ChannelMember{ChannelId: channel, UserId: list[i]})
	}
	return members, nil
}

func (a *testAPI) GetUser(id string) (*model.User, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if user, ok := a.users[id]; ok {
		return user, nil
	}
	return &model.User{Id: id, Username: "tester"}, nil
}

func (a *testAPI) HasPermissionTo(string, *model.Permission) bool { return false }

func (a *testAPI) KVGet(key string) ([]byte, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.data[key], nil
}

func (a *testAPI) KVSet(key string, value []byte) *model.AppError {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.data[key] = value
	delete(a.expiry, key)
	return nil
}

func (a *testAPI) KVSetWithExpiry(key string, value []byte, seconds int64) *model.AppError {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.data[key] = value
	a.expiry[key] = seconds
	return nil
}

func (a *testAPI) KVCompareAndSet(key string, oldValue, newValue []byte) (bool, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if hook := a.beforeCAS; hook != nil {
		a.beforeCAS = nil
		hook()
	}
	current, exists := a.data[key]
	if oldValue == nil {
		if exists {
			return false, nil
		}
	} else if !exists || !bytes.Equal(current, oldValue) {
		return false, nil
	}
	a.data[key] = newValue
	delete(a.expiry, key)
	return true, nil
}

func (a *testAPI) KVDelete(key string) *model.AppError {
	a.mu.Lock()
	defer a.mu.Unlock()
	delete(a.data, key)
	delete(a.expiry, key)
	return nil
}

// PublishWebSocketEvent checks that the payload survives plugin RPC (gob) and records the recipients.
func (a *testAPI) PublishWebSocketEvent(name string, value map[string]interface{}, broadcast *model.WebsocketBroadcast) {
	if err := gob.NewEncoder(&bytes.Buffer{}).Encode(value); err != nil {
		panic(err)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	event := testEvent{name: name, data: value}
	if broadcast != nil {
		event.userID, event.channel, event.omit = broadcast.UserId, broadcast.ChannelId, broadcast.OmitUsers
	}
	a.events = append(a.events, event)
}

func (a *testAPI) CreatePost(post *model.Post) (*model.Post, *model.AppError) {
	if err := gob.NewEncoder(&bytes.Buffer{}).Encode(post); err != nil {
		panic(err)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	post.Id = model.NewId()
	a.posts[post.Id] = post
	return post, nil
}

func (a *testAPI) GetPost(id string) (*model.Post, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if post, ok := a.posts[id]; ok {
		return post, nil
	}
	return nil, model.NewAppError("test", "not_found", nil, "", 404)
}

func (a *testAPI) UpdatePost(post *model.Post) (*model.Post, *model.AppError) {
	if err := gob.NewEncoder(&bytes.Buffer{}).Encode(post); err != nil {
		panic(err)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if _, ok := a.posts[post.Id]; !ok {
		return nil, model.NewAppError("test", "not_found", nil, "", 404)
	}
	a.posts[post.Id] = post
	a.updates++
	return post, nil
}

func (a *testAPI) GetConfig() *model.Config {
	a.mu.Lock()
	defer a.mu.Unlock()
	site, push, contents := a.siteURL, true, "full"
	config := &model.Config{}
	config.ServiceSettings.SiteURL = &site
	config.EmailSettings.SendPushNotifications = &push
	config.EmailSettings.PushNotificationContents = &contents
	return config
}

func (a *testAPI) GetSession(id string) (*model.Session, *model.AppError) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if session, ok := a.sessions[id]; ok {
		return session, nil
	}
	return nil, model.NewAppError("test", "invalid_session", nil, "", 401)
}

func (a *testAPI) SendPushNotification(notification *model.PushNotification, userID string) *model.AppError {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.pushes = append(a.pushes, testPush{userID: userID, notification: notification})
	return nil
}

func (a *testAPI) LoadPluginConfiguration(dest interface{}) error {
	a.mu.Lock()
	data, err := json.Marshal(a.settings)
	a.mu.Unlock()
	if err != nil {
		return err
	}
	return json.Unmarshal(data, dest)
}

func (a *testAPI) record(message string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.logs = append(a.logs, message)
}

func (a *testAPI) LogDebug(message string, _ ...interface{}) { a.record(message) }
func (a *testAPI) LogInfo(message string, _ ...interface{})  { a.record(message) }
func (a *testAPI) LogWarn(message string, _ ...interface{})  { a.record(message) }
func (a *testAPI) LogError(message string, _ ...interface{}) { a.record(message) }

func (a *testAPI) value(key string) []byte {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.data[key]
}

func (a *testAPI) eventsNamed(name string) []testEvent {
	a.mu.Lock()
	defer a.mu.Unlock()
	var events []testEvent
	for _, event := range a.events {
		if event.name == name {
			events = append(events, event)
		}
	}
	return events
}

func (a *testAPI) resetEvents() {
	a.mu.Lock()
	defer a.mu.Unlock()
	a.events = nil
}

func (a *testAPI) post(id string) *model.Post {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.posts[id]
}

func (a *testAPI) pushList() []testPush {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]testPush(nil), a.pushes...)
}

func (a *testAPI) logCount(fragment string) int {
	a.mu.Lock()
	defer a.mu.Unlock()
	count := 0
	for _, message := range a.logs {
		if strings.Contains(message, fragment) {
			count++
		}
	}
	return count
}

// userRecipients lists the users that per-user events went to, sorted.
func userRecipients(events []testEvent) []string {
	var users []string
	for _, event := range events {
		if event.userID != "" {
			users = append(users, event.userID)
		}
	}
	sort.Strings(users)
	return users
}

func channelBroadcasts(events []testEvent) []testEvent {
	var out []testEvent
	for _, event := range events {
		if event.channel != "" {
			out = append(out, event)
		}
	}
	return out
}

// fakeLiveKit implements the LiveKit room service calls the plugin makes.
type fakeLiveKit struct {
	mu         sync.Mutex
	rooms      map[string]bool
	identities map[string][]string
	created    int
	deleted    []string
	removed    []string
}

func newFakeLiveKit(t *testing.T) (*fakeLiveKit, *httptest.Server) {
	t.Helper()
	lk := &fakeLiveKit{rooms: map[string]bool{}, identities: map[string][]string{}}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		parts := strings.Split(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "), ".")
		if len(parts) != 3 {
			t.Error("missing server authorization")
			w.WriteHeader(401)
			return
		}
		var input struct {
			Name     string   `json:"name"`
			Room     string   `json:"room"`
			Names    []string `json:"names"`
			Identity string   `json:"identity"`
		}
		_ = json.NewDecoder(r.Body).Decode(&input)
		lk.mu.Lock()
		defer lk.mu.Unlock()
		switch r.URL.Path[strings.LastIndex(r.URL.Path, "/")+1:] {
		case "CreateRoom":
			lk.created++
			lk.rooms[input.Name] = true
			writeJSON(w, map[string]any{"name": input.Name})
		case "ListRooms":
			rooms := []map[string]any{}
			for _, name := range input.Names {
				if lk.rooms[name] {
					rooms = append(rooms, map[string]any{"name": name, "num_participants": len(lk.identities[name])})
				}
			}
			writeJSON(w, map[string]any{"rooms": rooms})
		case "DeleteRoom":
			lk.deleted = append(lk.deleted, input.Room)
			delete(lk.rooms, input.Room)
			delete(lk.identities, input.Room)
			writeJSON(w, map[string]any{})
		case "ListParticipants":
			participants := []map[string]string{}
			for _, identity := range lk.identities[input.Room] {
				participants = append(participants, map[string]string{"identity": identity})
			}
			writeJSON(w, map[string]any{"participants": participants})
		case "RemoveParticipant":
			lk.removed = append(lk.removed, input.Identity)
			lk.identities[input.Room] = removeString(lk.identities[input.Room], input.Identity)
			writeJSON(w, map[string]any{})
		default:
			t.Errorf("unexpected room operation %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(server.Close)
	return lk, server
}

func (lk *fakeLiveKit) createdCount() int {
	lk.mu.Lock()
	defer lk.mu.Unlock()
	return lk.created
}

func (lk *fakeLiveKit) deletedRooms() []string {
	lk.mu.Lock()
	defer lk.mu.Unlock()
	return append([]string(nil), lk.deleted...)
}

func (lk *fakeLiveKit) removedIdentities() []string {
	lk.mu.Lock()
	defer lk.mu.Unlock()
	return append([]string(nil), lk.removed...)
}

func (lk *fakeLiveKit) setConnected(room, identity string, connected bool) {
	lk.mu.Lock()
	defer lk.mu.Unlock()
	if connected {
		lk.identities[room] = append(lk.identities[room], identity)
	} else {
		lk.identities[room] = removeString(lk.identities[room], identity)
	}
}

type testClock struct {
	mu  sync.Mutex
	now time.Time
}

func (c *testClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.now
}

func (c *testClock) Advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.now = c.now.Add(d)
}

type harness struct {
	p      *Plugin
	api    *testAPI
	lk     *fakeLiveKit
	clock  *testClock
	server *httptest.Server
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	t.Setenv("RELAY_CALLS_CONFIG_FILE", filepath.Join(t.TempDir(), "missing.json"))
	api := newTestAPI()
	lk, server := newFakeLiveKit(t)
	clock := &testClock{now: time.UnixMilli(1_800_000_000_000)}
	settings := configuration{LiveKitURL: "wss://calls.example.com", LiveKitInternalURL: server.URL, LiveKitAPIKey: "test-key", LiveKitAPISecret: "test-secret", MaxParticipants: 25, AnnounceCalls: true, RingTimeoutSeconds: 45}
	api.settings = settings
	p := &Plugin{config: settings, client: server.Client(), now: clock.Now, sweepEvery: time.Hour}
	p.SetAPI(api)
	t.Cleanup(p.pending.Wait)
	return &harness{p: p, api: api, lk: lk, clock: clock, server: server}
}

func setup(t *testing.T) (*Plugin, *testAPI, *fakeLiveKit) {
	t.Helper()
	h := newHarness(t)
	return h.p, h.api, h.lk
}

// user adds an active user whose display name is the capitalized username.
func (h *harness) user(name string) string {
	id := model.NewId()
	h.api.mu.Lock()
	defer h.api.mu.Unlock()
	h.api.users[id] = &model.User{Id: id, Username: name, FirstName: strings.ToUpper(name[:1]) + name[1:]}
	return id
}

// channel adds a channel of type "D", "G", "O" or "P" with exactly these members.
func (h *harness) channel(kind string, members ...string) string {
	id := model.NewId()
	channel := &model.Channel{Id: id, Type: "O"}
	switch kind {
	case "D":
		channel.Type = "D"
	case "G":
		channel.Type = "G"
	case "P":
		channel.Type = "P"
	}
	h.api.mu.Lock()
	defer h.api.mu.Unlock()
	h.api.channels[id] = channel
	h.api.members[id] = append([]string(nil), members...)
	return id
}

// webhook delivers a signed LiveKit webhook.
func (h *harness) webhook(t *testing.T, event, room, identity string) {
	t.Helper()
	payload := map[string]any{"event": event, "room": map[string]string{"name": room}}
	if identity != "" {
		payload["participant"] = map[string]string{"identity": identity}
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(body)
	token, err := signToken("test-key", "test-secret", "", "", nil, time.Minute, base64.StdEncoding.EncodeToString(digest[:]))
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("POST", "/webhook", bytes.NewReader(body))
	req.Header.Set("Authorization", token)
	w := httptest.NewRecorder()
	h.p.ServeHTTP(nil, w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("webhook %s: %d %s", event, w.Code, w.Body.String())
	}
}

// connect puts identity into the LiveKit room and delivers participant_joined.
func (h *harness) connect(t *testing.T, room, identity string) {
	t.Helper()
	h.lk.setConnected(room, identity, true)
	h.webhook(t, "participant_joined", room, identity)
}

func (h *harness) stored(t *testing.T, id string) *callState {
	t.Helper()
	h.p.mu.Lock()
	defer h.p.mu.Unlock()
	call, _, err := h.p.loadCallByID(id)
	if err != nil || call == nil {
		t.Fatalf("call %s is not stored: %v", id, err)
	}
	return call
}

func (h *harness) sweep() {
	h.p.sweep()
	h.p.pending.Wait()
}

func invoke(p *Plugin, user, method, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Mattermost-User-Id", user)
	w := httptest.NewRecorder()
	p.ServeHTTP(nil, w, r)
	p.pending.Wait()
	return w
}

func invokeSession(p *Plugin, session, user, method, path, body string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(method, path, strings.NewReader(body))
	r.Header.Set("Mattermost-User-Id", user)
	w := httptest.NewRecorder()
	p.ServeHTTP(&plugin.Context{SessionId: session}, w, r)
	p.pending.Wait()
	return w
}

func expectStatus(t *testing.T, r *httptest.ResponseRecorder, status int) {
	t.Helper()
	if r.Code != status {
		t.Fatalf("expected HTTP %d, got %d: %s", status, r.Code, r.Body.String())
	}
}

func decodeJoin(t *testing.T, r *httptest.ResponseRecorder) joinResponse {
	t.Helper()
	expectStatus(t, r, http.StatusOK)
	var response joinResponse
	if err := json.Unmarshal(r.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response
}

func decodeCall(t *testing.T, r *httptest.ResponseRecorder) callView {
	t.Helper()
	expectStatus(t, r, http.StatusOK)
	var call callView
	if err := json.Unmarshal(r.Body.Bytes(), &call); err != nil {
		t.Fatal(err)
	}
	return call
}

func tokenClaims(t *testing.T, token string) map[string]any {
	t.Helper()
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		t.Fatalf("malformed token %q", token)
	}
	data, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		t.Fatal(err)
	}
	var claims map[string]any
	if err := json.Unmarshal(data, &claims); err != nil {
		t.Fatal(err)
	}
	return claims
}

func TestChannelAuthorization(t *testing.T) {
	p, api, lk := setup(t)
	path := "/channels/" + model.NewId() + "/join"
	if r := invoke(p, "", "POST", path, "{}"); r.Code != 401 {
		t.Fatalf("unauthenticated join: %d", r.Code)
	}
	api.mu.Lock()
	api.member = false
	api.mu.Unlock()
	if r := invoke(p, model.NewId(), "POST", path, "{}"); r.Code != 403 {
		t.Fatalf("non-member join: %d", r.Code)
	}
	if lk.createdCount() != 0 {
		t.Fatal("unauthorized request created a room")
	}
}

func TestJoinUsesOneRoomAndScopedTokens(t *testing.T) {
	p, _, lk := setup(t)
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
	if lk.createdCount() != 1 || a.Call.ID != b.Call.ID || a.Call.Room != b.Call.Room {
		t.Fatal("members did not join the same call")
	}
	if !a.Call.CanEnd || b.Call.CanEnd {
		t.Fatal("call owner permissions leaked")
	}
	claims := tokenClaims(t, a.Token)
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
	if len(api.value(channelKey(channel))) != 0 || len(api.value(roomKey(response.Call.Room))) != 0 {
		t.Fatal("ended call remains joinable")
	}
	var current struct {
		Call *callView `json:"call"`
	}
	if err := json.Unmarshal(invoke(p, owner, "GET", "/channels/"+channel, "").Body.Bytes(), &current); err != nil || current.Call != nil {
		t.Fatal("ended call is still the channel's call")
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
	var mu sync.Mutex
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
		mu.Lock()
		removed = append(removed, input.Identity)
		mu.Unlock()
		writeJSON(w, map[string]bool{"ok": true})
	}))
	defer server.Close()
	p.config.LiveKitInternalURL = server.URL
	api.mu.Lock()
	api.member = false
	api.mu.Unlock()
	p.UserHasLeftChannel(nil, &model.ChannelMember{ChannelId: channel, UserId: user}, nil)
	mu.Lock()
	revoked := append([]string(nil), removed...)
	mu.Unlock()
	if len(revoked) != 2 || revoked[0] != first || revoked[1] != second {
		t.Fatal("not all former member devices were removed")
	}
	body, _ := json.Marshal(map[string]any{"event": "participant_joined", "room": map[string]string{"name": call.Room}, "participant": map[string]string{"identity": first}})
	digest := sha256.Sum256(body)
	token, _ := signToken(p.config.LiveKitAPIKey, p.config.LiveKitAPISecret, "", "", nil, time.Minute, base64.StdEncoding.EncodeToString(digest[:]))
	req := httptest.NewRequest("POST", "/webhook", strings.NewReader(string(body)))
	req.Header.Set("Authorization", token)
	result := httptest.NewRecorder()
	p.ServeHTTP(nil, result, req)
	mu.Lock()
	revoked = append([]string(nil), removed...)
	mu.Unlock()
	if result.Code != 200 || len(revoked) != 3 || revoked[2] != first {
		t.Fatal("stale join token retained channel access")
	}
}

// TestHooksMatchServerSignatures guards against a hook that compiles but that the server never calls: the
// server registers a hook only when the method matches plugin.Hooks exactly.
func TestHooksMatchServerSignatures(t *testing.T) {
	hooks := reflect.TypeOf((*plugin.Hooks)(nil)).Elem()
	impl := reflect.TypeOf(&Plugin{})
	for _, name := range []string{"OnActivate", "OnDeactivate", "OnConfigurationChange", "ServeHTTP", "UserHasLeftChannel", "NotificationWillBePushed"} {
		want, ok := hooks.MethodByName(name)
		if !ok {
			t.Fatalf("plugin.Hooks has no %s", name)
		}
		got, ok := impl.MethodByName(name)
		if !ok {
			t.Fatalf("Plugin does not implement %s", name)
		}
		if got.Type.NumIn() != want.Type.NumIn()+1 || got.Type.NumOut() != want.Type.NumOut() {
			t.Fatalf("%s does not match plugin.Hooks", name)
		}
		for i := 0; i < want.Type.NumIn(); i++ {
			if got.Type.In(i+1) != want.Type.In(i) {
				t.Fatalf("%s parameter %d does not match plugin.Hooks", name, i)
			}
		}
		for i := 0; i < want.Type.NumOut(); i++ {
			if got.Type.Out(i) != want.Type.Out(i) {
				t.Fatalf("%s result %d does not match plugin.Hooks", name, i)
			}
		}
	}
}

func TestConfigAdvertisesVersion2(t *testing.T) {
	p, _, _ := setup(t)
	r := invoke(p, model.NewId(), "GET", "/config", "")
	expectStatus(t, r, http.StatusOK)
	var config map[string]any
	if err := json.Unmarshal(r.Body.Bytes(), &config); err != nil {
		t.Fatal(err)
	}
	if config["enabled"] != true || config["version"] != float64(2) || config["camera"] != true || config["ringing"] != true ||
		config["ring_timeout_seconds"] != float64(45) || config["screen_sharing"] != true || config["max_participants"] != float64(25) {
		t.Fatalf("unexpected configuration %v", config)
	}
}

func TestPublicLiveKitURLAllowsPlainSchemesOnlyOnLoopback(t *testing.T) {
	cases := map[string]bool{
		"wss://livekit.example.com":     true,
		"https://livekit.example.com":   true,
		"ws://127.0.0.1:7880":           true,
		"ws://localhost:7880":           true,
		"http://[::1]:7880":             true,
		"ws://livekit.example.com:7880": false,
		"ws://192.168.0.5:7880":         false,
		"wss://user:pw@livekit.example": false,
		"ftp://livekit.example.com":     false,
	}
	for raw, want := range cases {
		u, err := url.Parse(raw)
		if err != nil {
			t.Fatal(err)
		}
		if got := validPublicLiveKitURL(u); got != want {
			t.Errorf("%s: got %v, want %v", raw, got, want)
		}
	}
}
