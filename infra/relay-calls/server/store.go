package main

import (
	"encoding/json"
	"sort"
)

// KV layout:
//
//	call:<id>          the call record (ended calls are kept for endedRetentionSeconds)
//	channel:<channel>  id of the channel's current (ringing or active) call; version 1 stored the record itself
//	room:<room>        id of the room's call; version 1 stored the channel id
//	index              live calls with their ring expiry, swept by the ticker (survives restarts)
//	voip:<user>        the user's VoIP registrations by device id
const (
	indexKey              = "index"
	endedRetentionSeconds = 600
	maxVoIPDevices        = 10
)

func callKey(id string) string        { return "call:" + id }
func channelKey(id string) string     { return "channel:" + id }
func roomKey(room string) string      { return "room:" + room }
func devicesKey(userID string) string { return "voip:" + userID }

type indexEntry struct {
	ChannelID     string `json:"channel_id"`
	RingExpiresAt int64  `json:"ring_expires_at,omitempty"`
}

type callIndex struct {
	Calls map[string]indexEntry `json:"calls"`
}

// loadCall returns the channel's current call, or nil.
func (p *Plugin) loadCall(channelID string) (*callState, error) {
	data, appErr := p.API.KVGet(channelKey(channelID))
	if appErr != nil {
		return nil, appErr
	}
	if len(data) == 0 {
		return nil, nil
	}
	if data[0] == '{' {
		// A version 1 call record: migrate it to the version 2 layout.
		var call callState
		if err := json.Unmarshal(data, &call); err != nil {
			return nil, err
		}
		call.normalize()
		if call.ID == "" || call.ChannelID != channelID {
			return nil, nil
		}
		if err := p.saveCall(&call); err != nil {
			return nil, err
		}
		return &call, nil
	}
	call, _, err := p.loadCallByID(string(data))
	if err != nil {
		return nil, err
	}
	if call == nil || call.State == stateEnded || call.ChannelID != channelID {
		return nil, nil
	}
	return call, nil
}

// loadCallByID returns the call and the stored bytes (for compare-and-set), or nil once forgotten.
func (p *Plugin) loadCallByID(id string) (*callState, []byte, error) {
	data, appErr := p.API.KVGet(callKey(id))
	if appErr != nil {
		return nil, nil, appErr
	}
	if len(data) == 0 {
		return nil, nil, nil
	}
	var call callState
	if err := json.Unmarshal(data, &call); err != nil {
		return nil, nil, err
	}
	call.normalize()
	return &call, data, nil
}

func (p *Plugin) loadCallByRoom(room string) (*callState, error) {
	data, appErr := p.API.KVGet(roomKey(room))
	if appErr != nil {
		return nil, appErr
	}
	if len(data) == 0 {
		return nil, nil
	}
	call, _, err := p.loadCallByID(string(data))
	if err != nil {
		return nil, err
	}
	if call == nil {
		// Version 1 stored the channel id under the room key.
		if call, err = p.loadCall(string(data)); err != nil {
			return nil, err
		}
	}
	if call == nil || call.Room != room {
		return nil, nil
	}
	return call, nil
}

func (p *Plugin) saveCall(call *callState) error {
	call.normalize()
	data, err := json.Marshal(call)
	if err != nil {
		return err
	}
	if call.State == stateEnded {
		if appErr := p.API.KVSetWithExpiry(callKey(call.ID), data, endedRetentionSeconds); appErr != nil {
			return appErr
		}
	} else if appErr := p.API.KVSet(callKey(call.ID), data); appErr != nil {
		return appErr
	}
	return p.syncPointers(call)
}

