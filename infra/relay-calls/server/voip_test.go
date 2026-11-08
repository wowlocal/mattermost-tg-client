package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
)

type apnsRequest struct {
	proto  int
	path   string
	header http.Header
	body   []byte
}

// fakeAPNs is an HTTP/2 TLS server answering like APNs; status and reason are per device token.
type fakeAPNs struct {
	mu       sync.Mutex
	requests []apnsRequest
	status   map[string]int
	reason   map[string]string
}

func newFakeAPNs(t *testing.T) (*fakeAPNs, *httptest.Server) {
	t.Helper()
	f := &fakeAPNs{status: map[string]int{}, reason: map[string]string{}}
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		token := strings.TrimPrefix(r.URL.Path, "/3/device/")
		f.mu.Lock()
		f.requests = append(f.requests, apnsRequest{proto: r.ProtoMajor, path: r.URL.Path, header: r.Header.Clone(), body: body})
		status, reason := f.status[token], f.reason[token]
		f.mu.Unlock()
		if status == 0 {
			status = http.StatusOK
		}
		w.Header().Set("apns-id", "00000000-0000-0000-0000-000000000000")
		w.WriteHeader(status)
		if reason != "" {
			_ = json.NewEncoder(w).Encode(map[string]string{"reason": reason})
		}
	}))
	server.EnableHTTP2 = true
	server.StartTLS()
	t.Cleanup(server.Close)
	return f, server
}

func (f *fakeAPNs) list() []apnsRequest {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]apnsRequest(nil), f.requests...)
}

func writeAPNsKey(t *testing.T) (*ecdsa.PrivateKey, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "AuthKey_KEY1234567.p8")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatal(err)
	}
	return key, path
}

func (h *harness) enableVoIP(t *testing.T, server *httptest.Server) *ecdsa.PrivateKey {
	t.Helper()
	key, path := writeAPNsKey(t)
	sender, err := newAPNsSender(configuration{APNsKeyID: "KEY1234567", APNsTeamID: "TEAM123456", APNsKeyPath: path, APNsBaseURL: server.URL}, server.Client())
	if err != nil || sender == nil {
		t.Fatalf("could not create the APNs sender: %v", err)
	}
	sender.now = h.clock.Now
	h.p.voip = sender
	return key
}

func (h *harness) session(id, userID string) {
	h.api.mu.Lock()
	defer h.api.mu.Unlock()
	h.api.sessions[id] = &model.Session{Id: id, UserId: userID}
}

func (h *harness) devices(t *testing.T, userID string) map[string]voipDevice {
	t.Helper()
	h.p.mu.Lock()
	defer h.p.mu.Unlock()
	devices, err := h.p.loadDevices(userID)
	if err != nil {
		t.Fatal(err)
	}
	return devices
}

func registration(deviceID, token string) string {
	return `{"device_id":"` + deviceID + `","token":"` + token + `","environment":"sandbox","bundle_id":"com.example.relay"}`
}

