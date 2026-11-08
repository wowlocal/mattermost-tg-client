#!/usr/bin/env python3
"""A scripted Relay Calls peer for the local dev server (plugin org.relaychat.calls v2 on LiveKit).

Logs in a seeded dev user (password SEED_USER_PASSWORD from the dev server's .env, never printed), rings,
answers, declines or joins calls like a Relay client does, and while connected publishes a tone as the
microphone and an animated test pattern as the camera and/or a screen share, and reports what it receives from
every remote participant. Output is JSON lines on stdout (`--out FILE` appends them to a file as well).

Run it with the venv that has livekit 1.2.1 (and aiohttp, numpy):

    PY=~/Developer/relay-calls-integration/media-probe-venv/bin/python
    $PY tools/relay-calls-peer.py --user bob ring alice                 # ring alice's DM (audio)
    $PY tools/relay-calls-peer.py --user bob ring alice --video --camera
    $PY tools/relay-calls-peer.py --user bob ring alice,l4b0001         # ring the group DM
    $PY tools/relay-calls-peer.py --user bob answer --from alice        # wait for a ring and accept it
    $PY tools/relay-calls-peer.py --user bob answer --decline           # ... or decline / --busy / --ignore
    $PY tools/relay-calls-peer.py --user bob channel town-square        # start or join a channel call
    $PY tools/relay-calls-peer.py --user bob channel-create relay-calls-test --members alice
    $PY tools/relay-calls-peer.py --user bob status                     # live calls the user can see
    $PY tools/relay-calls-peer.py --user bob hangup                     # hang up the user's calls
    $PY tools/relay-calls-peer.py --user bob cleanup                    # end/decline/leave everything of the user

Media and timing options (ring, answer, channel):
    --tone HZ        microphone tone (default 440; 0 publishes silence), --no-audio publishes no microphone
    --camera         publish the test pattern as the camera (--size 640x360 --fps 15)
    --screen         publish a test pattern as a screen share (--screen-size 1280x720)
    --muted          start with the microphone muted
    --duration S     hang up S seconds after the media connected (default: stay until the call ends)
    --timeout S      give up waiting for a ring / an answer after S seconds
    --report S       statistics interval (default 2)
    --at T=ACTION    run ACTION T seconds after the media connected (repeatable):
                     mute, unmute, camera-on, camera-off, screen-on, screen-off, hangup, end, stats, quit
    --control PATH   a FIFO (created if missing) that takes one ACTION per line while connected
    --stay-alone     do not hang up a direct call when the other side's device leaves the room

Events (field "event"): login, channel, ring, incoming, received, accepted, declined, call (plugin state
changes), ws (call_state actions), connected, participant_joined, participant_left, track_subscribed,
track_unsubscribed, track_muted, track_unmuted, published, unpublished, stats, ended, summary, error.
`stats` lists each remote participant (user, identity, name) with microphone frames, RMS/peak level in dBFS and
the dominant frequency, and per video source (camera, screen) frames, fps, size and the number of distinct
sampled frames (> 1 means the picture moves).
"""

import argparse
import asyncio
import json
import logging
import math
import os
import sys
import threading
import time
import uuid
import zlib

import aiohttp
import numpy as np
from livekit import rtc

SERVER = os.environ.get("RELAY_DEV_SERVER", "http://127.0.0.1:8065")
ENV_FILE = os.path.expanduser(os.environ.get("RELAY_DEV_ENV", "~/Developer/tg-mattermost-client/infra/dev-server/.env"))
PLUGIN = "/plugins/org.relaychat.calls"
ACTIONS = ("mute", "unmute", "camera-on", "camera-off", "screen-on", "screen-off", "hangup", "end", "stats", "quit")

logging.basicConfig(level=logging.WARNING, stream=sys.stderr)
logging.getLogger("livekit").setLevel(logging.ERROR)

START = time.monotonic()
OUT = None


def emit(event, **fields):
    record = {"t": round(time.monotonic() - START, 2), "event": event}
    record.update(fields)
    line = json.dumps(record, default=str)
    print(line, flush=True)
    if OUT:
        with open(OUT, "a") as stream:
            stream.write(line + "\n")


def password():
    with open(ENV_FILE) as stream:
        for line in stream:
            if line.startswith("SEED_USER_PASSWORD="):
                return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("SEED_USER_PASSWORD is missing in " + ENV_FILE)


def decode_nested(value):
    if isinstance(value, str) and value[:1] in ("{", "["):
        try:
            return json.loads(value)
        except ValueError:
            return value
    return value


def brief(call):
    if not isinstance(call, dict):
        return call
    keys = ("id", "kind", "state", "video", "started_by", "end_reason", "duration_ms", "participants", "participant_ids", "invitees", "channel_id", "ring_expires_at")
    return {k: call.get(k) for k in keys if k in call}


class HTTPError(Exception):
    def __init__(self, status, body):
        super().__init__(f"HTTP {status}: {body}")
        self.status = status
        self.body = body