// syncPointers updates the channel and room keys and the index after the record was written.
func (p *Plugin) syncPointers(call *callState) error {
	if call.State == stateEnded {
		if current, appErr := p.API.KVGet(channelKey(call.ChannelID)); appErr == nil && (string(current) == call.ID || (len(current) > 0 && current[0] == '{')) {
			_ = p.API.KVDelete(channelKey(call.ChannelID))
		}
		_ = p.API.KVDelete(roomKey(call.Room))
	} else {
		if appErr := p.API.KVSet(channelKey(call.ChannelID), []byte(call.ID)); appErr != nil {
			return appErr
		}
		if appErr := p.API.KVSet(roomKey(call.Room), []byte(call.ID)); appErr != nil {
			return appErr
		}
	}
	return p.updateIndex(call)
}

func (p *Plugin) loadIndex() (*callIndex, error) {
	if p.index != nil {
		return p.index, nil
	}
	data, appErr := p.API.KVGet(indexKey)
	if appErr != nil {
		return nil, appErr
	}
	index := &callIndex{Calls: map[string]indexEntry{}}
	if len(data) > 0 {
		if err := json.Unmarshal(data, index); err != nil {
			return nil, err
		}
		if index.Calls == nil {
			index.Calls = map[string]indexEntry{}
		}
	}
	p.index = index
	return index, nil
}

func (p *Plugin) saveIndex() error {
	if p.index == nil {
		return nil
	}
	data, err := json.Marshal(p.index)
	if err != nil {
		return err
	}
	if appErr := p.API.KVSet(indexKey, data); appErr != nil {
		return appErr
	}
	return nil
}

func (p *Plugin) updateIndex(call *callState) error {
	index, err := p.loadIndex()
	if err != nil {
		return err
	}
	entry, exists := index.Calls[call.ID]
	if call.State == stateEnded {
		if !exists {
			return nil
		}
		delete(index.Calls, call.ID)
		return p.saveIndex()
	}
	next := indexEntry{ChannelID: call.ChannelID}
	if call.State == stateRinging {
		next.RingExpiresAt = call.RingExpiresAt
	}
	if exists && entry == next {
		return nil
	}
	index.Calls[call.ID] = next
	return p.saveIndex()
}

func sortedIDs(index *callIndex) []string {
	ids := make([]string, 0, len(index.Calls))
	for id := range index.Calls {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// liveCalls loads every ringing or active call except the given one.
func (p *Plugin) liveCalls(except string) []*callState {
	index, err := p.loadIndex()
	if err != nil {
		return nil
	}
	var calls []*callState
	for _, id := range sortedIDs(index) {
		if id == except {
			continue
		}
		call, _, err := p.loadCallByID(id)
		if err != nil || call == nil || call.State == stateEnded {
			continue
		}
		calls = append(calls, call)
	}
	return calls
}

func (p *Plugin) loadDevices(userID string) (map[string]voipDevice, error) {
	data, appErr := p.API.KVGet(devicesKey(userID))
	if appErr != nil {
		return nil, appErr
	}
	devices := map[string]voipDevice{}
	if len(data) > 0 {
		if err := json.Unmarshal(data, &devices); err != nil {
			return nil, err
		}
		if devices == nil {
			devices = map[string]voipDevice{}
		}
	}
	return devices, nil
}

func (p *Plugin) saveDevices(userID string, devices map[string]voipDevice) error {
	if len(devices) == 0 {
		if appErr := p.API.KVDelete(devicesKey(userID)); appErr != nil {
			return appErr
		}
		return nil
	}
	data, err := json.Marshal(devices)
	if err != nil {
		return err
	}
	if appErr := p.API.KVSet(devicesKey(userID), data); appErr != nil {
		return appErr
	}
	return nil
}

func (p *Plugin) dropDevice(userID, deviceID, token string) {
	devices, err := p.loadDevices(userID)
	if err != nil {
		return
	}
	if device, ok := devices[deviceID]; ok && device.Token == token {
		delete(devices, deviceID)
		if err := p.saveDevices(userID, devices); err != nil {
			p.API.LogWarn("Could not remove a VoIP registration", "user_id", userID)
		}
	}
}
