package main

import (
	"encoding/json"
	"net/http"
	"path/filepath"
	"testing"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
)

func ringPath(channel string) string { return "/channels/" + channel + "/ring" }
func callPath(id, action string) string {
	if action == "" {
		return "/calls/" + id
	}
	return "/calls/" + id + "/" + action
}

func eventCallField(t *testing.T, event testEvent, field string) any {
	t.Helper()
	call, ok := event.data["call"].(map[string]any)
	if !ok {
		t.Fatalf("event %s has no call", event.name)
	}
	return call[field]
}

func recordProp(t *testing.T, post *model.Post, field string) any {
	t.Helper()
	props, ok := post.Props["relay_call"].(map[string]any)
	if !ok {
		t.Fatalf("post %s has no relay_call props", post.Id)
	}
	return props[field]
}

func TestDirectRingAcceptHangup(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)

	ring := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"video":true,"device_id":"alice-phone"}`))
	call := ring.Call
	if call.Kind != kindDirect || call.State != stateRinging || !call.Video || call.Invitees[bob] != inviteeRinging || !call.CanEnd {
		t.Fatalf("unexpected ringing call %+v", call)
	}
	if call.RingExpiresAt == nil || *call.RingExpiresAt != h.clock.Now().UnixMilli()+45_000 || call.EndAt != nil || call.DurationMs != nil {
		t.Fatalf("unexpected ring times %+v", call)
	}
	if ring.URL != "wss://calls.example.com" || h.lk.createdCount() != 1 {
		t.Fatal("the ring did not create the room")
	}
	claims := tokenClaims(t, ring.Token)
	if claims["sub"] != alice+":alice-phone" || claims["name"] != "Alice" {
		t.Fatalf("unexpected token identity %v (%v)", claims["sub"], claims["name"])
	}
	sources, _ := claims["video"].(map[string]any)["canPublishSources"].([]any)
	if len(sources) != 4 || sources[0] != "microphone" || sources[1] != "camera" || sources[2] != "screen_share" || sources[3] != "screen_share_audio" {
		t.Fatalf("unexpected publish sources %v", sources)
	}

	incoming := h.api.eventsNamed("incoming")
	if len(incoming) != 1 || incoming[0].userID != bob {
		t.Fatalf("incoming went to %+v", incoming)
	}
	caller, _ := incoming[0].data["caller"].(map[string]any)
	if caller["id"] != alice || caller["username"] != "alice" || caller["display_name"] != "Alice" || eventCallField(t, incoming[0], "state") != stateRinging {
		t.Fatalf("unexpected incoming data %v", incoming[0].data)
	}
	updated := h.api.eventsNamed("call_updated")
	if got := userRecipients(updated); len(got) != 2 || len(channelBroadcasts(updated)) != 1 {
		t.Fatalf("call_updated recipients %v", got)
	}
	if broadcast := channelBroadcasts(updated)[0]; broadcast.channel != channel || !broadcast.omit[alice] || !broadcast.omit[bob] || broadcast.data["channel_id"] != channel {
		t.Fatalf("unexpected channel broadcast %+v", broadcast)
	}

	if call.PostID != "" || h.stored(t, call.ID).PostID != "" {
		t.Fatal("a ringing direct call already has a record; Telegram adds it when the call ends")
	}

	h.api.resetEvents()
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "received"), `{"device_id":"bob-phone"}`), http.StatusNoContent)
	states := h.api.eventsNamed("call_state")
	if got := userRecipients(states); len(got) != 2 || states[0].data["action"] != "received" || states[0].data["device_id"] != "bob-phone" || states[0].data["user_id"] != bob {
		t.Fatalf("received events %+v", states)
	}
	if h.stored(t, call.ID).Invitees[bob] != inviteeReceived {
		t.Fatal("received was not stored")
	}

	h.clock.Advance(5 * time.Second)
	h.api.resetEvents()
	accept := decodeJoin(t, invoke(h.p, bob, "POST", callPath(call.ID, "accept"), `{"device_id":"bob-phone"}`))
	if accept.Call.State != stateActive || accept.Call.Invitees[bob] != inviteeAccepted || accept.Call.RingExpiresAt != nil || accept.Call.CanEnd {
		t.Fatalf("unexpected answered call %+v", accept.Call)
	}
	if tokenClaims(t, accept.Token)["sub"] != bob+":bob-phone" {
		t.Fatal("the answering device got another identity")
	}
	if states := h.api.eventsNamed("call_state"); len(states) != 2 || states[0].data["action"] != "accepted" {
		t.Fatalf("accepted events %+v", states)
	}
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "accept"), `{"device_id":"bob-tablet"}`), http.StatusConflict)

	h.connect(t, call.Room, alice+":alice-phone")
	h.connect(t, call.Room, bob+":bob-phone")
	if got := decodeCall(t, invoke(h.p, alice, "GET", callPath(call.ID, ""), "")); got.Participants != 2 || len(got.ParticipantIDs) != 2 {
		t.Fatalf("participants not tracked %+v", got)
	}

	h.clock.Advance(2*time.Minute + 5*time.Second)
	h.api.resetEvents()
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "hangup"), `{"device_id":"bob-phone"}`), http.StatusNoContent)
	if states := h.api.eventsNamed("call_state"); len(states) != 2 || states[0].data["action"] != "hangup" || eventCallField(t, states[0], "state") != stateEnded {
		t.Fatalf("hangup events %+v", states)
	}
	ended := h.api.eventsNamed("call_ended")
	if got := userRecipients(ended); len(got) != 2 || len(channelBroadcasts(ended)) != 1 || eventCallField(t, ended[0], "end_reason") != reasonHangup {
		t.Fatalf("call_ended events %+v", ended)
	}
	if !containsString(h.lk.deletedRooms(), call.Room) {
		t.Fatal("hangup kept the room")
	}
	got := decodeCall(t, invoke(h.p, alice, "GET", callPath(call.ID, ""), ""))
	if got.State != stateEnded || got.EndReason != reasonHangup || got.DurationMs == nil || *got.DurationMs != 125_000 || got.EndAt == nil || got.CanEnd || got.Participants != 0 {
		t.Fatalf("unexpected ended call %+v", got)
	}
	h.api.mu.Lock()
	retention := h.api.expiry[callKey(call.ID)]
	h.api.mu.Unlock()
	if retention != endedRetentionSeconds {
		t.Fatalf("ended call retention %d", retention)
	}
	post := h.api.post(h.stored(t, call.ID).PostID)
	if post == nil || post.Type != callRecordPostType || post.UserId != alice || post.ChannelId != channel || recordProp(t, post, "call_id") != call.ID || recordProp(t, post, "v") != 2 || recordProp(t, post, "kind") != kindDirect {
		t.Fatalf("unexpected call record %+v", post)
	}
	if post.Message != "Video call · 2 min" || recordProp(t, post, "end_reason") != reasonHangup || recordProp(t, post, "duration_ms") != int64(125_000) || recordProp(t, post, "state") != stateEnded {
		t.Fatalf("call record not updated: %q %v", post.Message, post.Props)
	}
	var current struct {
		Call *callView `json:"call"`
	}
	if err := json.Unmarshal(invoke(h.p, alice, "GET", "/channels/"+channel, "").Body.Bytes(), &current); err != nil || current.Call != nil {
		t.Fatal("the ended call is still current")
	}
}

func TestFirstDeviceWinsCompareAndSet(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	id := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call.ID
	h.api.mu.Lock()
	h.api.beforeCAS = func() {
		// Another of bob's devices answers between this request's read and its write.
		var other callState
		_ = json.Unmarshal(h.api.data[callKey(id)], &other)
		other.Invitees[bob] = inviteeAccepted
		other.Answered = map[string]string{bob: "bob-tablet"}
		other.AnsweredAt = h.clock.Now().UnixMilli()
		other.State = stateActive
		other.RingExpiresAt = 0
		data, _ := json.Marshal(&other)
		h.api.data[callKey(id)] = data
	}
	h.api.mu.Unlock()
	r := invoke(h.p, bob, "POST", callPath(id, "accept"), `{"device_id":"bob-phone"}`)
	expectStatus(t, r, http.StatusConflict)
	var body struct {
		Call callView `json:"call"`
	}
	if err := json.Unmarshal(r.Body.Bytes(), &body); err != nil || body.Call.Invitees[bob] != inviteeAccepted {
		t.Fatalf("the losing device did not get the current call: %s", r.Body.String())
	}
	if h.stored(t, id).Answered[bob] != "bob-tablet" {
		t.Fatal("the losing device overwrote the winner")
	}
}

func TestDirectDecline(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call
	h.api.resetEvents()
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "decline"), `{"device_id":"bob-phone","reason":"declined"}`), http.StatusNoContent)
	stored := h.stored(t, call.ID)
	if stored.State != stateEnded || stored.EndReason != reasonDeclined || stored.Invitees[bob] != inviteeDeclined || stored.DurationMs != 0 {
		t.Fatalf("unexpected declined call %+v", stored)
	}
	if states := h.api.eventsNamed("call_state"); len(states) != 2 || states[0].data["action"] != "declined" {
		t.Fatalf("declined events %+v", states)
	}
	if !containsString(h.lk.deletedRooms(), call.Room) || h.api.post(stored.PostID).Message != "Declined call" {
		t.Fatal("decline did not close the room and the record")
	}
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "decline"), `{"reason":"declined"}`), http.StatusNoContent)
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "decline"), `{"reason":"maybe"}`), http.StatusBadRequest)
	if len(h.api.pushList()) != 0 {
		t.Fatal("a declined call sent a missed call push")
	}
}

func TestDirectBusy(t *testing.T) {
	h := newHarness(t)
	alice, bob, carol := h.user("alice"), h.user("bob"), h.user("carol")
	carolBob := h.channel("D", carol, bob)
	aliceBob := h.channel("D", alice, bob)
	first := decodeJoin(t, invoke(h.p, carol, "POST", ringPath(carolBob), `{"device_id":"carol-phone"}`)).Call

	h.api.resetEvents()
	busy := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(aliceBob), `{"device_id":"alice-phone"}`))
	if busy.Call.State != stateEnded || busy.Call.EndReason != reasonBusy || busy.Call.Invitees[bob] != inviteeBusy || busy.URL == "" {
		t.Fatalf("a ringing callee was not busy: %+v", busy)
	}
	if grant, _ := tokenClaims(t, busy.Token)["video"].(map[string]any); grant["roomJoin"] != false || grant["canPublish"] != nil {
		t.Fatalf("the busy call's token can join: %v", grant)
	}
	if h.lk.createdCount() != 1 {
		t.Fatal("a busy call created a room")
	}
	if states := h.api.eventsNamed("call_state"); len(states) != 2 || states[0].data["action"] != "busy" || states[0].data["user_id"] != bob {
		t.Fatalf("busy events %+v", states)
	}
	if len(h.api.eventsNamed("incoming")) != 0 || h.api.post(busy.Call.PostID).Message != "Call · busy" {
		t.Fatal("a busy callee was rung")
	}
	if got := decodeCall(t, invoke(h.p, alice, "GET", callPath(busy.Call.ID, ""), "")); got.EndReason != reasonBusy {
		t.Fatal("the busy call is not readable")
	}

	expectStatus(t, invoke(h.p, bob, "POST", callPath(first.ID, "decline"), `{"device_id":"bob-phone","reason":"busy"}`), http.StatusNoContent)
	if stored := h.stored(t, first.ID); stored.EndReason != reasonBusy || stored.Invitees[bob] != inviteeBusy {
		t.Fatalf("a device answering busy did not end the call busy: %+v", stored)
	}
	again := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(aliceBob), `{"device_id":"alice-phone"}`))
	if again.Call.State != stateRinging || again.Token == "" {
		t.Fatalf("bob stayed busy after his call ended: %+v", again.Call)
	}
}

func TestDirectMissedAfterTimeout(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call

	h.clock.Advance(44 * time.Second)
	h.sweep()
	if h.stored(t, call.ID).State != stateRinging {
		t.Fatal("the ring expired early")
	}
	h.clock.Advance(2 * time.Second)
	h.api.resetEvents()
	h.sweep()
	stored := h.stored(t, call.ID)
	if stored.State != stateEnded || stored.EndReason != reasonMissed || stored.Invitees[bob] != inviteeMissed {
		t.Fatalf("unexpected missed call %+v", stored)
	}
	states := h.api.eventsNamed("call_state")
	if len(states) != 2 || states[0].data["action"] != "missed" || states[0].data["user_id"] != bob {
		t.Fatalf("missed events %+v", states)
	}
	if len(h.api.eventsNamed("call_ended")) != 3 || !containsString(h.lk.deletedRooms(), call.Room) {
		t.Fatal("the missed call was not ended")
	}
	if post := h.api.post(stored.PostID); post.Message != "Missed call" || recordProp(t, post, "end_reason") != reasonMissed {
		t.Fatalf("unexpected record %q", post.Message)
	}
	pushes := h.api.pushList()
	if len(pushes) != 1 || pushes[0].userID != bob || pushes[0].notification.Message != "Missed call from Alice" || pushes[0].notification.PostId != stored.PostID || pushes[0].notification.ChannelId != channel {
		t.Fatalf("unexpected missed call pushes %+v", pushes)
	}
	if _, reason := h.p.NotificationWillBePushed(pushes[0].notification, bob); reason != "" {
		t.Fatalf("the plugin's own missed call push was rejected: %s", reason)
	}
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "accept"), `{"device_id":"bob-phone"}`), http.StatusConflict)
	h.p.mu.Lock()
	index, _ := h.p.loadIndex()
	_, indexed := index.Calls[call.ID]
	h.p.mu.Unlock()
	if indexed {
		t.Fatal("the ended call stayed in the ringing index")
	}
}

func TestAcceptAfterExpiryBeforeSweep(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call
	h.clock.Advance(45 * time.Second)
	r := invoke(h.p, bob, "POST", callPath(call.ID, "accept"), `{"device_id":"bob-phone"}`)
	expectStatus(t, r, http.StatusConflict)
	var body struct {
		Call callView `json:"call"`
	}
	if err := json.Unmarshal(r.Body.Bytes(), &body); err != nil || body.Call.State != stateEnded || body.Call.EndReason != reasonMissed {
		t.Fatalf("accept after expiry: %s", r.Body.String())
	}
}

func TestCallerCancels(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "received"), `{"device_id":"bob-phone"}`), http.StatusNoContent)
	h.api.resetEvents()
	expectStatus(t, invoke(h.p, alice, "POST", callPath(call.ID, "hangup"), `{"device_id":"alice-phone"}`), http.StatusNoContent)
	stored := h.stored(t, call.ID)
	if stored.EndReason != reasonCancelled || stored.Invitees[bob] != inviteeMissed {
		t.Fatalf("unexpected cancelled call %+v", stored)
	}
	if states := h.api.eventsNamed("call_state"); len(states) != 2 || states[0].data["action"] != "cancelled" || states[0].data["user_id"] != alice {
		t.Fatalf("cancelled events %+v", states)
	}
	if h.api.post(stored.PostID).Message != "Cancelled call" || !containsString(h.lk.deletedRooms(), call.Room) {
		t.Fatal("cancel did not close the room and the record")
	}
	if pushes := h.api.pushList(); len(pushes) != 1 || pushes[0].userID != bob {
		t.Fatalf("no missed call push after cancel: %+v", pushes)
	}
	expectStatus(t, invoke(h.p, bob, "POST", callPath(call.ID, "received"), `{"device_id":"bob-phone"}`), http.StatusConflict)
}

func TestRingIsForConversations(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	open := h.channel("O", alice, bob)
	expectStatus(t, invoke(h.p, alice, "POST", ringPath(open), `{"device_id":"alice-phone"}`), http.StatusBadRequest)
	direct := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(direct), `{"device_id":"alice-phone"}`)).Call
	r := invoke(h.p, bob, "POST", ringPath(direct), `{"device_id":"bob-phone"}`)
	expectStatus(t, r, http.StatusConflict)
	var body struct {
		Call callView `json:"call"`
	}
	if err := json.Unmarshal(r.Body.Bytes(), &body); err != nil || body.Call.ID != call.ID || body.Call.Invitees[bob] != inviteeRinging {
		t.Fatalf("409 without the current call: %s", r.Body.String())
	}
	self := h.channel("D", alice)
	expectStatus(t, invoke(h.p, alice, "POST", ringPath(self), `{}`), http.StatusBadRequest)
	expectStatus(t, invoke(h.p, alice, "POST", ringPath(h.channel("D", alice, h.user("carol"))), `{"device_id":"bad:id"}`), http.StatusBadRequest)
	if r := invoke(h.p, h.user("mallory"), "GET", callPath(call.ID, ""), ""); r.Code != http.StatusForbidden {
		t.Fatalf("a non-member read the call: %d", r.Code)
	}
}

func TestJoinAnswersARingAndStartsWithoutRinging(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call
	joined := decodeJoin(t, invoke(h.p, bob, "POST", "/channels/"+channel+"/join", `{"call_id":"`+call.ID+`","device_id":"bob-mac"}`))
	if joined.Call.State != stateActive || joined.Call.Invitees[bob] != inviteeAccepted || tokenClaims(t, joined.Token)["sub"] != bob+":bob-mac" {
		t.Fatalf("join did not answer the ring: %+v", joined.Call)
	}

	other := h.channel("G", alice, bob, h.user("carol"))
	started := decodeJoin(t, invoke(h.p, alice, "POST", "/channels/"+other+"/join", `{}`))
	if started.Call.Kind != kindGroup || started.Call.State != stateActive || len(started.Call.Invitees) != 0 || len(h.api.eventsNamed("incoming")) != 1 {
		t.Fatalf("join rang or started the wrong call: %+v", started.Call)
	}
	if post := h.api.post(started.Call.PostID); post == nil || post.Message != "Group call" {
		t.Fatal("a started call has no record")
	}
}

func TestParticipantJoinAnswersTheRing(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call
	h.clock.Advance(3 * time.Second)
	h.connect(t, call.Room, bob+":bob-phone")
	stored := h.stored(t, call.ID)
	if stored.State != stateActive || stored.Invitees[bob] != inviteeAccepted || stored.AnsweredAt != h.clock.Now().UnixMilli() || stored.Answered[bob] != "bob-phone" {
		t.Fatalf("the first invitee to join did not answer: %+v", stored)
	}
	h.webhook(t, "room_finished", call.Room, "")
	if stored := h.stored(t, call.ID); stored.EndReason != reasonHangup {
		t.Fatalf("an answered direct call ended %q when its room finished", stored.EndReason)
	}
}

func TestGroupRingWithPartialAnswers(t *testing.T) {
	h := newHarness(t)
	alice, bob, carol, dave, erin := h.user("alice"), h.user("bob"), h.user("carol"), h.user("dave"), h.user("erin")
	// dave is in an answered direct call with erin.
	erinDave := h.channel("D", erin, dave)
	busyCall := decodeJoin(t, invoke(h.p, erin, "POST", ringPath(erinDave), `{"device_id":"erin-phone"}`)).Call
	decodeJoin(t, invoke(h.p, dave, "POST", callPath(busyCall.ID, "accept"), `{"device_id":"dave-phone"}`))

	group := h.channel("G", alice, bob, carol, dave)
	h.api.resetEvents()
	ring := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(group), `{"device_id":"alice-mac"}`))
	call := ring.Call
	if call.Kind != kindGroup || call.State != stateRinging || call.Invitees[bob] != inviteeRinging || call.Invitees[carol] != inviteeRinging || call.Invitees[dave] != inviteeBusy {
		t.Fatalf("unexpected group ring %+v", call)
	}
	if got := userRecipients(h.api.eventsNamed("incoming")); len(got) != 2 || !containsString(got, bob) || !containsString(got, carol) {
		t.Fatalf("incoming went to %v", got)
	}
	if states := h.api.eventsNamed("call_state"); len(states) != 4 || states[0].data["action"] != "busy" || states[0].data["user_id"] != dave {
		t.Fatalf("busy events %+v", states)
	}

	h.clock.Advance(5 * time.Second)
	answer := decodeJoin(t, invoke(h.p, bob, "POST", callPath(call.ID, "accept"), `{"device_id":"bob-phone"}`))
	if answer.Call.State != stateRinging || answer.Call.Invitees[bob] != inviteeAccepted || answer.Call.RingExpiresAt == nil {
		t.Fatalf("a group call stopped ringing for the others: %+v", answer.Call)
	}
	answeredAt := h.clock.Now().UnixMilli()
	h.connect(t, call.Room, alice+":alice-mac")
	h.connect(t, call.Room, bob+":bob-phone")

	h.clock.Advance(41 * time.Second)
	h.api.resetEvents()
	h.sweep()
	stored := h.stored(t, call.ID)
	if stored.State != stateActive || stored.Invitees[carol] != inviteeMissed || stored.RingExpiresAt != 0 {
		t.Fatalf("unexpected group call after the ring: %+v", stored)
	}
	if states := h.api.eventsNamed("call_state"); len(states) != 4 || states[0].data["action"] != "missed" || states[0].data["user_id"] != carol {
		t.Fatalf("missed events %+v", states)
	}
	if pushes := h.api.pushList(); len(pushes) != 1 || pushes[0].userID != carol || pushes[0].notification.Message != "Missed group call from Alice" {
		t.Fatalf("unexpected missed pushes %+v", pushes)
	}
	if len(h.api.eventsNamed("call_ended")) != 0 {
		t.Fatal("the group call ended with the ring")
	}

	// The creator hanging up only leaves; the call goes on until the room finishes.
	expectStatus(t, invoke(h.p, alice, "POST", callPath(call.ID, "hangup"), `{"device_id":"alice-mac"}`), http.StatusNoContent)
	if !containsString(h.lk.removedIdentities(), alice+":alice-mac") || h.stored(t, call.ID).State != stateActive {
		t.Fatal("hangup in a group call did not just leave")
	}
	h.webhook(t, "participant_left", call.Room, alice+":alice-mac")
	if stored := h.stored(t, call.ID); stored.Participants != 1 || len(stored.Identities) != 1 {
		t.Fatalf("participant_left not applied: %+v", stored)
	}

	h.clock.Advance(2 * time.Minute)
	h.api.resetEvents()
	h.webhook(t, "room_finished", call.Room, "")
	ended := h.stored(t, call.ID)
	if ended.State != stateEnded || ended.EndReason != reasonEnded || ended.DurationMs != h.clock.Now().UnixMilli()-answeredAt {
		t.Fatalf("unexpected ended group call %+v", ended)
	}
	events := h.api.eventsNamed("call_ended")
	if got := userRecipients(events); len(got) != 4 || len(channelBroadcasts(events)) != 1 {
		t.Fatalf("call_ended recipients %v", got)
	}
	if post := h.api.post(call.PostID); post.Message != "Group call · 2 min" {
		t.Fatalf("unexpected group record %q", post.Message)
	}
}

func TestGroupCreatorCancelsBeforeAnswer(t *testing.T) {
	h := newHarness(t)
	alice, bob, carol := h.user("alice"), h.user("bob"), h.user("carol")
	group := h.channel("G", alice, bob, carol)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(group), `{"video":true,"device_id":"alice-mac"}`)).Call
	expectStatus(t, invoke(h.p, carol, "POST", callPath(call.ID, "decline"), `{"device_id":"carol-phone"}`), http.StatusNoContent)
	if stored := h.stored(t, call.ID); stored.State != stateRinging || stored.Invitees[carol] != inviteeDeclined {
		t.Fatalf("a group decline ended the call: %+v", stored)
	}
	expectStatus(t, invoke(h.p, alice, "POST", callPath(call.ID, "hangup"), `{"device_id":"alice-mac"}`), http.StatusNoContent)
	stored := h.stored(t, call.ID)
	if stored.EndReason != reasonCancelled || stored.Invitees[bob] != inviteeMissed || stored.Invitees[carol] != inviteeDeclined {
		t.Fatalf("unexpected cancelled group call %+v", stored)
	}
	if h.api.post(call.PostID).Message != "Cancelled group video call" {
		t.Fatalf("unexpected record %q", h.api.post(call.PostID).Message)
	}
}

func TestActiveCalls(t *testing.T) {
	h := newHarness(t)
	alice, bob, carol := h.user("alice"), h.user("bob"), h.user("carol")
	direct := h.channel("D", alice, bob)
	ring := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(direct), `{"device_id":"alice-phone"}`)).Call
	h.clock.Advance(time.Second)
	shared := h.channel("O", bob, carol)
	panel := decodeJoin(t, invoke(h.p, carol, "POST", "/channels/"+shared+"/join", `{"device_id":"carol-mac"}`)).Call
	hidden := h.channel("P", alice, carol)
	decodeJoin(t, invoke(h.p, carol, "POST", "/channels/"+hidden+"/join", `{"device_id":"carol-mac"}`))

	r := invoke(h.p, bob, "GET", "/calls/active", "")
	expectStatus(t, r, http.StatusOK)
	var body struct {
		Calls []callView `json:"calls"`
	}
	if err := json.Unmarshal(r.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	if len(body.Calls) != 2 || body.Calls[0].ID != panel.ID || body.Calls[1].ID != ring.ID || body.Calls[1].Invitees[bob] != inviteeRinging {
		t.Fatalf("unexpected active calls %+v", body.Calls)
	}
	if body.Calls[0].Kind != kindChannel || body.Calls[0].Invitees != nil {
		t.Fatalf("a channel call has invitees: %+v", body.Calls[0])
	}
}

func TestRingExpirySurvivesRestart(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call

	// A new plugin process over the same KV store.
	restarted := &Plugin{client: h.server.Client(), now: h.clock.Now, sweepEvery: time.Hour}
	restarted.SetAPI(h.api)
	t.Setenv("RELAY_CALLS_CONFIG_FILE", filepath.Join(t.TempDir(), "missing.json"))
	if err := restarted.OnActivate(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = restarted.OnDeactivate() }()
	h.clock.Advance(46 * time.Second)
	restarted.sweep()
	restarted.pending.Wait()
	stored := h.stored(t, call.ID)
	if stored.State != stateEnded || stored.EndReason != reasonMissed {
		t.Fatalf("the ring did not expire after a restart: %+v", stored)
	}
	if len(h.api.pushList()) != 1 {
		t.Fatal("no missed call push after a restart")
	}
}

func TestCallRecordPushIsSuppressed(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("D", alice, bob)
	call := decodeJoin(t, invoke(h.p, alice, "POST", ringPath(channel), `{"device_id":"alice-phone"}`)).Call
	expectStatus(t, invoke(h.p, alice, "POST", callPath(call.ID, "hangup"), `{"device_id":"alice-phone"}`), http.StatusNoContent)
	record := h.stored(t, call.ID).PostID
	if _, reason := h.p.NotificationWillBePushed(&model.PushNotification{PostId: record, ChannelId: channel, Message: "Cancelled call"}, bob); reason == "" {
		t.Fatal("the call record's alert push was not suppressed")
	}
	if replacement, reason := h.p.NotificationWillBePushed(&model.PushNotification{PostId: record, ChannelId: channel, Message: "Missed call from Alice"}, bob); reason != "" || replacement != nil {
		t.Fatal("the plugin's own missed-call push was suppressed")
	}
	message, _ := h.api.CreatePost(&model.Post{UserId: alice, ChannelId: channel, Message: "hello"})
	if replacement, reason := h.p.NotificationWillBePushed(&model.PushNotification{PostId: message.Id, ChannelId: channel}, bob); reason != "" || replacement != nil {
		t.Fatal("an ordinary message push was changed")
	}
	if _, reason := h.p.NotificationWillBePushed(&model.PushNotification{PostId: model.NewId(), ChannelId: model.NewId()}, bob); reason != "" {
		t.Fatal("a push in another channel was rejected")
	}
}

func TestVersion1RecordMigrates(t *testing.T) {
	h := newHarness(t)
	alice, bob := h.user("alice"), h.user("bob")
	channel := h.channel("O", alice, bob)
	legacy := map[string]any{"id": model.NewId(), "channel_id": channel, "room": "relay_legacy", "started_by": alice, "started_at": h.clock.Now().UnixMilli(), "participants": 1, "can_end": false}
	data, _ := json.Marshal(legacy)
	h.api.mu.Lock()
	h.api.data[channelKey(channel)] = data
	h.api.data[roomKey("relay_legacy")] = []byte(channel)
	h.api.mu.Unlock()
	h.lk.setConnected("relay_legacy", alice+":old", true)
	h.lk.mu.Lock()
	h.lk.rooms["relay_legacy"] = true
	h.lk.mu.Unlock()
	joined := decodeJoin(t, invoke(h.p, bob, "POST", "/channels/"+channel+"/join", `{}`))
	if joined.Call.ID != legacy["id"] || joined.Call.Kind != kindChannel || joined.Call.State != stateActive || joined.Call.Participants != 1 {
		t.Fatalf("version 1 call not joined: %+v", joined.Call)
	}
	if string(h.api.value(channelKey(channel))) != legacy["id"] {
		t.Fatal("version 1 record not migrated")
	}
}