// verifyProviderToken checks the ES256 provider token APNs expects and returns it with its iat.
func verifyProviderToken(t *testing.T, authorization string, key *ecdsa.PublicKey) (string, int64) {
	t.Helper()
	token := strings.TrimPrefix(authorization, "bearer ")
	parts := strings.Split(token, ".")
	if !strings.HasPrefix(authorization, "bearer ") || len(parts) != 3 {
		t.Fatalf("malformed authorization %q", authorization)
	}
	var header map[string]any
	data, err := base64.RawURLEncoding.DecodeString(parts[0])
	if err != nil || json.Unmarshal(data, &header) != nil || header["alg"] != "ES256" || header["kid"] != "KEY1234567" || len(header) != 2 {
		t.Fatalf("unexpected JWT header %s", data)
	}
	var claims map[string]any
	data, err = base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil || json.Unmarshal(data, &claims) != nil || claims["iss"] != "TEAM123456" || len(claims) != 2 {
		t.Fatalf("unexpected JWT claims %s", data)
	}
	iat, ok := claims["iat"].(float64)
	if !ok {
		t.Fatalf("JWT iat is not a number: %v", claims["iat"])
	}
	signature, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(signature) != 64 {
		t.Fatalf("JWT signature is not a raw 64-byte r||s value")
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	if !ecdsa.Verify(key, digest[:], new(big.Int).SetBytes(signature[:32]), new(big.Int).SetBytes(signature[32:])) {
		t.Fatal("the JWT signature does not verify with the .p8 key")
	}
	return token, int64(iat)
}

func TestVoIPRingReachesRegisteredDevice(t *testing.T) {
	h := newHarness(t)
	apns, server := newFakeAPNs(t)
	key := h.enableVoIP(t, server)
	alice, bob := h.user("alice"), h.user("bob")
	h.session("session-bob", bob)
	token := strings.Repeat("ab", 32)
	expectStatus(t, invokeSession(h.p, "session-bob", bob, "POST", "/devices/voip", registration("bob-phone", strings.ToUpper(token))), http.StatusNoContent)
	if device := h.devices(t, bob)["bob-phone"]; device.Token != token || device.SessionID != "session-bob" || device.Environment != "sandbox" || device.BundleID != "com.example.relay" {
		t.Fatalf("unexpected registration %+v", device)
	}

	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"video":true,"device_id":"alice-phone"}`)).Call
	requests := apns.list()
	if len(requests) != 1 {
		t.Fatalf("expected one VoIP push, got %d", len(requests))
	}
	request := requests[0]
	if request.proto != 2 {
		t.Fatalf("the VoIP push used HTTP/%d", request.proto)
	}
	if request.path != "/3/device/"+token {
		t.Fatalf("unexpected APNs path %s", request.path)
	}
	for name, want := range map[string]string{
		"apns-push-type": "voip", "apns-topic": "com.example.relay.voip", "apns-priority": "10",
		"apns-expiration": strconv.FormatInt(*call.RingExpiresAt/1000, 10), "apns-collapse-id": call.ID,
	} {
		if got := request.header.Get(name); got != want {
			t.Fatalf("%s is %q, want %q", name, got, want)
		}
	}
	first, iat := verifyProviderToken(t, request.header.Get("authorization"), &key.PublicKey)
	if iat != h.clock.Now().Unix() {
		t.Fatalf("JWT iat %d, want %d", iat, h.clock.Now().Unix())
	}
	expected, _ := json.Marshal(map[string]any{"relay_call": map[string]any{
		"v": 2, "call_id": call.ID, "channel_id": channel, "caller_id": alice, "caller_name": "Alice", "video": true,
		"ring_expires_at": *call.RingExpiresAt, "server_url": "https://chat.example.com", "recipient_id": bob,
	}})
	if string(request.body) != string(expected) {
		t.Fatalf("payload %s, want %s", request.body, expected)
	}

	// The provider token is cached, and replaced before it is an hour old.
	expectStatus(t, invoke(h.p, alice, "POST", callPath(call.ID, "hangup"), `{"device_id":"alice-phone"}`), http.StatusNoContent)
	h.clock.Advance(10 * time.Minute)
	second := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call
	expectStatus(t, invoke(h.p, alice, "POST", callPath(second.ID, "hangup"), `{"device_id":"alice-phone"}`), http.StatusNoContent)
	h.clock.Advance(41 * time.Minute)
	decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`))
	requests = apns.list()
	if len(requests) != 3 {
		t.Fatalf("expected three VoIP pushes, got %d", len(requests))
	}
	if requests[1].header.Get("authorization") != "bearer "+first {
		t.Fatal("the provider token was not reused")
	}
	renewed, renewedAt := verifyProviderToken(t, requests[2].header.Get("authorization"), &key.PublicKey)
	if renewed == first || renewedAt != h.clock.Now().Unix() {
		t.Fatal("the provider token was not renewed after 50 minutes")
	}
	if len(h.api.eventsNamed("incoming")) != 3 {
		t.Fatal("VoIP replaced the WebSocket ring")
	}
}