class Mattermost:
    def __init__(self, session, user):
        self.session = session
        self.user = user
        self.token = None
        self.me = None
        self.usernames = {}

    async def request(self, method, path, body=None, ok=(200, 201, 204)):
        headers = {"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        async with self.session.request(method, SERVER + path, json=body, headers=headers) as response:
            raw = await response.read()
            try:
                data = json.loads(raw) if raw else None
            except ValueError:
                data = raw.decode(errors="replace")
            if response.status not in ok:
                raise HTTPError(response.status, data)
            return response.status, data, response.headers

    async def login(self):
        _, me, headers = await self.request("POST", "/api/v4/users/login", {"login_id": self.user, "password": password()})
        self.token = headers["Token"]
        self.me = me
        self.usernames[me["id"]] = me["username"]
        emit("login", user=self.user, user_id=me["id"])

    async def logout(self):
        if self.token:
            try:
                await self.request("POST", "/api/v4/users/logout")
            except Exception:
                pass
            self.token = None

    async def user_ids(self, usernames):
        _, users, _ = await self.request("POST", "/api/v4/users/usernames", usernames)
        found = {u["username"]: u["id"] for u in users}
        for name, uid in found.items():
            self.usernames[uid] = name
        missing = [u for u in usernames if u not in found]
        if missing:
            raise SystemExit("unknown users: " + ", ".join(missing))
        return [found[u] for u in usernames]

    async def names(self, ids):
        missing = [i for i in set(ids) if i and i not in self.usernames]
        if missing:
            try:
                _, users, _ = await self.request("POST", "/api/v4/users/ids", missing)
                for u in users:
                    self.usernames[u["id"]] = u["username"]
            except HTTPError:
                pass
        return {i: self.usernames.get(i, i) for i in ids}

    async def channel_for_users(self, usernames):
        ids = await self.user_ids(usernames)
        if len(ids) == 1:
            _, channel, _ = await self.request("POST", "/api/v4/channels/direct", [self.me["id"], ids[0]])
        else:
            _, channel, _ = await self.request("POST", "/api/v4/channels/group", [self.me["id"]] + ids)
        return channel

    async def channel_by_name(self, name, team=None):
        if len(name) == 26 and name.isalnum():
            _, channel, _ = await self.request("GET", f"/api/v4/channels/{name}")
            return channel
        _, teams, _ = await self.request("GET", "/api/v4/users/me/teams")
        for t in teams:
            if team and t["name"] != team:
                continue
            try:
                _, channel, _ = await self.request("GET", f"/api/v4/teams/{t['id']}/channels/name/{name}")
                return channel
            except HTTPError:
                continue
        raise SystemExit(f"no channel {name} in the user's teams")


def tone_frames(frequency, sample_rate=48000, frame_ms=10, amplitude=0.3):
    samples = sample_rate * frame_ms // 1000
    phase = 0
    step = 2 * math.pi * frequency / sample_rate
    while True:
        if frequency > 0:
            t = phase + step * np.arange(samples)
            phase = (phase + step * samples) % (2 * math.pi)
            data = (np.sin(t) * amplitude * 32767).astype(np.int16)
        else:
            data = np.zeros(samples, dtype=np.int16)
        yield rtc.AudioFrame(data.tobytes(), sample_rate, 1, samples)


class Pattern:
    """Colour bars, a moving box and a moving stripe: every frame differs."""

    def __init__(self, width, height, label):
        self.width, self.height = width, height
        bars = np.array([[235, 235, 235], [235, 235, 16], [16, 235, 235], [16, 235, 16], [235, 16, 235], [235, 16, 16], [16, 16, 235], [16, 16, 16]], dtype=np.uint8)
        columns = (np.arange(width) * len(bars) // width)
        base = np.zeros((height, width, 4), dtype=np.uint8)
        base[:, :, :3] = bars[columns][None, :, :]
        base[:, :, 3] = 255
        if label == "screen":
            base[: height // 6, :, :3] = [40, 40, 120]
        self.base = base
        self.index = 0

    def frame(self):
        image = self.base.copy()
        w, h = self.width, self.height
        box = max(16, h // 6)
        x = (self.index * 7) % max(1, w - box)
        y = (self.index * 3) % max(1, h - box)
        image[y:y + box, x:x + box, :3] = 255 - image[y:y + box, x:x + box, :3]
        stripe = (self.index * 5) % h
        image[stripe:stripe + 4, :, :3] = 0
        self.index += 1
        return rtc.VideoFrame(w, h, rtc.VideoBufferType.RGBA, image.tobytes())


class RemoteStats:
    def __init__(self, identity, name, user):
        self.identity, self.name, self.user = identity, name, user
        self.audio = None
        self.video = {}

    def audio_stats(self):
        if self.audio is None:
            self.audio = {"frames": 0, "window_frames": 0, "sq": 0.0, "samples": 0, "peak": 0, "tail": np.zeros(0, dtype=np.int16), "muted": False, "total_frames": 0}
        return self.audio

    def video_stats(self, source):
        if source not in self.video:
            self.video[source] = {"frames": 0, "window_frames": 0, "width": 0, "height": 0, "crcs": set(), "muted": False}
        return self.video[source]

    def report(self, interval, reset=True):
        out = {"user": self.user, "identity": self.identity, "name": self.name}
        if self.audio is not None:
            a = self.audio
            rms = math.sqrt(a["sq"] / a["samples"]) if a["samples"] else 0.0
            freq = None
            if len(a["tail"]) >= 2048:
                tail = a["tail"][-4800:].astype(np.float64)
                spectrum = np.abs(np.fft.rfft(tail * np.hanning(len(tail))))
                bins = np.fft.rfftfreq(len(tail), 1 / 48000)
                if spectrum[1:].max() > 1e3:
                    freq = round(float(bins[1:][spectrum[1:].argmax()]), 1)
            out["audio"] = {
                "frames": a["frames"],
                "fps": round(a["window_frames"] / interval, 1) if interval else None,
                "rms_dbfs": round(20 * math.log10(rms / 32768), 1) if rms > 0 else -120.0,
                "peak_dbfs": round(20 * math.log10(a["peak"] / 32768), 1) if a["peak"] > 0 else -120.0,
                "freq_hz": freq,
                "muted": a["muted"],
            }
            if reset:
                a["window_frames"], a["sq"], a["samples"], a["peak"] = 0, 0.0, 0, 0
        for source, v in self.video.items():
            out[source] = {
                "frames": v["frames"],
                "fps": round(v["window_frames"] / interval, 1) if interval else None,
                "width": v["width"],
                "height": v["height"],
                "distinct": len(v["crcs"]),
                "muted": v["muted"],
            }
            if reset:
                v["window_frames"] = 0
        return out


class Peer:
    def __init__(self, args, mm):
        self.args = args
        self.mm = mm
        self.device_id = args.device_id or str(uuid.uuid4())
        self.room = None
        self.call = None
        self.call_id = None
        self.channel_id = None
        self.kind = None
        self.connected_at = None
        self.ended = asyncio.Event()
        self.end_info = None
        self.tasks = []
        self.readers = {}
        self.remotes = {}
        self.speakers = []
        self.audio_track = None
        self.audio_pub = None
        self.video_pubs = {}
        self.video_tasks = {}
        self.muted = args.muted
        self.peer_seen = False
        self.ws_events = asyncio.Queue()
        self.hung_up = False

    # Plugin state

    def update_call(self, call, source):
        if not isinstance(call, dict) or (self.call_id and call.get("id") != self.call_id):
            return
        previous = self.call
        self.call = call
        fields = ("state", "invitees", "participant_ids", "end_reason", "participants")
        if previous is None or any(previous.get(k) != call.get(k) for k in fields):
            emit("call", source=source, call=brief(call))
        if call.get("state") == "ended" and not self.ended.is_set():
            self.end_info = {"end_reason": call.get("end_reason"), "duration_ms": call.get("duration_ms")}
            self.ended.set()

    async def poll_call(self):
        while not self.ended.is_set():
            if self.call_id:
                try:
                    status, call, _ = await self.mm.request("GET", f"{PLUGIN}/calls/{self.call_id}", ok=(200, 404))
                    if status == 404:
                        if not self.ended.is_set():
                            self.end_info = {"end_reason": "forgotten"}
                            self.ended.set()
                    else:
                        self.update_call(call, "poll")
                except Exception as error:
                    emit("error", where="poll", error=str(error))
            await asyncio.sleep(1)

    async def websocket(self):
        url = SERVER.replace("http", "ws", 1) + "/api/v4/websocket"
        while True:
            try:
                async with self.mm.session.ws_connect(url, headers={"Authorization": "Bearer " + self.mm.token}, heartbeat=20) as ws:
                    await ws.send_json({"seq": 1, "action": "authentication_challenge", "data": {"token": self.mm.token}})
                    async for message in ws:
                        if message.type != aiohttp.WSMsgType.TEXT:
                            continue
                        payload = json.loads(message.data)
                        name = payload.get("event") or ""
                        if not name.startswith("custom_org.relaychat.calls_"):
                            continue
                        data = {k: decode_nested(v) for k, v in (payload.get("data") or {}).items()}
                        short = name[len("custom_org.relaychat.calls_"):]
                        await self.ws_events.put((short, data))
                        call = data.get("call")
                        if short == "call_state" and isinstance(call, dict) and call.get("id") == self.call_id:
                            names = await self.mm.names([data.get("user_id")])
                            emit("ws", action=data.get("action"), user=names.get(data.get("user_id")), device_id=data.get("device_id"))
                        if isinstance(call, dict):
                            self.update_call(call, "ws:" + short)
            except asyncio.CancelledError:
                raise
            except Exception as error:
                emit("error", where="websocket", error=str(error))
                await asyncio.sleep(2)

    # Media

    async def connect(self, join):
        self.room = rtc.Room()
        room = self.room

        @room.on("participant_connected")
        def joined(participant):
            self.peer_seen = True
            emit("participant_joined", **self.who(participant))

        @room.on("participant_disconnected")
        def left(participant):
            emit("participant_left", **self.who(participant))
            if self.kind == "direct" and not self.args.stay_alone and not self.hung_up:
                if not any(p for p in room.remote_participants.values() if p.identity != participant.identity):
                    asyncio.ensure_future(self.peer_gone())

        @room.on("track_subscribed")
        def subscribed(track, publication, participant):
            emit("track_subscribed", source=self.source_name(publication.source), sid=publication.sid, muted=publication.muted, **self.who(participant))
            stats = self.remote(participant)
            if track.kind == rtc.TrackKind.KIND_AUDIO:
                stats.audio_stats()["muted"] = publication.muted
                self.readers[publication.sid] = asyncio.ensure_future(self.read_audio(track, stats))
            elif track.kind == rtc.TrackKind.KIND_VIDEO:
                source = self.source_name(publication.source)
                stats.video_stats(source)["muted"] = publication.muted
                self.readers[publication.sid] = asyncio.ensure_future(self.read_video(track, stats, source))

        @room.on("track_unsubscribed")
        def unsubscribed(track, publication, participant):
            emit("track_unsubscribed", source=self.source_name(publication.source), sid=publication.sid, **self.who(participant))
            reader = self.readers.pop(publication.sid, None)
            if reader:
                reader.cancel()

        @room.on("track_muted")
        def muted(participant, publication):
            if isinstance(participant, rtc.RemoteParticipant):
                emit("track_muted", source=self.source_name(publication.source), **self.who(participant))
                self.set_remote_muted(participant, publication, True)

        @room.on("track_unmuted")
        def unmuted(participant, publication):
            if isinstance(participant, rtc.RemoteParticipant):
                emit("track_unmuted", source=self.source_name(publication.source), **self.who(participant))
                self.set_remote_muted(participant, publication, False)

        @room.on("active_speakers_changed")
        def speakers(participants):
            self.speakers = [self.who(p).get("user") for p in participants]

        @room.on("disconnected")
        def disconnected(reason=None):
            emit("disconnected", reason=str(reason))

        await room.connect(join["url"], join["token"], rtc.RoomOptions(auto_subscribe=True))
        self.connected_at = time.monotonic()
        emit("connected", room=room.name, identity=room.local_participant.identity, remote=[self.who(p) for p in room.remote_participants.values()])
        if room.remote_participants:
            self.peer_seen = True
        for participant in room.remote_participants.values():
            self.remote(participant)
        if not self.args.no_audio:
            await self.publish_audio()
        if self.args.camera:
            await self.video_on("camera")
        if self.args.screen:
            await self.video_on("screen")

    def who(self, participant):
        identity = participant.identity or ""
        user_id = identity.split(":", 1)[0]
        return {"user": self.mm.usernames.get(user_id, user_id), "identity": identity, "name": participant.name}

    @staticmethod
    def source_name(source):
        return {rtc.TrackSource.SOURCE_MICROPHONE: "microphone", rtc.TrackSource.SOURCE_CAMERA: "camera", rtc.TrackSource.SOURCE_SCREENSHARE: "screen", rtc.TrackSource.SOURCE_SCREENSHARE_AUDIO: "screen_audio"}.get(source, "unknown")

    def remote(self, participant):
        stats = self.remotes.get(participant.identity)
        if stats is None:
            info = self.who(participant)
            stats = RemoteStats(info["identity"], info["name"], info["user"])
            self.remotes[participant.identity] = stats
            asyncio.ensure_future(self.mm.names([info["identity"].split(":", 1)[0]]))
        return stats

    def set_remote_muted(self, participant, publication, value):
        stats = self.remote(participant)
        source = self.source_name(publication.source)
        if source == "microphone":
            stats.audio_stats()["muted"] = value
        elif source in ("camera", "screen"):
            stats.video_stats(source)["muted"] = value

    async def read_audio(self, track, stats):
        stream = rtc.AudioStream(track, sample_rate=48000, num_channels=1)
        a = stats.audio_stats()
        try:
            async for event in stream:
                samples = np.frombuffer(event.frame.data, dtype=np.int16)
                a["frames"] += 1
                a["window_frames"] += 1
                a["samples"] += len(samples)
                a["sq"] += float(np.dot(samples.astype(np.float64), samples.astype(np.float64)))
                if len(samples):
                    a["peak"] = max(a["peak"], int(np.abs(samples.astype(np.int32)).max()))
                a["tail"] = np.concatenate([a["tail"][-9600:], samples])
        except asyncio.CancelledError:
            pass
        finally:
            await stream.aclose()

    async def read_video(self, track, stats, source):
        stream = rtc.VideoStream(track)
        v = stats.video_stats(source)
        try:
            async for event in stream:
                frame = event.frame
                v["frames"] += 1
                v["window_frames"] += 1
                v["width"], v["height"] = frame.width, frame.height
                if v["frames"] % 10 == 1 and len(v["crcs"]) < 1000:
                    v["crcs"].add(zlib.crc32(bytes(frame.data[: min(len(frame.data), 200000)])))
        except asyncio.CancelledError:
            pass
        finally:
            await stream.aclose()

    async def publish_audio(self):
        source = rtc.AudioSource(48000, 1)
        self.audio_track = rtc.LocalAudioTrack.create_audio_track("microphone", source)
        options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        self.audio_pub = await self.room.local_participant.publish_track(self.audio_track, options)
        if self.muted:
            self.audio_track.mute()
        emit("published", source="microphone", sid=self.audio_pub.sid, tone_hz=self.args.tone, muted=self.muted)

        async def pump():
            for frame in tone_frames(self.args.tone):
                await source.capture_frame(frame)

        self.tasks.append(asyncio.ensure_future(pump()))

    async def video_on(self, kind):
        if kind in self.video_pubs:
            return
        if kind == "camera":
            width, height = self.args.size
        else:
            width, height = self.args.screen_size
        source = rtc.VideoSource(width, height, is_screencast=(kind == "screen"))
        track = rtc.LocalVideoTrack.create_video_track(kind, source)
        options = rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_CAMERA if kind == "camera" else rtc.TrackSource.SOURCE_SCREENSHARE)
        pattern = Pattern(width, height, kind)
        fps = self.args.fps if kind == "camera" else max(5, self.args.fps // 2)

        stop = threading.Event()

        def pump():
            next_at = time.monotonic()
            while not stop.is_set():
                source.capture_frame(pattern.frame())
                next_at += 1 / fps
                stop.wait(max(0, next_at - time.monotonic()))

        threading.Thread(target=pump, daemon=True).start()
        self.video_tasks[kind] = stop
        await asyncio.sleep(0.2)
        publication = await self.room.local_participant.publish_track(track, options)
        self.video_pubs[kind] = publication
        emit("published", source=kind, sid=publication.sid, width=width, height=height, fps=fps)

    async def video_off(self, kind):
        publication = self.video_pubs.pop(kind, None)
        task = self.video_tasks.pop(kind, None)
        if publication:
            await self.room.local_participant.unpublish_track(publication.sid)
            emit("unpublished", source=kind)
        if task:
            task.set()

    # Actions

    async def action(self, name):
        name = name.strip()
        if not name:
            return
        emit("action", action=name)
        if name == "mute" and self.audio_track:
            self.muted = True
            self.audio_track.mute()
        elif name == "unmute" and self.audio_track:
            self.muted = False
            self.audio_track.unmute()
        elif name in ("camera-on", "screen-on") and self.room:
            await self.video_on(name.split("-")[0])
        elif name in ("camera-off", "screen-off") and self.room:
            await self.video_off(name.split("-")[0])
        elif name == "hangup":
            await self.hangup()
        elif name == "end":
            await self.end_for_everyone()
        elif name == "stats":
            self.report(reset=False)
        elif name == "quit":
            self.ended.set()
        elif name not in ACTIONS:
            emit("error", where="action", error="unknown action " + name)

    async def hangup(self):
        if not self.call_id or self.hung_up:
            return
        self.hung_up = True
        try:
            status, _, _ = await self.mm.request("POST", f"{PLUGIN}/calls/{self.call_id}/hangup", {"device_id": self.device_id}, ok=(200, 204, 404, 409))
            emit("hungup", status=status)
        except HTTPError as error:
            emit("error", where="hangup", status=error.status, body=error.body)
        if self.kind == "channel" and not self.ended.is_set():
            self.end_info = {"end_reason": "left"}
            self.ended.set()

    async def end_for_everyone(self):
        if not self.call_id:
            return
        try:
            status, _, _ = await self.mm.request("POST", f"{PLUGIN}/channels/{self.channel_id}/end", {"call_id": self.call_id}, ok=(200, 204))
            emit("end", status=status)
        except HTTPError as error:
            emit("error", where="end", status=error.status, body=error.body)

    async def peer_gone(self):
        await asyncio.sleep(2)
        if self.room and not self.room.remote_participants and not self.ended.is_set() and not self.hung_up:
            emit("peer_gone")
            await self.hangup()

    def report(self, reset=True):
        interval = self.args.report
        remote = [s.report(interval, reset=reset) for s in self.remotes.values() if self.room and s.identity in self.room.remote_participants]
        local = {"muted": self.muted, "camera": "camera" in self.video_pubs, "screen": "screen" in self.video_pubs}
        emit("stats", connected_s=round(time.monotonic() - self.connected_at, 1) if self.connected_at else None, remote=remote, local=local, speakers=self.speakers)

    async def reporter(self):
        while not self.ended.is_set():
            await asyncio.sleep(self.args.report)
            if self.room and self.connected_at:
                self.report()

    async def scheduled(self):
        while self.connected_at is None and not self.ended.is_set():
            await asyncio.sleep(0.1)
        for at, name in sorted(self.args.at):
            delay = self.connected_at + at - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
            if self.ended.is_set():
                return
            await self.action(name)

    def control(self):
        path = self.args.control
        if not os.path.exists(path):
            os.mkfifo(path)
        loop = asyncio.get_running_loop()

        def read():
            while True:
                with open(path) as stream:
                    for line in stream:
                        asyncio.run_coroutine_threadsafe(self.action(line), loop)

        threading.Thread(target=read, daemon=True).start()

    async def lifetime(self):
        if self.args.duration is not None:
            while self.connected_at is None and not self.ended.is_set():
                await asyncio.sleep(0.1)
            await asyncio.sleep(max(0, self.connected_at + self.args.duration - time.monotonic()))
            if not self.ended.is_set():
                await self.action("hangup")
                await asyncio.sleep(1.5)
                if not self.ended.is_set():
                    self.end_info = self.end_info or {"end_reason": "duration"}
                    self.ended.set()

    async def run_connected(self, join):
        await self.connect(join)
        self.tasks += [asyncio.ensure_future(self.reporter()), asyncio.ensure_future(self.scheduled()), asyncio.ensure_future(self.lifetime())]
        if self.args.control:
            self.control()
        await self.ended.wait()

    async def finish(self):
        if self.room and self.connected_at:
            self.report(reset=False)
        if self.call_id and not self.hung_up and (self.call or {}).get("state") != "ended":
            await self.hangup()
        for stop in self.video_tasks.values():
            stop.set()
        for task in self.tasks + list(self.readers.values()):
            task.cancel()
        if self.room:
            try:
                await self.room.disconnect()
            except Exception:
                pass
        summary = {"call_id": self.call_id, "kind": self.kind, "end": self.end_info}
        if self.call:
            summary["call"] = brief(self.call)
        summary["remote"] = [s.report(0, reset=False) for s in self.remotes.values()]
        for r in summary["remote"]:
            for key in ("audio", "camera", "screen"):
                if key in r:
                    r[key].pop("fps", None)
        emit("summary", **summary)


async def wait_for_ring(peer, from_id, kind, timeout):
    mm = peer.mm
    me = mm.me["id"]
    seen = set()
    deadline = time.monotonic() + timeout

    def matches(call):
        if not isinstance(call, dict) or call.get("id") in seen:
            return False
        if call.get("kind") == "channel" or call.get("state") == "ended":
            return False
        if (call.get("invitees") or {}).get(me) not in ("ringing", "received"):
            return False
        if from_id and call.get("started_by") != from_id:
            return False
        if kind and call.get("kind") != kind:
            return False
        return True

    while time.monotonic() < deadline:
        _, active, _ = await mm.request("GET", f"{PLUGIN}/calls/active")
        for call in active.get("calls", []):
            if matches(call):
                return call
        try:
            name, data = await asyncio.wait_for(peer.ws_events.get(), timeout=1.0)
            if name == "incoming" and matches(data.get("call")):
                return data["call"]
        except asyncio.TimeoutError:
            pass
    return None


async def command_ring(peer, args):
    mm = peer.mm
    users = [u for u in args.target.split(",") if u]
    channel = await mm.channel_for_users(users)
    peer.channel_id = channel["id"]
    emit("channel", channel_id=channel["id"], type=channel["type"], users=users)
    status, body, _ = await mm.request("POST", f"{PLUGIN}/channels/{channel['id']}/ring", {"video": args.video, "device_id": peer.device_id}, ok=(200, 201, 409))
    call = body.get("call") if isinstance(body, dict) else None
    emit("ring", status=status, call=brief(call))
    if status == 409 or not call:
        emit("error", where="ring", status=status, body=body if not isinstance(body, dict) else body.get("message"))
        return 3
    peer.call_id, peer.kind = call["id"], call["kind"]
    await mm.names(list((call.get("invitees") or {}).keys()))
    peer.update_call(call, "ring")
    if call["state"] == "ended":
        peer.end_info = {"end_reason": call.get("end_reason")}
        return 0
    await peer.run_connected(body)
    return 0


async def command_answer(peer, args):
    mm = peer.mm
    from_id = (await mm.user_ids([args.from_user]))[0] if args.from_user else None
    emit("waiting", from_user=args.from_user, timeout=args.timeout)
    call = await wait_for_ring(peer, from_id, args.kind, args.timeout)
    if call is None:
        emit("error", where="answer", error="no ring")
        return 2
    peer.call_id, peer.kind, peer.channel_id = call["id"], call["kind"], call["channel_id"]
    names = await mm.names([call["started_by"]] + list((call.get("invitees") or {}).keys()))
    emit("incoming", caller=names.get(call["started_by"]), call=brief(call))
    peer.update_call(call, "incoming")
    if not args.no_received:
        await mm.request("POST", f"{PLUGIN}/calls/{call['id']}/received", {"device_id": peer.device_id}, ok=(200, 204, 409))
        emit("received")
    if args.ignore:
        await peer.ended.wait()
        return 0
    if args.answer_after:
        try:
            await asyncio.wait_for(peer.ended.wait(), timeout=args.answer_after)
            return 0
        except asyncio.TimeoutError:
            pass
    if args.decline or args.busy:
        reason = "busy" if args.busy else "declined"
        status, body, _ = await mm.request("POST", f"{PLUGIN}/calls/{call['id']}/decline", {"device_id": peer.device_id, "reason": reason}, ok=(200, 204, 409))
        emit("declined", status=status, reason=reason)
        peer.hung_up = True
        try:
            await asyncio.wait_for(peer.ended.wait(), timeout=5)
        except asyncio.TimeoutError:
            pass
        return 0
    status, body, _ = await mm.request("POST", f"{PLUGIN}/calls/{call['id']}/accept", {"device_id": peer.device_id}, ok=(200, 409))
    emit("accepted", status=status, call=brief(body.get("call") if isinstance(body, dict) else None))
    if status != 200:
        return 3
    peer.update_call(body["call"], "accept")
    await peer.run_connected(body)
    return 0


async def command_channel(peer, args):
    mm = peer.mm
    channel = await mm.channel_by_name(args.target, args.team)
    peer.channel_id, peer.kind = channel["id"], "channel"
    emit("channel", channel_id=channel["id"], name=channel["name"], type=channel["type"])
    _, current, _ = await mm.request("GET", f"{PLUGIN}/channels/{channel['id']}")
    existing = (current or {}).get("call")
    body = {"device_id": peer.device_id}
    if existing:
        body["call_id"] = existing["id"]
    status, join, _ = await mm.request("POST", f"{PLUGIN}/channels/{channel['id']}/join", body, ok=(200, 201, 409))
    call = join.get("call") if isinstance(join, dict) else None
    emit("join", status=status, existing=bool(existing), call=brief(call))
    if status != 200 or not call:
        return 3
    peer.call_id, peer.kind = call["id"], call["kind"]
    peer.update_call(call, "join")
    await peer.run_connected(join)
    return 0


async def command_channel_create(mm, args):
    members = [m for m in (args.members or "").split(",") if m]
    ids = await mm.user_ids(members) if members else []
    _, teams, _ = await mm.request("GET", "/api/v4/users/me/teams")
    team = None
    for t in teams:
        if args.team and t["name"] != args.team:
            continue
        ok = True
        for uid in ids:
            try:
                await mm.request("GET", f"/api/v4/teams/{t['id']}/members/{uid}")
            except HTTPError:
                ok = False
                break
        if ok:
            team = t
            break
    if team is None:
        raise SystemExit("no team shared with " + ", ".join(members))
    try:
        _, channel, _ = await mm.request("GET", f"/api/v4/teams/{team['id']}/channels/name/{args.target}")
        created = False
    except HTTPError:
        _, channel, _ = await mm.request("POST", "/api/v4/channels", {"team_id": team["id"], "name": args.target, "display_name": args.display_name or args.target, "type": "O"})
        created = True
    for uid in ids:
        await mm.request("POST", f"/api/v4/channels/{channel['id']}/members", {"user_id": uid}, ok=(200, 201))
    emit("channel", channel_id=channel["id"], name=channel["name"], display_name=channel["display_name"], team=team["name"], created=created, members=members)
    return 0


async def command_status(mm):
    _, active, _ = await mm.request("GET", f"{PLUGIN}/calls/active")
    calls = active.get("calls", [])
    ids = set()
    for c in calls:
        ids.add(c.get("started_by"))
        ids.update(c.get("participant_ids") or [])
        ids.update((c.get("invitees") or {}).keys())
    names = await mm.names(list(ids))
    for c in calls:
        b = brief(c)
        b["started_by"] = names.get(b.get("started_by"))
        b["participant_ids"] = [names.get(i) for i in b.get("participant_ids") or []]
        if b.get("invitees"):
            b["invitees"] = {names.get(k): v for k, v in b["invitees"].items()}
        emit("live_call", call=b)
    emit("status", count=len(calls))
    return 0


async def command_hangup(mm, args, cleanup):
    me = mm.me["id"]
    _, active, _ = await mm.request("GET", f"{PLUGIN}/calls/active")
    for c in active.get("calls", []):
        mine = c.get("started_by") == me or me in (c.get("participant_ids") or []) or me in (c.get("invitees") or {})
        if not mine:
            continue
        invitee = (c.get("invitees") or {}).get(me)
        if invitee in ("ringing", "received"):
            status, _, _ = await mm.request("POST", f"{PLUGIN}/calls/{c['id']}/decline", {"device_id": args.device_id or str(uuid.uuid4()), "reason": "declined"}, ok=(200, 204, 409))
            emit("declined", call_id=c["id"], status=status)
        elif cleanup and c.get("started_by") == me:
            status, _, _ = await mm.request("POST", f"{PLUGIN}/channels/{c['channel_id']}/end", {"call_id": c["id"]}, ok=(200, 204, 403, 409))
            emit("end", call_id=c["id"], status=status)
        else:
            status, _, _ = await mm.request("POST", f"{PLUGIN}/calls/{c['id']}/hangup", {}, ok=(200, 204, 404, 409))
            emit("hungup", call_id=c["id"], kind=c.get("kind"), status=status)
    return 0


def parse_size(text):
    w, h = text.lower().split("x")
    return int(w), int(h)


def parse_at(text):
    t, action = text.split("=", 1)
    if action not in ACTIONS:
        raise argparse.ArgumentTypeError("unknown action " + action)
    return float(t), action


def arguments():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--user", required=True, help="seeded dev user to log in as (bob, l4b0001, ...)")
    parser.add_argument("--out", help="also append the JSON lines to this file")
    parser.add_argument("--device-id", help="device id (default: a new UUID per run)")
    sub = parser.add_subparsers(dest="command", required=True)

    def media(p):
        p.add_argument("--tone", type=float, default=440.0)
        p.add_argument("--no-audio", action="store_true")
        p.add_argument("--muted", action="store_true")
        p.add_argument("--camera", action="store_true")
        p.add_argument("--screen", action="store_true")
        p.add_argument("--size", type=parse_size, default=(640, 360))
        p.add_argument("--screen-size", type=parse_size, default=(1280, 720))
        p.add_argument("--fps", type=int, default=15)
        p.add_argument("--duration", type=float)
        p.add_argument("--report", type=float, default=2.0)
        p.add_argument("--at", type=parse_at, action="append", default=[])
        p.add_argument("--control")
        p.add_argument("--stay-alone", action="store_true")

    p = sub.add_parser("ring", help="ring a DM (one user) or a group DM (comma-separated users)")
    p.add_argument("target")
    p.add_argument("--video", action="store_true", help="a video call (the ring says video)")
    media(p)
    p = sub.add_parser("answer", help="wait for a ring and accept, decline or ignore it")
    p.add_argument("--from", dest="from_user")
    p.add_argument("--kind", choices=("direct", "group"))
    p.add_argument("--timeout", type=float, default=120)
    p.add_argument("--answer-after", type=float, default=0)
    p.add_argument("--decline", action="store_true")
    p.add_argument("--busy", action="store_true")
    p.add_argument("--ignore", action="store_true", help="never answer: wait for the ring to time out (missed)")
    p.add_argument("--no-received", action="store_true", help="do not report the ring as received")
    media(p)
    p = sub.add_parser("channel", help="start or join a channel's call")
    p.add_argument("target", help="channel name (in the user's teams) or id")
    p.add_argument("--team")
    media(p)
    p = sub.add_parser("channel-create", help="create (or reuse) a public channel and add members")
    p.add_argument("target")
    p.add_argument("--members")
    p.add_argument("--team")
    p.add_argument("--display-name")
    sub.add_parser("status", help="the live calls the user can see")
    sub.add_parser("hangup", help="hang up / decline the user's live calls")
    sub.add_parser("cleanup", help="like hangup, and end the calls the user started")
    args = parser.parse_args()
    if getattr(args, "control", None):
        args.control = os.path.abspath(args.control)
    return args


async def main():
    global OUT
    args = arguments()
    OUT = args.out
    async with aiohttp.ClientSession() as session:
        mm = Mattermost(session, args.user)
        await mm.login()
        try:
            if args.command == "status":
                return await command_status(mm)
            if args.command in ("hangup", "cleanup"):
                return await command_hangup(mm, args, args.command == "cleanup")
            if args.command == "channel-create":
                return await command_channel_create(mm, args)
            peer = Peer(args, mm)
            background = [asyncio.ensure_future(peer.websocket()), asyncio.ensure_future(peer.poll_call())]
            code = 1
            try:
                if args.command == "ring":
                    code = await command_ring(peer, args)
                elif args.command == "answer":
                    code = await command_answer(peer, args)
                elif args.command == "channel":
                    code = await command_channel(peer, args)
                if code == 0:
                    try:
                        await asyncio.wait_for(peer.ended.wait(), timeout=args.timeout if args.command == "ring" and not peer.connected_at else None) if not peer.ended.is_set() else None
                    except asyncio.TimeoutError:
                        pass
            finally:
                await peer.finish()
                for task in background:
                    task.cancel()
            return code
        finally:
            await mm.logout()


def run():
    try:
        code = asyncio.run(main())
    except KeyboardInterrupt:
        code = 130
    sys.exit(code or 0)


if __name__ == "__main__":
    run()
