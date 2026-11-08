package main

import (
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
)

const (
	kindDirect  = "direct"
	kindGroup   = "group"
	kindChannel = "channel"

	stateRinging = "ringing"
	stateActive  = "active"
	stateEnded   = "ended"

	inviteeRinging  = "ringing"
	inviteeReceived = "received"
	inviteeAccepted = "accepted"
	inviteeDeclined = "declined"
	inviteeBusy     = "busy"
	inviteeMissed   = "missed"

	reasonMissed    = "missed"
	reasonCancelled = "cancelled"
	reasonDeclined  = "declined"
	reasonBusy      = "busy"
	reasonHangup    = "hangup"
	reasonEnded     = "ended"
	reasonFailed    = "failed"

	reconcileInterval = 30 * time.Second
	// roomSettleMs keeps the reconciler away from rooms that were created a moment ago.
	roomSettleMs = 60_000
)

// callState is the stored call (KV "call:<id>"). Version 1 records (no kind/state) load as active channel calls.
type callState struct {
	ID            string            `json:"id"`
	ChannelID     string            `json:"channel_id"`
	Room          string            `json:"room"`
	Kind          string            `json:"kind,omitempty"`
	State         string            `json:"state,omitempty"`
	Video         bool              `json:"video,omitempty"`
	StartedBy     string            `json:"started_by"`
	StartedAt     int64             `json:"started_at"`
	RingExpiresAt int64             `json:"ring_expires_at,omitempty"`
	AnsweredAt    int64             `json:"answered_at,omitempty"`
	EndReason     string            `json:"end_reason,omitempty"`
	EndAt         int64             `json:"end_at,omitempty"`
	DurationMs    int64             `json:"duration_ms,omitempty"`
	Participants  int               `json:"participants"`
	Identities    []string          `json:"identities,omitempty"`
	Invitees      map[string]string `json:"invitees,omitempty"`
	Answered      map[string]string `json:"answered,omitempty"`
	PostID        string            `json:"post_id,omitempty"`
}

// callView is the wire call object of contract version 2.
type callView struct {
	ID             string            `json:"id"`
	ChannelID      string            `json:"channel_id"`
	Room           string            `json:"room"`
	Kind           string            `json:"kind"`
	State          string            `json:"state"`
	Video          bool              `json:"video"`
	StartedBy      string            `json:"started_by"`
	StartedAt      int64             `json:"started_at"`
	RingExpiresAt  *int64            `json:"ring_expires_at,omitempty"`
	EndReason      string            `json:"end_reason,omitempty"`
	EndAt          *int64            `json:"end_at,omitempty"`
	DurationMs     *int64            `json:"duration_ms,omitempty"`
	Participants   int               `json:"participants"`
	ParticipantIDs []string          `json:"participant_ids"`
	Invitees       map[string]string `json:"invitees,omitempty"`
	PostID         string            `json:"post_id,omitempty"`
	CanEnd         bool              `json:"can_end"`
}

// viewer computes can_end for one user. Without an owner (event recipients) only the starter may end.
type viewer struct {
	owner  *Plugin
	userID string
	admins map[string]bool
	system *bool
}

type stateEvent struct {
	userID   string
	deviceID string
	action   string
}

func (p *Plugin) newViewer(userID string) *viewer {
	return &viewer{owner: p, userID: userID, admins: map[string]bool{}}
}

func (v *viewer) canEnd(call *callState) bool {
	if v == nil || call == nil || call.State == stateEnded {
		return false
	}
	if call.StartedBy == v.userID || v.admins[call.ChannelID] {
		return true
	}
	if v.owner == nil {
		return false
	}
	if v.system == nil {
		allowed := v.owner.API.HasPermissionTo(v.userID, model.PermissionManageSystem)
		v.system = &allowed
	}
	return *v.system
}

func (c *callState) normalize() {
	if c.Kind == "" {
		c.Kind = kindChannel
	}
	if c.State == "" {
		c.State = stateActive
		if c.AnsweredAt == 0 {
			c.AnsweredAt = c.StartedAt
		}
	}
}

// updateRinging keeps the invariant: a live call is ringing exactly while some invitee still rings.
func (c *callState) updateRinging() {
	if c.State == stateEnded {
		return
	}
	for _, status := range c.Invitees {
		if isRinging(status) {
			c.State = stateRinging
			return
		}
	}
	c.State = stateActive
	c.RingExpiresAt = 0
}

