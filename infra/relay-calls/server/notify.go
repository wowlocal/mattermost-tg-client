package main

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/mattermost/mattermost/server/public/model"
)

const (
	callRecordPostType = "custom_relay_call"
	// recordPushWindow is how long after creating a call record the push hook checks a channel's posts.
	recordPushWindow = 5 * time.Minute
)

// parties are the caller and the invitees: the recipients of incoming/call_state, and per-user recipients of
// call_updated/call_ended.
func parties(call *callState) []string {
	users := []string{}
	if call.StartedBy != "" {
		users = append(users, call.StartedBy)
	}
	invitees := make([]string, 0, len(call.Invitees))
	for userID := range call.Invitees {
		if userID != call.StartedBy {
			invitees = append(invitees, userID)
		}
	}
	sort.Strings(invitees)
	return append(users, invitees...)
}

// eventCall is the call as one recipient sees it (can_end only for the starter).
func eventCall(call *callState, userID string) map[string]any {
	return viewOf(call, &viewer{userID: userID, admins: map[string]bool{}}).eventMap()
}

func callerInfo(user *model.User) map[string]any {
	return map[string]any{"id": user.Id, "username": user.Username, "display_name": displayName(user)}
}

// publishToUser reaches every session of userID.
func (p *Plugin) publishToUser(event, userID string, data map[string]any) {
	p.API.PublishWebSocketEvent(event, data, &model.WebsocketBroadcast{UserId: userID})
}

func (p *Plugin) publishState(call *callState, event stateEvent) {
	if call.Kind == kindChannel {
		return
	}
	for _, userID := range parties(call) {
		p.publishToUser("call_state", userID, map[string]any{
			"call": eventCall(call, userID), "user_id": event.userID, "device_id": event.deviceID, "action": event.action,
		})
	}
}

// publishCall delivers call_updated/call_ended once to every channel member and every party: per user to
// the parties, and to the channel without them.
func (p *Plugin) publishCall(event string, call *callState) {
	recipients := parties(call)
	omit := make(map[string]bool, len(recipients))
	for _, userID := range recipients {
		omit[userID] = true
		p.publishToUser(event, userID, map[string]any{"call": eventCall(call, userID), "channel_id": call.ChannelID, "call_id": call.ID})
	}
	p.API.PublishWebSocketEvent(event, map[string]any{"call": viewOf(call, nil).eventMap(), "channel_id": call.ChannelID, "call_id": call.ID},
		&model.WebsocketBroadcast{ChannelId: call.ChannelID, OmitUsers: omit})
}

func (p *Plugin) publishUpdated(call *callState) { p.publishCall("call_updated", call) }
func (p *Plugin) publishEnded(call *callState)   { p.publishCall("call_ended", call) }

func recordProps(call *callState) map[string]any {
	return map[string]any{
		"v": contractVersion, "call_id": call.ID, "kind": call.Kind, "video": call.Video, "state": call.State,
		"started_by": call.StartedBy, "end_reason": call.EndReason, "duration_ms": call.DurationMs,
		"started_at": call.StartedAt, "end_at": call.EndAt,
	}
}

// recordMessage is the plain text other Mattermost clients show for a call record.
func recordMessage(call *callState) string {
	var base string
	switch {
	case call.Kind == kindDirect && call.Video:
		base = "Video call"
	case call.Kind == kindDirect:
		base = "Call"
	case call.Video:
		base = "Group video call"
	default:
		base = "Group call"
	}
	if call.State != stateEnded {
		return base
	}
	lower := strings.ToLower(base[:1]) + base[1:]
	switch call.EndReason {
	case reasonMissed:
		return "Missed " + lower
	case reasonCancelled:
		return "Cancelled " + lower
	case reasonDeclined:
		return "Declined " + lower
	case reasonFailed:
		return "Failed " + lower
	case reasonBusy:
		return base + " · busy"
	}
	if call.DurationMs > 0 {
		return base + " · " + formatDuration(call.DurationMs)
	}
	return base
}

func formatDuration(ms int64) string {
	seconds := ms / 1000
	if seconds < 60 {
		if seconds < 1 {
			seconds = 1
		}
		return fmt.Sprintf("%d s", seconds)
	}
	minutes := seconds / 60
	if minutes < 60 {
		return fmt.Sprintf("%d min", minutes)
	}
	return fmt.Sprintf("%d h %d min", minutes/60, minutes%60)
}

// createRecord posts the call record when AnnounceCalls (call records) is on, and reports whether it did.
func (p *Plugin) createRecord(call *callState) bool {
	if !p.config.AnnounceCalls {
		return false
	}
	p.noteRecordChannel(call.ChannelID)
	post, appErr := p.API.CreatePost(&model.Post{
		UserId: call.StartedBy, ChannelId: call.ChannelID, Type: callRecordPostType, Message: recordMessage(call),
		Props: model.StringInterface{"relay_call": recordProps(call)},
	})
	if appErr != nil || post == nil {
		p.API.LogWarn("Could not create the call record", "call_id", call.ID)
		return false
	}
	call.PostID = post.Id
	return true
}

