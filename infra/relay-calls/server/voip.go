package main

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
)

const (
	apnsProductionURL = "https://api.push.apple.com"
	apnsSandboxURL    = "https://api.sandbox.push.apple.com"
	// APNs accepts a provider token for an hour and rejects refreshes more often than every 20 minutes.
	apnsTokenLifetime = 50 * time.Minute
)

// apnsSender sends VoIP pushes to APNs over HTTP/2 with a provider token (ES256 JWT) from a .p8 key.
type apnsSender struct {
	keyID   string
	teamID  string
	key     *ecdsa.PrivateKey
	client  *http.Client
	baseURL string
	now     func() time.Time

	mu       sync.Mutex
	token    string
	issuedAt time.Time
}

type voipDevice struct {
	Token       string `json:"token"`
	Environment string `json:"environment"`
	BundleID    string `json:"bundle_id"`
	SessionID   string `json:"session_id,omitempty"`
	UpdatedAt   int64  `json:"updated_at"`
}

type voipJob struct {
	userID      string
	deviceID    string
	token       string
	environment string
	topic       string
	payload     []byte
}

// newAPNsSender returns nil without an error when no key is configured (VoIP disabled).
func newAPNsSender(c configuration, client *http.Client) (*apnsSender, error) {
	if c.APNsKeyPath == "" && c.APNsKeyID == "" && c.APNsTeamID == "" {
		return nil, nil
	}
	if c.APNsKeyPath == "" || c.APNsKeyID == "" || c.APNsTeamID == "" {
		return nil, errors.New("APNsKeyPath, APNsKeyID and APNsTeamID must all be set")
	}
	data, err := os.ReadFile(c.APNsKeyPath)
	if err != nil {
		return nil, errors.New("could not read the APNs key file")
	}
	key, err := parseAPNsKey(data)
	if err != nil {
		return nil, err
	}
	baseURL := strings.TrimRight(c.APNsBaseURL, "/")
	if baseURL != "" {
		u, err := url.Parse(baseURL)
		if err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
			return nil, errors.New("APNsBaseURL must be an HTTPS URL without credentials")
		}
	}
	if client == nil {
		client = &http.Client{
			Timeout: 10 * time.Second,
			Transport: &http.Transport{
				Proxy:               http.ProxyFromEnvironment,
				ForceAttemptHTTP2:   true,
				TLSClientConfig:     &tls.Config{MinVersion: tls.VersionTLS12},
				MaxIdleConnsPerHost: 4,
				IdleConnTimeout:     5 * time.Minute,
			},
		}
	}
	return &apnsSender{keyID: c.APNsKeyID, teamID: c.APNsTeamID, key: key, client: client, baseURL: baseURL}, nil
}

func parseAPNsKey(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("the APNs key is not PEM encoded")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, errors.New("the APNs key is not a PKCS #8 private key")
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok || key.Curve.Params().Name != "P-256" {
		return nil, errors.New("the APNs key is not a P-256 key")
	}
	return key, nil
}

func (s *apnsSender) clock() time.Time {
	if s.now != nil {
		return s.now()
	}
	return time.Now()
}

// bearer returns the cached provider token, signing a new one when it is older than apnsTokenLifetime.
func (s *apnsSender) bearer() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.clock()
	if s.token != "" && !now.Before(s.issuedAt) && now.Sub(s.issuedAt) < apnsTokenLifetime {
		return s.token, nil
	}
	header, err := json.Marshal(map[string]string{"alg": "ES256", "kid": s.keyID})
	if err != nil {
		return "", err
	}
	claims, err := json.Marshal(map[string]any{"iss": s.teamID, "iat": now.Unix()})
	if err != nil {
		return "", err
	}
	unsigned := base64.RawURLEncoding.EncodeToString(header) + "." + base64.RawURLEncoding.EncodeToString(claims)
	digest := sha256.Sum256([]byte(unsigned))
	r, sig, err := ecdsa.Sign(rand.Reader, s.key, digest[:])
	if err != nil {
		return "", err
	}
	signature := make([]byte, 64)
	r.FillBytes(signature[:32])
	sig.FillBytes(signature[32:])
	s.token = unsigned + "." + base64.RawURLEncoding.EncodeToString(signature)
	s.issuedAt = now
	return s.token, nil
}