func isRinging(status string) bool {
	return status == inviteeRinging || status == inviteeReceived
}

func viewOf(call *callState, v *viewer) callView {
	out := callView{
		ID: call.ID, ChannelID: call.ChannelID, Room: call.Room, Kind: call.Kind, State: call.State, Video: call.Video,
		StartedBy: call.StartedBy, StartedAt: call.StartedAt, Participants: call.Participants,
		ParticipantIDs: distinctUsers(call.Identities), PostID: call.PostID,
	}
	if call.State == stateRinging && call.RingExpiresAt > 0 {
		expires := call.RingExpiresAt
		out.RingExpiresAt = &expires
	}
	if call.State == stateEnded {
		endAt, duration := call.EndAt, call.DurationMs
		out.EndReason = call.EndReason
		out.EndAt = &endAt
		out.DurationMs = &duration
	}
	if call.Kind != kindChannel && len(call.Invitees) > 0 {
		out.Invitees = make(map[string]string, len(call.Invitees))
		for userID, status := range call.Invitees {
			out.Invitees[userID] = status
		}
	}
	out.CanEnd = v.canEnd(call)
	return out
}

// eventMap is the view as plugin RPC can carry it (gob: only basic types and map[string]any).
func (v callView) eventMap() map[string]any {
	ids := v.ParticipantIDs
	if ids == nil {
		ids = []string{}
	}
	m := map[string]any{
		"id": v.ID, "channel_id": v.ChannelID, "room": v.Room, "kind": v.Kind, "state": v.State, "video": v.Video,
		"started_by": v.StartedBy, "started_at": v.StartedAt, "participants": v.Participants,
		"participant_ids": ids, "can_end": v.CanEnd,
	}
	if v.PostID != "" {
		m["post_id"] = v.PostID
	}
	if v.RingExpiresAt != nil {
		m["ring_expires_at"] = *v.RingExpiresAt
	}
	if v.EndReason != "" {
		m["end_reason"] = v.EndReason
	}
	if v.EndAt != nil {
		m["end_at"] = *v.EndAt
	}
	if v.DurationMs != nil {
		m["duration_ms"] = *v.DurationMs
	}
	if len(v.Invitees) > 0 {
		invitees := make(map[string]any, len(v.Invitees))
		for userID, status := range v.Invitees {
			invitees[userID] = status
		}
		m["invitees"] = invitees
	}
	return m
}

func distinctUsers(identities []string) []string {
	seen := map[string]bool{}
	users := []string{}
	for _, identity := range identities {
		userID, _, _ := strings.Cut(identity, ":")
		if userID != "" && !seen[userID] {
			seen[userID] = true
			users = append(users, userID)
		}
	}
	sort.Strings(users)
	return users
}

func hasUser(identities []string, userID string) bool {
	for _, identity := range identities {
		if strings.HasPrefix(identity, userID+":") {
			return true
		}
	}
	return false
}

func containsString(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}

