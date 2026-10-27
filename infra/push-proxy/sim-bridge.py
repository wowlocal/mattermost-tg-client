#!/usr/bin/env python3
"""DEVELOPMENT ONLY: delivers the dev server's pushes to an iOS simulator, without APNs.

The Mattermost server sends pushes to its push proxy (POST /api/v1/send_push, the server's
model.PushNotification as JSON). This bridge stands in for that URL:

1. it forwards every request unchanged to the real push proxy (--proxy, default http://127.0.0.1:8066), so
   the proxy's logs show the server → proxy leg, and its acknowledgements (POST /api/v1/ack) as well;
2. for pushes to Relay's platforms (relay_apple, relay_apple_sandbox; apple_rn, apple_rnbeta from Mattermost 12+) it builds the APNs payload exactly as
   mattermost-push-proxy 6.6.0 does (server/apple_notification_server.go, SendNotification) and delivers it
   to the simulator (real ack ids, post ids, server id):
   - `--deliver simctl` (default): `xcrun simctl push <udid> org.relaychat.Relay`. iOS shows the server's
     text as is: simulated pushes never start the notification service extension (only APNs delivery
     does), and a background push (`clear`) only triggers a background fetch, without its payload.
   - `--deliver app`: hands the payload to a running debug build (debug remote `simulate-push`), which runs
     the notification service extension's code (MattermostPushService) and schedules the result as a local
     notification `--app-delay` seconds later, so it is delivered while the app is in the background, locked
     or killed. `clear` and `update_badge` go to the app's handler for background pushes. The app must be
     in the foreground when the push arrives.
3. it answers {"status": "OK"} when the simulator took the push (the proxy's own answer is only logged:
   without a real APNs key it is a failure, and a "remove" answer would make the server drop the device).

Use it with configure-dev-server.py --push-server http://host.docker.internal:8166 (the server runs in a
container; host.docker.internal is this Mac). Payloads can be saved for fixtures (--save-dir); the
signature (a JWT with the device token) is replaced there.

  ./sim-bridge.py --udid <simulator udid> [--port 8166] [--proxy http://127.0.0.1:8066] [--save-dir DIR]
"""
import argparse
import datetime
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BUNDLE_ID = "org.relaychat.Relay"
# Mattermost 12+ servers refuse Relay's own platforms; Relay registers there as apple_rn / apple_rnbeta (4E).
RELAY_PLATFORMS = {"relay_apple", "relay_apple_sandbox", "apple_rn", "apple_rnbeta"}


def log(text):
    print("%s %s" % (datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3], text), flush=True)


def apns_payload(msg):
    """mattermost-push-proxy 6.6.0 SendNotification (apple_notification_server.go), standard transport.
    Returns (payload, app version). emoji.Sprint (":smile:" → 😄) is left out."""
    platform = msg.get("platform", "")
    app_version = 1
    if "-v" in platform:
        index = platform.index("-v")
        try:
            app_version = int(platform[index + 2:])
        except ValueError:
            pass
    aps = {}
    badge = msg.get("badge", 0)
    push_type = msg.get("type", "")
    if badge == 0 and push_type == "clear" and app_version > 1:
        aps["badge"] = 1
    elif badge != -1:
        aps["badge"] = badge
    payload = {}
    if msg.get("is_id_loaded"):
        aps["category"] = msg.get("category", "")
        aps["sound"] = "default"
        payload["version"] = msg.get("version", "")
        payload["id_loaded"] = True
        aps["mutable-content"] = 1
        aps["alert"] = {"body": msg.get("message", "")}
        aps["content-available"] = 1
    elif push_type in ("message", "session"):
        aps["category"] = msg.get("category", "")
        aps["sound"] = "default"
        payload["version"] = msg.get("version", "")
        aps["mutable-content"] = 1
        if push_type == "message":
            aps["content-available"] = 1
        if msg.get("channel_name") and msg.get("version") == "v2":
            aps["alert"] = {"title": msg["channel_name"], "body": msg.get("message", "")}
            payload["channel_name"] = msg["channel_name"]
        else:
            aps["alert"] = msg.get("message", "")
            if msg.get("channel_name"):
                payload["channel_name"] = msg["channel_name"]
    elif push_type in ("clear", "test"):
        aps["content-available"] = 1
    payload["type"] = push_type
    payload["sub_type"] = msg.get("sub_type", "")
    payload["server_id"] = msg.get("server_id", "")
    if msg.get("ack_id"):
        payload["ack_id"] = msg["ack_id"]
    payload["is_crt_enabled"] = bool(msg.get("is_crt_enabled"))
    if msg.get("channel_id"):
        payload["channel_id"] = msg["channel_id"]
        if msg.get("is_crt_enabled") and msg.get("root_id"):
            aps["thread-id"] = msg["root_id"]
        else:
            aps["thread-id"] = msg["channel_id"]
    payload["signature"] = msg.get("signature") or "NO_SIGNATURE"
    for key in ("team_id", "sender_id", "sender_name", "post_id", "root_id", "override_username", "override_icon_url", "from_webhook"):
        if msg.get(key):
            payload[key] = msg[key]
    payload["aps"] = aps
    return payload, app_version