func TestVoIPDropsDeadRegistrations(t *testing.T) {
	h := newHarness(t)
	apns, server := newFakeAPNs(t)
	h.enableVoIP(t, server)
	alice, bob := h.user("alice"), h.user("bob")
	gone, bad, revoked, live := strings.Repeat("01", 32), strings.Repeat("02", 32), strings.Repeat("03", 32), strings.Repeat("04", 32)
	apns.mu.Lock()
	apns.status[gone], apns.reason[gone] = http.StatusGone, "Unregistered"
	apns.status[bad], apns.reason[bad] = http.StatusBadRequest, "BadDeviceToken"
	apns.mu.Unlock()
	for _, session := range []string{"s-gone", "s-bad", "s-revoked", "s-live"} {
		h.session(session, bob)
	}
	expectStatus(t, invokeSession(h.p, "s-gone", bob, "POST", "/devices/voip", registration("bob-old", gone)), http.StatusNoContent)
	expectStatus(t, invokeSession(h.p, "s-bad", bob, "POST", "/devices/voip", registration("bob-bad", bad)), http.StatusNoContent)
	expectStatus(t, invokeSession(h.p, "s-revoked", bob, "POST", "/devices/voip", registration("bob-ipad", revoked)), http.StatusNoContent)
	expectStatus(t, invokeSession(h.p, "s-live", bob, "POST", "/devices/voip", registration("bob-phone", live)), http.StatusNoContent)
	for _, body := range []string{
		`{"device_id":"x","token":"` + live + `","environment":"development","bundle_id":"com.example.relay"}`,
		`{"device_id":"x","token":"xyz","environment":"sandbox","bundle_id":"com.example.relay"}`,
		`{"device_id":"x","token":"` + live + `","environment":"sandbox","bundle_id":"bad bundle"}`,
		`{"device_id":"a:b","token":"` + live + `","environment":"sandbox","bundle_id":"com.example.relay"}`,
	} {
		expectStatus(t, invokeSession(h.p, "s-live", bob, "POST", "/devices/voip", body), http.StatusBadRequest)
	}
	h.api.mu.Lock()
	delete(h.api.sessions, "s-revoked")
	h.api.mu.Unlock()

	channel := h.channel("D", alice, bob)
	decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`))
	sent := map[string]bool{}
	for _, request := range apns.list() {
		sent[strings.TrimPrefix(request.path, "/3/device/")] = true
	}
	if len(sent) != 3 || !sent[gone] || !sent[bad] || !sent[live] || sent[revoked] {
		t.Fatalf("unexpected VoIP recipients %v", sent)
	}
	devices := h.devices(t, bob)
	if len(devices) != 1 || devices["bob-phone"].Token != live {
		t.Fatalf("dead registrations were kept: %+v", devices)
	}

	// The same APNs token registered again under a new device id replaces the old entry.
	expectStatus(t, invokeSession(h.p, "s-live", bob, "POST", "/devices/voip", registration("bob-phone-2", live)), http.StatusNoContent)
	if devices := h.devices(t, bob); len(devices) != 1 || devices["bob-phone-2"].Token != live {
		t.Fatalf("a re-registered token was duplicated: %+v", devices)
	}
	expectStatus(t, invoke(h.p, bob, "DELETE", "/devices/voip/bob-phone-2", ""), http.StatusNoContent)
	if len(h.devices(t, bob)) != 0 || h.api.value(devicesKey(bob)) != nil {
		t.Fatal("the registration was not deleted")
	}
	expectStatus(t, invoke(h.p, bob, "DELETE", "/devices/voip/bob-phone-2", ""), http.StatusNoContent)
}

func TestVoIPConfiguration(t *testing.T) {
	h := newHarness(t)
	if err := h.p.OnConfigurationChange(); err != nil {
		t.Fatal(err)
	}
	if err := h.p.OnConfigurationChange(); err != nil {
		t.Fatal(err)
	}
	if h.p.voip != nil || h.api.logCount("no APNs key is configured") != 1 {
		t.Fatal("VoIP without a key was not disabled and logged once")
	}

	// The APNs key comes from the secret configuration file next to the LiveKit secrets.
	_, keyPath := writeAPNsKey(t)
	file := filepath.Join(t.TempDir(), "plugin-config.json")
	data, _ := json.Marshal(map[string]any{"APNsKeyID": "KEY1234567", "APNsTeamID": "TEAM123456", "APNsKeyPath": keyPath})
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RELAY_CALLS_CONFIG_FILE", file)
	if err := h.p.OnConfigurationChange(); err != nil {
		t.Fatal(err)
	}
	if h.p.voip == nil || h.p.voip.keyID != "KEY1234567" || h.p.voip.teamID != "TEAM123456" || h.p.voip.baseURL != "" {
		t.Fatalf("the APNs key was not loaded: %+v", h.p.voip)
	}

	// Without a LiveKit secret in the plugin settings the whole file applies, as in version 1.
	data, _ = json.Marshal(map[string]any{
		"LiveKitURL": "wss://calls.example.com", "LiveKitInternalURL": h.server.URL, "LiveKitAPIKey": "test-key", "LiveKitAPISecret": "test-secret",
		"APNsKeyID": "KEY7654321", "APNsTeamID": "TEAM123456", "APNsKeyPath": keyPath, "RingTimeoutSeconds": 30,
	})
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	h.api.mu.Lock()
	h.api.settings = configuration{AnnounceCalls: true}
	h.api.mu.Unlock()
	if err := h.p.OnConfigurationChange(); err != nil {
		t.Fatal(err)
	}
	if !h.p.ready() || h.p.config.RingTimeoutSeconds != 30 || h.p.voip == nil || h.p.voip.keyID != "KEY7654321" {
		t.Fatalf("the secret file was not applied: %+v", h.p.config)
	}

	// An incomplete key disables VoIP with an error; calls keep working.
	data, _ = json.Marshal(map[string]any{
		"LiveKitURL": "wss://calls.example.com", "LiveKitInternalURL": h.server.URL, "LiveKitAPIKey": "test-key", "LiveKitAPISecret": "test-secret",
		"APNsKeyPath": keyPath,
	})
	if err := os.WriteFile(file, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := h.p.OnConfigurationChange(); err != nil {
		t.Fatal(err)
	}
	if h.p.voip != nil || h.api.logCount("could not be loaded") != 1 {
		t.Fatal("an incomplete APNs key did not disable VoIP")
	}
	alice, bob := h.user("alice"), h.user("bob")
	decodeJoin(t, invoke(h.p, alice, "POST", ringPath(h.channel("D", alice, bob)), `{"device_id":"alice-phone"}`))
}

func TestAPNsKeyMustBeP256(t *testing.T) {
	if _, err := parseAPNsKey([]byte("not a key")); err == nil {
		t.Fatal("a non-PEM key was accepted")
	}
	key, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parseAPNsKey(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})); err == nil {
		t.Fatal("a P-384 key was accepted")
	}
}