func removeString(values []string, value string) []string {
	out := values[:0]
	for _, candidate := range values {
		if candidate != value {
			out = append(out, candidate)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func channelKind(channel *model.Channel) string {
	switch string(channel.Type) {
	case "D":
		return kindDirect
	case "G":
		return kindGroup
	default:
		return kindChannel
	}
}

func roomGoneReason(call *callState) string {
	switch {
	case call.State == stateRinging:
		return reasonFailed
	case call.Kind == kindDirect && call.AnsweredAt > 0:
		return reasonHangup
	default:
		return reasonEnded
	}
}

// userBusy reports whether userID is in another live call: connected to it, ringing in it, dialing from it,
// or a party of an answered direct call.
func userBusy(calls []*callState, userID string) bool {
	for _, call := range calls {
		if call.State == stateEnded {
			continue
		}
		if hasUser(call.Identities, userID) {
			return true
		}
		if call.Kind == kindChannel {
			continue
		}
		status := call.Invitees[userID]
		if isRinging(status) || (call.StartedBy == userID && call.State == stateRinging) {
			return true
		}
		if call.Kind == kindDirect && call.State == stateActive && (call.StartedBy == userID || status == inviteeAccepted) {
			return true
		}
	}
	return false
}

// Channel routes: GET /channels/<id>, POST /channels/<id>/{join,ring,end}.
func (p *Plugin) serveChannel(w http.ResponseWriter, r *http.Request, userID string, parts []string) {
	if len(parts) < 2 || len(parts) > 3 || !model.IsValidId(parts[1]) {
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
		p.expireIfDue(call)
		if call.State != stateEnded {
			if err := p.refreshCall(r.Context(), call); err != nil {
				fail(w, http.StatusBadGateway, "The calling service is temporarily unavailable.")
				return
			}
		}
		if call.State == stateEnded {
			call = nil
		}
	}
	v := p.newViewer(userID)
	v.admins[channelID] = member.SchemeAdmin
	if len(parts) == 2 && r.Method == http.MethodGet {
		var current *callView
		if call != nil {
			view := viewOf(call, v)
			current = &view
		}
		writeJSON(w, map[string]any{"call": current})
		return
	}
	if len(parts) != 3 || r.Method != http.MethodPost {
		fail(w, http.StatusMethodNotAllowed, "This call action requires POST.")
		return
	}
	var input callInput
	if !decodeInput(w, r, &input) {
		return
	}
	if input.CallID != "" && (call == nil || call.ID != input.CallID) {
		fail(w, http.StatusConflict, "This call has ended. Refresh the channel to join a new call.")
		return
	}
	switch parts[2] {
	case "join":
		p.handleJoin(w, r, userID, channel, v, call, input)
	case "ring":
		p.handleRing(w, r, userID, channel, v, call, input)
	case "end":
		p.handleEnd(w, r, v, call)
	default:
		fail(w, http.StatusNotFound, "Unknown call action.")
	}
}

func (p *Plugin) handleJoin(w http.ResponseWriter, r *http.Request, userID string, channel *model.Channel, v *viewer, call *callState, input callInput) {
	user, ok := p.activeUser(userID)
	if !ok {
		fail(w, http.StatusForbidden, "This account is unavailable.")
		return
	}
	deviceID := input.DeviceID
	if deviceID == "" {
		deviceID = model.NewId()
	} else if !validDeviceID(deviceID) {
		fail(w, http.StatusBadRequest, "Invalid device.")
		return
	}
	if call == nil {
		started, status, message := p.startCall(r.Context(), channel, user, false, false)
		if status != 0 {
			fail(w, status, message)
			return
		}
		call = started
	} else if isRinging(call.Invitees[userID]) {
		// Joining a call that rings for this user answers it.
		if status, message := p.acceptCall(call, userID, deviceID); status != 0 {
			failWithCall(w, status, message, call, v)
			return
		}
	}
	if call.Participants >= p.config.MaxParticipants {
		fail(w, http.StatusConflict, "This call has reached the server's participant limit.")
		return
	}
	p.writeJoin(w, call, user, deviceID, v)
}

func (p *Plugin) handleRing(w http.ResponseWriter, r *http.Request, userID string, channel *model.Channel, v *viewer, call *callState, input callInput) {
	kind := channelKind(channel)
	if kind != kindDirect && kind != kindGroup {
		fail(w, http.StatusBadRequest, "Only direct and group messages ring.")
		return
	}
	if call != nil {
		failWithCall(w, http.StatusConflict, "A call is already in progress in this conversation.", call, v)
		return
	}
	user, ok := p.activeUser(userID)
	if !ok {
		fail(w, http.StatusForbidden, "This account is unavailable.")
		return
	}
	deviceID := input.DeviceID
	if deviceID == "" {
		deviceID = model.NewId()
	} else if !validDeviceID(deviceID) {
		fail(w, http.StatusBadRequest, "Invalid device.")
		return
	}
	started, status, message := p.startCall(r.Context(), channel, user, true, input.Video)
	if status != 0 {
		fail(w, status, message)
		return
	}
	token, err := p.roomToken(started, user, deviceID)
	if started.State == stateEnded {
		// Busy before it started: there is no room, and this token cannot join one (clients require a token).
		token, err = signToken(p.config.LiveKitAPIKey, p.config.LiveKitAPISecret, user.Id+":"+deviceID, displayName(user), map[string]any{"room": started.Room, "roomJoin": false}, time.Minute, "")
	}
	if err != nil {
		fail(w, http.StatusInternalServerError, "Could not authorize the call.")
		return
	}
	writeJSON(w, joinResponse{URL: p.config.LiveKitURL, Token: token, Call: viewOf(started, v)})
}

func (p *Plugin) handleEnd(w http.ResponseWriter, r *http.Request, v *viewer, call *callState) {
	if !v.canEnd(call) {
		fail(w, http.StatusForbidden, "Only the call starter or a channel administrator can end this call.")
		return
	}
	if err := p.roomRequest(r.Context(), "DeleteRoom", map[string]any{"room": call.Room}, nil); err != nil {
		fail(w, http.StatusBadGateway, "Could not end the call. Please try again.")
		return
	}
	reason := reasonEnded
	switch {
	case call.Kind != kindChannel && call.AnsweredAt == 0:
		reason = reasonCancelled
	case call.Kind == kindDirect:
		reason = reasonHangup
	}
	var states []stateEvent
	if reason == reasonCancelled {
		states = append(states, stateEvent{userID: v.userID, action: "cancelled"})
	}
	p.finishCall(call, reason, false, states...)
	writeJSON(w, map[string]bool{"ok": true})
}

// startCall creates a call in channel. With ring, every other member is invited; a direct call whose
// invitee is busy ends at once (busy) without a room.
func (p *Plugin) startCall(ctx context.Context, channel *model.Channel, caller *model.User, ring, video bool) (*callState, int, string) {
	now := p.clock().UnixMilli()
	call := &callState{ID: model.NewId(), ChannelID: channel.Id, Kind: channelKind(channel), State: stateActive, Video: video, StartedBy: caller.Id, StartedAt: now}
	call.Room = "relay_" + call.ID
	var ringing, busy []string
	if ring {
		invitees, err := p.inviteesFor(channel.Id, caller.Id)
		if err != nil {
			return nil, http.StatusInternalServerError, "Could not load this conversation's members."
		}
		if len(invitees) == 0 {
			return nil, http.StatusBadRequest, "There is nobody to call in this conversation."
		}
		live := p.liveCalls(call.ID)
		call.Invitees = make(map[string]string, len(invitees))
		for _, userID := range invitees {
			if userBusy(live, userID) {
				call.Invitees[userID] = inviteeBusy
				busy = append(busy, userID)
			} else {
				call.Invitees[userID] = inviteeRinging
				ringing = append(ringing, userID)
			}
		}
		if len(ringing) > 0 {
			call.State = stateRinging
			call.RingExpiresAt = now + int64(p.config.RingTimeoutSeconds)*1000
		}
	} else {
		call.AnsweredAt = now
	}
	allBusy := ring && len(ringing) == 0 && call.Kind == kindDirect
	if allBusy {
		call.State, call.EndReason, call.EndAt = stateEnded, reasonBusy, now
	} else if err := p.roomRequest(ctx, "CreateRoom", map[string]any{"name": call.Room, "empty_timeout": 120, "departure_timeout": 30, "max_participants": p.config.MaxParticipants, "metadata": channel.Id}, nil); err != nil {
		return nil, http.StatusBadGateway, "Could not start the call. Please try again."
	}
	if err := p.saveCall(call); err != nil {
		if !allBusy {
			_ = p.roomRequest(ctx, "DeleteRoom", map[string]any{"room": call.Room}, nil)
		}
		return nil, http.StatusInternalServerError, "Could not save the call."
	}
	if p.createRecord(call) {
		if err := p.saveCall(call); err != nil {
			p.API.LogWarn("Could not link the call record", "call_id", call.ID)
		}
	}
	for _, userID := range busy {
		p.publishState(call, stateEvent{userID: userID, action: "busy"})
	}
	if allBusy {
		p.publishEnded(call)
		return call, 0, ""
	}
	p.publishUpdated(call)
	if len(ringing) > 0 {
		info := callerInfo(caller)
		for _, userID := range ringing {
			p.publishToUser("incoming", userID, map[string]any{"call": eventCall(call, userID), "caller": info})
		}
		p.sendRings(call, caller, ringing)
	}
	return call, 0, ""
}

// inviteesFor lists the channel's other active, human members.
func (p *Plugin) inviteesFor(channelID, callerID string) ([]string, error) {
	var invitees []string
	for page := 0; page < 10; page++ {
		members, appErr := p.API.GetChannelMembers(channelID, page, 100)
		if appErr != nil {
			return nil, appErr
		}
		for _, member := range members {
			if member.UserId == callerID || containsString(invitees, member.UserId) {
				continue
			}
			user, ok := p.activeUser(member.UserId)
			if !ok || user.IsBot {
				continue
			}
			invitees = append(invitees, member.UserId)
		}
		if len(members) < 100 {
			break
		}
	}
	sort.Strings(invitees)
	return invitees, nil
}

// acceptCall marks userID as having answered on deviceID. The first device wins: the record is written with
// compare-and-set, and a device that loses sees the call no longer ringing for its user (409).
func (p *Plugin) acceptCall(call *callState, userID, deviceID string) (int, string) {
	for attempt := 0; attempt < 3; attempt++ {
		current, raw, err := p.loadCallByID(call.ID)
		if err != nil {
			return http.StatusInternalServerError, "Could not load this call."
		}
		if current == nil {
			return http.StatusNotFound, "This call is no longer available."
		}
		*call = *current
		if p.expireIfDue(call) || call.State == stateEnded || !isRinging(call.Invitees[userID]) {
			return http.StatusConflict, "This call is no longer ringing for you."
		}
		call.Invitees[userID] = inviteeAccepted
		if call.Answered == nil {
			call.Answered = map[string]string{}
		}
		call.Answered[userID] = deviceID
		if call.AnsweredAt == 0 {
			call.AnsweredAt = p.clock().UnixMilli()
		}
		call.updateRinging()
		data, err := json.Marshal(call)
		if err != nil {
			return http.StatusInternalServerError, "Could not answer the call."
		}
		won, appErr := p.API.KVCompareAndSet(callKey(call.ID), raw, data)
		if appErr != nil {
			return http.StatusInternalServerError, "Could not answer the call."
		}
		if !won {
			continue
		}
		if err := p.syncPointers(call); err != nil {
			p.API.LogWarn("Could not index the answered call", "call_id", call.ID)
		}
		p.publishState(call, stateEvent{userID: userID, deviceID: deviceID, action: "accepted"})
		p.publishUpdated(call)
		return 0, ""
	}
	if current, _, err := p.loadCallByID(call.ID); err == nil && current != nil {
		*call = *current
	}
	return http.StatusConflict, "This call is no longer ringing for you."
}

// expireIfDue applies the ring timeout. A direct call ends missed; a group call keeps running and its
// unanswered invitees become missed. It reports whether anything changed.
func (p *Plugin) expireIfDue(call *callState) bool {
	if call.State != stateRinging || call.RingExpiresAt == 0 || p.clock().UnixMilli() < call.RingExpiresAt {
		return false
	}
	if call.Kind != kindGroup {
		p.finishCall(call, reasonMissed, true)
		return true
	}
	var missed []string
	for userID, status := range call.Invitees {
		if isRinging(status) {
			call.Invitees[userID] = inviteeMissed
			missed = append(missed, userID)
		}
	}
	sort.Strings(missed)
	call.updateRinging()
	if err := p.saveCall(call); err != nil {
		p.API.LogWarn("Could not save the expired ring", "call_id", call.ID)
	}
	for _, userID := range missed {
		p.publishState(call, stateEvent{userID: userID, action: "missed"})
	}
	p.publishUpdated(call)
	p.sendMissedPushes(call, missed)
	return true
}

// finishCall ends the call: invitees still ringing become missed, the record post is updated and
// call_ended is published after the given call_state events.
func (p *Plugin) finishCall(call *callState, reason string, deleteRoom bool, states ...stateEvent) {
	if call.State == stateEnded {
		return
	}
	if deleteRoom {
		if err := p.roomRequest(context.Background(), "DeleteRoom", map[string]any{"room": call.Room}, nil); err != nil {
			p.API.LogWarn("Could not close the call room", "call_id", call.ID)
		}
	}
	now := p.clock().UnixMilli()
	var missed []string
	for userID, status := range call.Invitees {
		if isRinging(status) {
			call.Invitees[userID] = inviteeMissed
			missed = append(missed, userID)
		}
	}
	sort.Strings(missed)
	call.State = stateEnded
	call.EndReason = reason
	call.EndAt = now
	call.RingExpiresAt = 0
	if call.AnsweredAt > 0 && now > call.AnsweredAt {
		call.DurationMs = now - call.AnsweredAt
	}
	call.Participants = 0
	call.Identities = nil
	if err := p.saveCall(call); err != nil {
		p.API.LogError("Could not save the ended call", "call_id", call.ID)
	}
	p.updateRecord(call)
	if reason == reasonMissed {
		for _, userID := range missed {
			states = append(states, stateEvent{userID: userID, action: "missed"})
		}
	}
	for _, event := range states {
		p.publishState(call, event)
	}
	p.publishEnded(call)
	if reason == reasonMissed || reason == reasonCancelled {
		p.sendMissedPushes(call, missed)
	}
}

// Call routes: GET /calls/active, GET /calls/<id>, POST /calls/<id>/{received,accept,decline,hangup}.
func (p *Plugin) serveCall(w http.ResponseWriter, r *http.Request, userID string, parts []string) {
	if len(parts) == 2 && parts[1] == "active" {
		if r.Method != http.MethodGet {
			fail(w, http.StatusMethodNotAllowed, "This route requires GET.")
			return
		}
		p.listActive(w, userID)
		return
	}
	if len(parts) < 2 || len(parts) > 3 || !model.IsValidId(parts[1]) {
		fail(w, http.StatusNotFound, "Unknown call endpoint.")
		return
	}
	call, _, err := p.loadCallByID(parts[1])
	if err != nil {
		fail(w, http.StatusInternalServerError, "Could not load this call.")
		return
	}
	if call == nil {
		fail(w, http.StatusNotFound, "This call is no longer available.")
		return
	}
	member, appErr := p.API.GetChannelMember(call.ChannelID, userID)
	if appErr != nil || member == nil {
		fail(w, http.StatusForbidden, "Join this channel before joining its call.")
		return
	}
	v := p.newViewer(userID)
	v.admins[call.ChannelID] = member.SchemeAdmin
	p.expireIfDue(call)
	if len(parts) == 2 {
		if r.Method != http.MethodGet {
			fail(w, http.StatusMethodNotAllowed, "This route requires GET.")
			return
		}
		writeJSON(w, viewOf(call, v))
		return
	}
	if r.Method != http.MethodPost {
		fail(w, http.StatusMethodNotAllowed, "This call action requires POST.")
		return
	}
	var input callInput
	if !decodeInput(w, r, &input) {
		return
	}
	if input.DeviceID != "" && !validDeviceID(input.DeviceID) {
		fail(w, http.StatusBadRequest, "Invalid device.")
		return
	}
	switch parts[2] {
	case "received":
		p.handleReceived(w, call, userID, input.DeviceID, v)
	case "accept":
		p.handleAccept(w, call, userID, input.DeviceID, v)
	case "decline":
		p.handleDecline(w, call, userID, input.DeviceID, input.Reason, v)
	case "hangup":
		p.handleHangup(w, r, call, userID, input.DeviceID)
	default:
		fail(w, http.StatusNotFound, "Unknown call action.")
	}
}

func (p *Plugin) handleReceived(w http.ResponseWriter, call *callState, userID, deviceID string, v *viewer) {
	status := call.Invitees[userID]
	if call.State == stateEnded || !isRinging(status) {
		failWithCall(w, http.StatusConflict, "This call is no longer ringing for you.", call, v)
		return
	}
	if status == inviteeRinging {
		call.Invitees[userID] = inviteeReceived
		if err := p.saveCall(call); err != nil {
			fail(w, http.StatusInternalServerError, "Could not update the call.")
			return
		}
		p.publishState(call, stateEvent{userID: userID, deviceID: deviceID, action: "received"})
		p.publishUpdated(call)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (p *Plugin) handleAccept(w http.ResponseWriter, call *callState, userID, deviceID string, v *viewer) {
	user, ok := p.activeUser(userID)
	if !ok {
		fail(w, http.StatusForbidden, "This account is unavailable.")
		return
	}
	if deviceID == "" {
		deviceID = model.NewId()
	}
	if status, message := p.acceptCall(call, userID, deviceID); status != 0 {
		failWithCall(w, status, message, call, v)
		return
	}
	if call.Participants >= p.config.MaxParticipants {
		fail(w, http.StatusConflict, "This call has reached the server's participant limit.")
		return
	}
	p.writeJoin(w, call, user, deviceID, v)
}

func (p *Plugin) handleDecline(w http.ResponseWriter, call *callState, userID, deviceID, reason string, v *viewer) {
	if reason == "" {
		reason = reasonDeclined
	}
	if reason != reasonDeclined && reason != reasonBusy {
		fail(w, http.StatusBadRequest, "Invalid decline reason.")
		return
	}
	status := call.Invitees[userID]
	if call.State == stateEnded || !isRinging(status) {
		if status == reason {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		failWithCall(w, http.StatusConflict, "This call is no longer ringing for you.", call, v)
		return
	}
	call.Invitees[userID] = reason
	event := stateEvent{userID: userID, deviceID: deviceID, action: reason}
	if call.Kind == kindDirect {
		p.finishCall(call, reason, true, event)
	} else {
		call.updateRinging()
		if err := p.saveCall(call); err != nil {
			fail(w, http.StatusInternalServerError, "Could not update the call.")
			return
		}
		p.publishState(call, event)
		p.publishUpdated(call)
	}
	w.WriteHeader(http.StatusNoContent)
}

// handleHangup: the caller before anyone answered cancels; a party of an answered direct call ends it for
// both; an invitee whose devices still ring declines; everyone else leaves (the device is removed from the room).
func (p *Plugin) handleHangup(w http.ResponseWriter, r *http.Request, call *callState, userID, deviceID string) {
	status := call.Invitees[userID]
	switch {
	case call.State == stateEnded:
	case call.Kind != kindChannel && call.AnsweredAt == 0 && userID == call.StartedBy:
		p.finishCall(call, reasonCancelled, true, stateEvent{userID: userID, deviceID: deviceID, action: "cancelled"})
	case call.Kind == kindDirect && call.State == stateActive:
		p.finishCall(call, reasonHangup, true, stateEvent{userID: userID, deviceID: deviceID, action: "hangup"})
	case isRinging(status):
		call.Invitees[userID] = inviteeDeclined
		event := stateEvent{userID: userID, deviceID: deviceID, action: "declined"}
		if call.Kind == kindDirect {
			p.finishCall(call, reasonDeclined, true, event)
			break
		}
		call.updateRinging()
		if err := p.saveCall(call); err != nil {
			fail(w, http.StatusInternalServerError, "Could not update the call.")
			return
		}
		p.publishState(call, event)
		p.publishUpdated(call)
	default:
		p.leaveCall(r.Context(), call, userID, deviceID)
	}
	w.WriteHeader(http.StatusNoContent)
}

func (p *Plugin) leaveCall(ctx context.Context, call *callState, userID, deviceID string) {
	var identities []string
	if deviceID != "" {
		identities = []string{userID + ":" + deviceID}
	} else {
		for _, identity := range call.Identities {
			if strings.HasPrefix(identity, userID+":") {
				identities = append(identities, identity)
			}
		}
	}
	for _, identity := range identities {
		if err := p.roomRequest(ctx, "RemoveParticipant", map[string]any{"room": call.Room, "identity": identity}, nil); err != nil {
			p.API.LogDebug("Could not remove a departing call participant", "call_id", call.ID)
		}
	}
}

// listActive returns every ringing or active call in channels the user belongs to, newest first.
func (p *Plugin) listActive(w http.ResponseWriter, userID string) {
	index, err := p.loadIndex()
	if err != nil {
		fail(w, http.StatusInternalServerError, "Could not load calls.")
		return
	}
	v := p.newViewer(userID)
	membership := map[string]bool{}
	var live []*callState
	for _, id := range sortedIDs(index) {
		call, _, err := p.loadCallByID(id)
		if err != nil || call == nil {
			continue
		}
		p.expireIfDue(call)
		if call.State == stateEnded {
			continue
		}
		allowed, seen := membership[call.ChannelID]
		if !seen {
			member, appErr := p.API.GetChannelMember(call.ChannelID, userID)
			allowed = appErr == nil && member != nil
			membership[call.ChannelID] = allowed
			if allowed {
				v.admins[call.ChannelID] = member.SchemeAdmin
			}
		}
		if allowed {
			live = append(live, call)
		}
	}
	sort.SliceStable(live, func(i, j int) bool { return live[i].StartedAt > live[j].StartedAt })
	calls := make([]callView, 0, len(live))
	for _, call := range live {
		calls = append(calls, viewOf(call, v))
	}
	writeJSON(w, map[string]any{"calls": calls})
}

func (p *Plugin) participantJoined(call *callState, identity string) {
	userID, deviceID, _ := strings.Cut(identity, ":")
	if !containsString(call.Identities, identity) {
		call.Identities = append(call.Identities, identity)
	}
	call.Participants = len(call.Identities)
	var events []stateEvent
	if isRinging(call.Invitees[userID]) {
		// Joining the room answers the ring (version 1 clients join instead of accepting).
		call.Invitees[userID] = inviteeAccepted
		if call.Answered == nil {
			call.Answered = map[string]string{}
		}
		call.Answered[userID] = deviceID
		if call.AnsweredAt == 0 {
			call.AnsweredAt = p.clock().UnixMilli()
		}
		call.updateRinging()
		events = append(events, stateEvent{userID: userID, deviceID: deviceID, action: "accepted"})
	}
	events = append(events, stateEvent{userID: userID, deviceID: deviceID, action: "joined"})
	if err := p.saveCall(call); err != nil {
		p.API.LogWarn("Could not save call participants", "call_id", call.ID)
	}
	for _, event := range events {
		p.publishState(call, event)
	}
	p.publishUpdated(call)
}

func (p *Plugin) participantLeft(call *callState, identity string) {
	if identity == "" {
		return
	}
	userID, deviceID, _ := strings.Cut(identity, ":")
	call.Identities = removeString(call.Identities, identity)
	call.Participants = len(call.Identities)
	if err := p.saveCall(call); err != nil {
		p.API.LogWarn("Could not save call participants", "call_id", call.ID)
	}
	p.publishState(call, stateEvent{userID: userID, deviceID: deviceID, action: "left"})
	p.publishUpdated(call)
}

// refreshCall checks the room with LiveKit (version 1 behaviour): a missing room ends the call, and a
// changed participant count resynchronizes the identities.
func (p *Plugin) refreshCall(ctx context.Context, call *callState) error {
	var result roomList
	if err := p.roomRequest(ctx, "ListRooms", map[string]any{"names": []string{call.Room}}, &result); err != nil {
		return err
	}
	for _, room := range result.Rooms {
		if room.Name != call.Room {
			continue
		}
		if room.NumParticipants != call.Participants || room.NumParticipants != len(call.Identities) {
			if identities, err := p.listIdentities(ctx, call.Room); err == nil {
				call.Identities = identities
			}
			call.Participants = room.NumParticipants
			if err := p.saveCall(call); err != nil {
				p.API.LogWarn("Could not save call participants", "call_id", call.ID)
			}
		}
		return nil
	}
	p.finishCall(call, roomGoneReason(call), false)
	return nil
}

func (p *Plugin) startSweeper() {
	p.stopSweeper()
	p.mu.Lock()
	interval := p.sweepEvery
	if interval <= 0 {
		interval = time.Second
	}
	stop, done := make(chan struct{}), make(chan struct{})
	p.sweepStop, p.sweepDone = stop, done
	p.mu.Unlock()
	go func() {
		defer close(done)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-stop:
				return
			case <-ticker.C:
				p.sweep()
			}
		}
	}()
}

func (p *Plugin) stopSweeper() {
	p.mu.Lock()
	stop, done := p.sweepStop, p.sweepDone
	p.sweepStop, p.sweepDone = nil, nil
	p.mu.Unlock()
	if stop != nil {
		close(stop)
		<-done
	}
}

// sweep expires due rings from the KV-backed index (so expiry survives restarts) and periodically
// reconciles active calls with LiveKit.
func (p *Plugin) sweep() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !p.ready() {
		return
	}
	index, err := p.loadIndex()
	if err != nil {
		return
	}
	now := p.clock()
	nowMs := now.UnixMilli()
	for _, id := range sortedIDs(index) {
		entry, ok := index.Calls[id]
		if !ok || entry.RingExpiresAt == 0 || entry.RingExpiresAt > nowMs {
			continue
		}
		call, _, err := p.loadCallByID(id)
		if err != nil {
			continue
		}
		if call == nil {
			delete(index.Calls, id)
			_ = p.saveIndex()
			continue
		}
		if !p.expireIfDue(call) {
			_ = p.updateIndex(call)
		}
	}
	if now.Sub(p.lastReconcile) >= reconcileInterval {
		p.lastReconcile = now
		p.reconcile(index)
	}
}

// reconcile ends active calls whose LiveKit room disappeared without a room_finished webhook.
func (p *Plugin) reconcile(index *callIndex) {
	nowMs := p.clock().UnixMilli()
	var calls []*callState
	var names []string
	for _, id := range sortedIDs(index) {
		call, _, err := p.loadCallByID(id)
		if err != nil {
			continue
		}
		if call == nil {
			delete(index.Calls, id)
			_ = p.saveIndex()
			continue
		}
		if call.State == stateActive && nowMs-call.StartedAt >= roomSettleMs {
			calls = append(calls, call)
			names = append(names, call.Room)
		}
	}
	if len(calls) == 0 {
		return
	}
	var result roomList
	if err := p.roomRequest(context.Background(), "ListRooms", map[string]any{"names": names}, &result); err != nil {
		return
	}
	present := make(map[string]bool, len(result.Rooms))
	for _, room := range result.Rooms {
		present[room.Name] = true
	}
	for _, call := range calls {
		if !present[call.Room] {
			p.finishCall(call, roomGoneReason(call), false)
		}
	}
}