class Bridge:
    def __init__(self, args):
        self.args = args
        self.lock = threading.Lock()
        self.app_lock = threading.Lock()
        self.count = 0

    def forward(self, path, body):
        if not self.args.proxy:
            return None
        request = urllib.request.Request(self.args.proxy.rstrip("/") + path, data=body, method="POST", headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=40) as response:
                return response.read().decode(errors="replace").strip()
        except urllib.error.URLError as error:
            return "proxy unreachable: %s" % error

    def deliver(self, msg):
        platform = msg.get("platform", "").split("-v")[0]
        if platform not in RELAY_PLATFORMS:
            log("  not a Relay platform (%r); not delivered" % msg.get("platform"))
            return False
        if self.args.device_token and msg.get("device_id") != self.args.device_token:
            log("  device %s… is not --device-token; not delivered" % msg.get("device_id", "")[:8])
            return False
        payload, _ = apns_payload(msg)
        payload["Simulator Target Bundle"] = BUNDLE_ID
        if self.args.save_dir:
            os.makedirs(self.args.save_dir, exist_ok=True)
            saved = dict(payload)
            saved["signature"] = "NO_SIGNATURE"
            name = "%s-%s-%s.apns" % (datetime.datetime.now().strftime("%H%M%S"), msg.get("type", "push"), msg.get("ack_id", "")[:6])
            with open(os.path.join(self.args.save_dir, name), "w") as f:
                json.dump(saved, f, indent=2, sort_keys=True)
                f.write("\n")
        if self.args.deliver == "app":
            return self.deliver_to_app(payload)
        with tempfile.NamedTemporaryFile("w", suffix=".apns", delete=False) as f:
            json.dump(payload, f)
            path = f.name
        try:
            result = subprocess.run(["xcrun", "simctl", "push", self.args.udid, BUNDLE_ID, path], capture_output=True, text=True, timeout=30)
        finally:
            os.unlink(path)
        if result.returncode != 0:
            log("  simctl push failed: %s" % (result.stderr.strip() or result.stdout.strip()))
            return False
        log("  delivered to simulator %s… (%s)" % (self.args.udid[:8], result.stdout.strip()))
        return True

    def deliver_to_app(self, payload):
        """The debug remote's simulate-push (MattermostUI): the app runs the extension's code on the payload."""
        try:
            container = subprocess.check_output(["xcrun", "simctl", "get_app_container", self.args.udid, BUNDLE_ID, "data"], text=True).strip()
        except subprocess.CalledProcessError:
            log("  the app is not installed")
            return False
        directory = os.path.join(container, "Documents", "relay-debug")
        os.makedirs(directory, exist_ok=True)
        command = {"action": "simulate-push", "id": uuid.uuid4().hex, "payload": json.dumps(payload), "delay": str(self.args.app_delay)}
        # One command file: hand pushes over one at a time, each after the app answered the previous one.
        with self.app_lock:
            with open(os.path.join(directory, "command.json"), "w") as f:
                json.dump(command, f)
            subprocess.check_call(["xcrun", "simctl", "spawn", self.args.udid, "notifyutil", "-p", "org.relaychat.Relay.debug"])
            deadline = time.time() + 15
            while time.time() < deadline:
                try:
                    with open(os.path.join(directory, "result.json")) as f:
                        result = json.load(f)
                    if result.get("id") == command["id"]:
                        log("  handed to the app (simulate-push, shown in %s s): %s" % (self.args.app_delay, "ok" if result.get("ok") else result.get("error")))
                        return bool(result.get("ok"))
                except (OSError, ValueError):
                    pass
                time.sleep(0.1)
        log("  the app did not answer (is a debug build in the foreground?)")
        return False


def make_handler(bridge):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, fmt, *args):
            pass

        def reply(self, code, body):
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            self.reply(200, {"status": "OK", "bridge": "relay sim-bridge"})

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            try:
                msg = json.loads(body or b"{}")
            except ValueError:
                self.reply(400, {"status": "FAIL", "error": "bad json"})
                return
            if self.path == "/api/v1/send_push":
                log("send_push %s (platform %s, ack %s, channel %s, post %s)" % (msg.get("type"), msg.get("platform"), msg.get("ack_id"), msg.get("channel_id"), msg.get("post_id")))
                proxy_answer = bridge.forward(self.path, body)
                if proxy_answer is not None:
                    log("  proxy: %s" % proxy_answer)
                ok = bridge.deliver(msg)
                self.reply(200, {"status": "OK"} if ok else {"status": "FAIL", "error": "not delivered to the simulator"})
            elif self.path == "/api/v1/ack":
                log("ack %s (%s, platform %s)" % (msg.get("id"), msg.get("type"), msg.get("platform")))
                proxy_answer = bridge.forward(self.path, body)
                if proxy_answer is not None:
                    log("  proxy: %s" % proxy_answer)
                self.reply(200, {"status": "OK"})
            else:
                self.reply(404, {"status": "FAIL", "error": "unknown path"})

    return Handler


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--udid", required=True, help="simulator to deliver to")
    parser.add_argument("--port", type=int, default=8166)
    parser.add_argument("--bind", default="127.0.0.1", help="address to listen on (OrbStack forwards host.docker.internal to the Mac's loopback)")
    parser.add_argument("--proxy", default="http://127.0.0.1:8066", help="the real push proxy ('' to skip)")
    parser.add_argument("--device-token", help="only deliver pushes for this APNs token (hex)")
    parser.add_argument("--save-dir", help="save every delivered APNs payload here")
    parser.add_argument("--deliver", choices=["simctl", "app"], default="simctl", help="simctl push, or the app's simulate-push (runs the extension's code)")
    parser.add_argument("--app-delay", type=float, default=1.0, help="--deliver app: seconds until the notification is shown")
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.bind, args.port), make_handler(Bridge(args)))
    log("sim-bridge listening on %s:%d → simulator %s, proxy %s" % (args.bind, args.port, args.udid, args.proxy or "-"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