// createRecordAndLink posts the record and saves the call with its post id.
func (p *Plugin) createRecordAndLink(call *callState) {
	if p.createRecord(call) {
		if err := p.saveCall(call); err != nil {
			p.API.LogWarn("Could not link the call record", "call_id", call.ID)
		}
	}
}

func (p *Plugin) updateRecord(call *callState) {
	if call.PostID == "" {
		return
	}
	post, appErr := p.API.GetPost(call.PostID)
	if appErr != nil || post == nil {
		p.API.LogWarn("Could not load the call record", "call_id", call.ID)
		return
	}
	post.Message = recordMessage(call)
	post.AddProp("relay_call", recordProps(call))
	if _, appErr := p.API.UpdatePost(post); appErr != nil {
		p.API.LogWarn("Could not update the call record", "call_id", call.ID)
	}
}

func (p *Plugin) noteRecordChannel(channelID string) {
	p.pushMu.Lock()
	defer p.pushMu.Unlock()
	now := p.clock().UnixMilli()
	if p.recordChannels == nil {
		p.recordChannels = map[string]int64{}
	}
	for id, expires := range p.recordChannels {
		if expires <= now {
			delete(p.recordChannels, id)
		}
	}
	p.recordChannels[channelID] = now + recordPushWindow.Milliseconds()
}

// allowedPush is one of this plugin's own pushes for a call record, matched by its exact message so the
// server's alert for the same post (another message) stays suppressed.
type allowedPush struct {
	expires int64
	message string
}

func (p *Plugin) allowPush(userID, postID, message string) {
	p.pushMu.Lock()
	defer p.pushMu.Unlock()
	now := p.clock().UnixMilli()
	if p.allowedPushes == nil {
		p.allowedPushes = map[string]allowedPush{}
	}
	for key, allowed := range p.allowedPushes {
		if allowed.expires <= now {
			delete(p.allowedPushes, key)
		}
	}
	p.allowedPushes[userID+":"+postID] = allowedPush{expires: now + recordPushWindow.Milliseconds(), message: message}
}

// mayBeRecordPush is true when a push could be the server's alert for a call record this plugin just
// created (and is not one of this plugin's own missed-call pushes).
func (p *Plugin) mayBeRecordPush(channelID, userID, postID, message string) bool {
	p.pushMu.Lock()
	defer p.pushMu.Unlock()
	now := p.clock().UnixMilli()
	if allowed, ok := p.allowedPushes[userID+":"+postID]; ok && allowed.expires > now && allowed.message == message {
		return false
	}
	if channelID == "" {
		return true
	}
	expires, ok := p.recordChannels[channelID]
	return ok && expires > now
}

// NotificationWillBePushed suppresses Mattermost's own push for call record posts: the ring itself (VoIP
// push, WebSocket) announces the call, so a DM ring is not doubled by an alert. It never takes p.mu, because
// the server may run it while a plugin call holding p.mu is in flight.
func (p *Plugin) NotificationWillBePushed(notification *model.PushNotification, userID string) (*model.PushNotification, string) {
	if notification == nil || notification.PostId == "" {
		return nil, ""
	}
	if !p.mayBeRecordPush(notification.ChannelId, userID, notification.PostId, notification.Message) {
		return nil, ""
	}
	post, appErr := p.API.GetPost(notification.PostId)
	if appErr != nil || post == nil || post.Type != callRecordPostType {
		return nil, ""
	}
	return nil, "Relay call records are announced by the call itself."
}

// sendMissedPushes sends "Missed call from X" through Mattermost's push proxy. Skipped when push is off or
// when the server only sends ids (id_loaded), since the plugin API bypasses that redaction.
func (p *Plugin) sendMissedPushes(call *callState, users []string) {
	if len(users) == 0 {
		return
	}
	cfg := p.API.GetConfig()
	if cfg == nil || cfg.EmailSettings.SendPushNotifications == nil || !*cfg.EmailSettings.SendPushNotifications {
		return
	}
	if cfg.EmailSettings.PushNotificationContents != nil && *cfg.EmailSettings.PushNotificationContents == "id_loaded" {
		return
	}
	name := "Someone"
	if caller, ok := p.activeUser(call.StartedBy); ok {
		name = displayName(caller)
	}
	kind := "call"
	switch {
	case call.Kind == kindGroup && call.Video:
		kind = "group video call"
	case call.Kind == kindGroup:
		kind = "group call"
	case call.Video:
		kind = "video call"
	}
	message := "Missed " + kind + " from " + name
	channelID, postID, callerID := call.ChannelID, call.PostID, call.StartedBy
	recipients := append([]string(nil), users...)
	for _, userID := range recipients {
		p.allowPush(userID, postID, message)
	}
	p.goAsync(func() {
		for _, userID := range recipients {
			notification := &model.PushNotification{
				Type: "message", ChannelId: channelID, PostId: postID, SenderId: callerID, SenderName: name,
				ChannelName: name, Message: message,
			}
			if appErr := p.API.SendPushNotification(notification, userID); appErr != nil {
				p.API.LogDebug("Could not send the missed call push", "user_id", userID)
			}
		}
	})
}