func (s *apnsSender) resetBearer() {
	s.mu.Lock()
	s.token = ""
	s.mu.Unlock()
}

// send posts one VoIP push and returns the APNs status and reason.
func (s *apnsSender) send(environment, deviceToken, topic string, payload []byte, expiration int64, collapseID string) (int, string, error) {
	bearer, err := s.bearer()
	if err != nil {
		return 0, "", err
	}
	host := s.baseURL
	if host == "" {
		host = apnsSandboxURL
		if environment == "production" {
			host = apnsProductionURL
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, host+"/3/device/"+deviceToken, bytes.NewReader(payload))
	if err != nil {
		return 0, "", err
	}
	req.Header.Set("authorization", "bearer "+bearer)
	req.Header.Set("apns-push-type", "voip")
	req.Header.Set("apns-topic", topic)
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", strconv.FormatInt(expiration, 10))
	req.Header.Set("apns-collapse-id", collapseID)
	req.Header.Set("content-type", "application/json")
	response, err := s.client.Do(req)
	if err != nil {
		return 0, "", errors.New("APNs request failed")
	}
	defer response.Body.Close()
	var failure struct {
		Reason string `json:"reason"`
	}
	if response.StatusCode != http.StatusOK {
		_ = json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&failure)
		if response.StatusCode == http.StatusForbidden && (failure.Reason == "ExpiredProviderToken" || failure.Reason == "InvalidProviderToken") {
			s.resetBearer()
		}
	}
	return response.StatusCode, failure.Reason, nil
}

