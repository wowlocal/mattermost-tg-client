#!/usr/bin/env python3
import asyncio
import json
import math
import os
import struct
import sys
import uuid

from livekit import api, rtc


async def main():
    credentials = json.loads(sys.stdin.readline()) if os.environ.get("RELAY_TEST_CREDENTIALS_STDIN") else None
    room_name = "relay-media-test-" + uuid.uuid4().hex
    rooms = [rtc.Room() for _ in range(3)]
    audio_received = asyncio.Event()
    video_received = asyncio.Event()
    readers = []

    async def read_audio(track):
        async for event in rtc.AudioStream(track, sample_rate=48000, num_channels=1):
            if any(event.frame.data):
                audio_received.set()
                break

    async def read_video(track):
        async for event in rtc.VideoStream(track):
            if event.frame.width == 640 and event.frame.height == 360:
                video_received.set()
                break

    @rooms[1].on("track_subscribed")
    def subscribed(track, publication, participant):
        if track.kind == rtc.TrackKind.KIND_AUDIO:
            readers.append(asyncio.create_task(read_audio(track)))
        elif track.kind == rtc.TrackKind.KIND_VIDEO:
            readers.append(asyncio.create_task(read_video(track)))

    try:
        for index, room in enumerate(rooms):
            token = credentials["tokens"][index] if credentials else api.AccessToken("devkey", "secret").with_identity("test-"+str(index)).with_grants(api.VideoGrants(room_join=True, room=room_name)).to_jwt()
            url = credentials["url"] if credentials else os.environ.get("RELAY_TEST_URL", "ws://127.0.0.1:17880")
            options = rtc.RoomOptions()
            if os.environ.get("RELAY_TEST_RELAY_ONLY"):
                options.rtc_config = rtc.RtcConfiguration(ice_transport_type=rtc.IceTransportType.TRANSPORT_RELAY)
            await room.connect(url, token, options=options)
        audio = rtc.AudioSource(48000, 1)
        audio_track = rtc.LocalAudioTrack.create_audio_track("microphone-test", audio)
        await rooms[0].local_participant.publish_track(audio_track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        video = rtc.VideoSource(640, 360)
        video_track = rtc.LocalVideoTrack.create_video_track("screen-share-test", video)
        await rooms[0].local_participant.publish_track(video_track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_SCREENSHARE))
        for frame_number in range(200):
            samples = [int(7000 * math.sin(2 * math.pi * 440 * (frame_number * 480 + i) / 48000)) for i in range(480)]
            frame = rtc.AudioFrame(struct.pack("<480h", *samples), 48000, 1, 480)
            await audio.capture_frame(frame)
            if frame_number % 3 == 0:
                pixels = bytes((30, 100, 200, 255)) * (640 * 360)
                video.capture_frame(rtc.VideoFrame(640, 360, rtc.VideoBufferType.RGBA, pixels))
            if audio_received.is_set() and video_received.is_set():
                break
            await asyncio.sleep(0.01)
        await asyncio.wait_for(asyncio.gather(audio_received.wait(), video_received.wait()), 15)
        for _ in range(50):
            if all(len(room.remote_participants) == 2 for room in rooms):
                break
            await asyncio.sleep(0.1)
        assert all(len(room.remote_participants) == 2 for room in rooms), [len(room.remote_participants) for room in rooms]
        print(json.dumps({"participants": 3, "audio_received": True, "screen_share_received": True, "screen_size": "640x360"}))
    finally:
        for reader in readers:
            reader.cancel()
        await asyncio.gather(*(room.disconnect() for room in rooms), return_exceptions=True)


asyncio.run(asyncio.wait_for(main(), timeout=60))