// sendRings wakes the invitees' registered iOS devices. Registrations whose Mattermost session is gone are
// dropped here; tokens APNs reports gone are dropped after the send.
func (p *Plugin) sendRings(call *callState, caller *model.User, users []string) {
	sender := p.voip
	if sender == nil || len(users) == 0 {
		return
	}
	siteURL := ""
	if cfg := p.API.GetConfig(); cfg != nil && cfg.ServiceSettings.SiteURL != nil {
		siteURL = strings.TrimRight(*cfg.ServiceSettings.SiteURL, "/")
	}
	callerName := displayName(caller)
	var jobs []voipJob
	for _, userID := range users {
		devices, err := p.loadDevices(userID)
		if err != nil || len(devices) == 0 {
			continue
		}
		ids := make([]string, 0, len(devices))
		for id := range devices {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		changed := false
		for _, deviceID := range ids {
			device := devices[deviceID]
			if !p.sessionValid(device.SessionID, userID) {
				delete(devices, deviceID)
				changed = true
				continue
			}
			payload, err := json.Marshal(map[string]any{"relay_call": map[string]any{
				"v": contractVersion, "call_id": call.ID, "channel_id": call.ChannelID, "caller_id": call.StartedBy,
				"caller_name": callerName, "video": call.Video, "ring_expires_at": call.RingExpiresAt,
				"server_url": siteURL, "recipient_id": userID,
			}})
			if err != nil {
				continue
			}
			jobs = append(jobs, voipJob{userID: userID, deviceID: deviceID, token: device.Token, environment: device.Environment, topic: device.BundleID + ".voip", payload: payload})
		}
		if changed {
			if err := p.saveDevices(userID, devices); err != nil {
				p.API.LogWarn("Could not remove expired VoIP registrations", "user_id", userID)
			}
		}
	}
	if len(jobs) == 0 {
		return
	}
	expiration := call.RingExpiresAt / 1000
	callID := call.ID
	p.goAsync(func() {
		for _, job := range jobs {
			status, reason, err := sender.send(job.environment, job.token, job.topic, job.payload, expiration, callID)
			switch {
			case err != nil:
				p.API.LogWarn("Could not send a VoIP push", "call_id", callID, "user_id", job.userID)
			case status == http.StatusGone || reason == "BadDeviceToken" || reason == "Unregistered":
				p.mu.Lock()
				p.dropDevice(job.userID, job.deviceID, job.token)
				p.mu.Unlock()
			case status != http.StatusOK:
				p.API.LogWarn("APNs refused a VoIP push", "call_id", callID, "status", status, "reason", reason)
			}
		}
	})
}

// sessionValid ties a registration to the Mattermost session that made it. A lookup failing on the server
// side (5xx) keeps the registration.
func (p *Plugin) sessionValid(sessionID, userID string) bool {
	if sessionID == "" {
		return true
	}
	session, appErr := p.API.GetSession(sessionID)
	if appErr != nil {
		return appErr.StatusCode >= http.StatusInternalServerError
	}
	return session != nil && session.UserId == userID && !session.IsExpired()
}

// Device routes: POST /devices/voip, DELETE /devices/voip/<device_id>.
func (p *Plugin) serveDevices(w http.ResponseWriter, r *http.Request, userID, sessionID string, parts []string) {
	if len(parts) < 2 || len(parts) > 3 || parts[1] != "voip" {
		fail(w, http.StatusNotFound, "Unknown call endpoint.")
		return
	}
	if len(parts) == 3 {
		if r.Method != http.MethodDelete {
			fail(w, http.StatusMethodNotAllowed, "This route requires DELETE.")
			return
		}
		if !validDeviceID(parts[2]) {
			fail(w, http.StatusBadRequest, "Invalid device.")
			return
		}
		devices, err := p.loadDevices(userID)
		if err != nil {
			fail(w, http.StatusInternalServerError, "Could not load VoIP devices.")
			return
		}
		if _, ok := devices[parts[2]]; ok {
			delete(devices, parts[2])
			if err := p.saveDevices(userID, devices); err != nil {
				fail(w, http.StatusInternalServerError, "Could not save VoIP devices.")
				return
			}
		}
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if r.Method != http.MethodPost {
		fail(w, http.StatusMethodNotAllowed, "This route requires POST.")
		return
	}
	var input callInput
	if !decodeInput(w, r, &input) {
		return
	}
	token := strings.ToLower(input.Token)
	if !validDeviceID(input.DeviceID) || !validAPNsToken(token) || (input.Environment != "sandbox" && input.Environment != "production") || !validBundleID(input.BundleID) {
		fail(w, http.StatusBadRequest, "Invalid VoIP registration.")
		return
	}
	devices, err := p.loadDevices(userID)
	if err != nil {
		fail(w, http.StatusInternalServerError, "Could not load VoIP devices.")
		return
	}
	for id, device := range devices {
		if id != input.DeviceID && device.Token == token {
			delete(devices, id)
		}
	}
	devices[input.DeviceID] = voipDevice{Token: token, Environment: input.Environment, BundleID: input.BundleID, SessionID: sessionID, UpdatedAt: p.clock().UnixMilli()}
	for len(devices) > maxVoIPDevices {
		oldest := ""
		for id, device := range devices {
			if oldest == "" || device.UpdatedAt < devices[oldest].UpdatedAt {
				oldest = id
			}
		}
		delete(devices, oldest)
	}
	if err := p.saveDevices(userID, devices); err != nil {
		fail(w, http.StatusInternalServerError, "Could not save VoIP devices.")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func validAPNsToken(token string) bool {
	if len(token) < 64 || len(token) > 200 || len(token)%2 != 0 {
		return false
	}
	for _, r := range token {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

func validBundleID(id string) bool {
	if id == "" || len(id) > 155 {
		return false
	}
	for _, r := range id {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '.' || r == '-') {
			return false
		}
	}
	return true
}
