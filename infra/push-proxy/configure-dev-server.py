#!/usr/bin/env python3
"""Points the local dev server (infra/dev-server) at Relay's push proxy, through the REST API.

  ./configure-dev-server.py                      # push server http://push-proxy:8066, contents "full"
  ./configure-dev-server.py --enable             # also turn pushes on (recreates the mattermost container)
  ./configure-dev-server.py --push-server http://host.docker.internal:8166   # through sim-bridge.py
  ./configure-dev-server.py --status             # show the settings
  ./configure-dev-server.py --sessions alice,bob # show the users' sessions and their push device ids

RELAY_DEV_SERVER_DIR=<path to infra/dev-server> selects another checkout's dev server (default: ../dev-server).

Settings (System Console → Environment → Push Notification Server):
- EmailSettings.PushNotificationServer: the proxy's URL as the server sees it. The proxy container is on the
  dev server's network as "push-proxy"; sim-bridge.py runs on the host (host.docker.internal).
- EmailSettings.PushNotificationContents: "full" (sender and text in the push). "id_loaded" (the device
  fetches the text through POST /notifications/ack) needs a licensed server: the unlicensed Team Edition dev
  server silently falls back to "generic" (BuildPushNotificationMessage, server/channels/app/notification_push.go).
- EmailSettings.SendPushNotifications: the dev server's docker-compose.yml pins it to false with an
  environment variable, which the REST API cannot override. --enable recreates the container with
  dev-server-push.override.yml (data stays in the volumes; about 20 s of downtime).

Standard library only. Uses the sysadmin credentials from infra/dev-server/.env.
"""
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
# The dev server checkout whose .env and compose project are in use (a git worktree has no .env of its own).
DEV_SERVER = os.path.normpath(os.environ.get("RELAY_DEV_SERVER_DIR") or os.path.join(HERE, "..", "dev-server"))


def load_env(path):
    env = {}
    if not os.path.exists(path):
        sys.exit("error: %s not found; start the dev server first (infra/dev-server/up.sh)" % path)
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key.strip()] = value.strip().strip("'\"")
    return env


class Client:
    def __init__(self, base):
        self.base = base.rstrip("/") + "/api/v4"
        self.token = None

    def request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json", "X-Requested-With": "XMLHttpRequest"}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        request = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                raw = response.read()
                return response.status, response.headers, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as error:
            raw = error.read()
            try:
                return error.code, error.headers, json.loads(raw)
            except ValueError:
                return error.code, error.headers, raw.decode(errors="replace")

    def login(self, login_id, password):
        status, headers, body = self.request("POST", "/users/login", {"login_id": login_id, "password": password})
        if status != 200:
            sys.exit("error: login as %s failed (%s): %s" % (login_id, status, body))
        self.token = headers["Token"]

    def logout(self):
        if self.token:
            self.request("POST", "/users/logout")
            self.token = None


def wait_for_ping(base, timeout=180):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with urllib.request.urlopen(base.rstrip("/") + "/api/v4/system/ping", timeout=5) as response:
                if response.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(1)
    return False


def recreate_with_override():
    compose = [
        "docker", "compose", "-p", "mmdev",
        "--project-directory", DEV_SERVER,
        "-f", os.path.join(DEV_SERVER, "docker-compose.yml"),
        "-f", os.path.join(HERE, "dev-server-push.override.yml"),
        "--env-file", os.path.join(DEV_SERVER, ".env"),
        "up", "-d", "--wait", "--wait-timeout", "300", "mattermost",
    ]
    print("==> recreating the dev server's mattermost container with SendPushNotifications=true")
    subprocess.check_call(compose)


def show_status(client):
    _, _, config = client.request("GET", "/config")
    _, _, environment = client.request("GET", "/config/environment")
    email = config.get("EmailSettings", {})
    pinned = (environment or {}).get("EmailSettings", {})
    for key in ("SendPushNotifications", "PushNotificationServer", "PushNotificationContents"):
        print("  %-26s %-40s%s" % (key, json.dumps(email.get(key)), "  (set by an environment variable)" if key in pinned else ""))
    _, _, client_config = client.request("GET", "/config/client?format=old")
    print("  %-26s %s" % ("DiagnosticId (server_id)", client_config.get("DiagnosticId")))
    return email, pinned


def show_sessions(client, usernames):
    for username in usernames:
        status, _, user = client.request("GET", "/users/username/" + username)
        if status != 200:
            print("  %s: no such user" % username)
            continue
        _, _, sessions = client.request("GET", "/users/%s/sessions" % user["id"])
        print("  %s (%s): %d session(s)" % (username, user["id"], len(sessions or [])))
        for session in sessions or []:
            device = session.get("device_id") or ""
            platform, _, token = device.partition(":")
            shown = "%s:%s…%s" % (platform, token[:8], token[-4:]) if token else "-"
            print("    session %s… device %s  last activity %s" % (session["id"][:8], shown, time.strftime("%H:%M:%S", time.localtime(session.get("last_activity_at", 0) / 1000))))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--push-server", default="http://push-proxy:8066")
    parser.add_argument("--contents", default="full", choices=["generic_no_channel", "generic", "full", "id_loaded"])
    parser.add_argument("--enable", action="store_true", help="also turn SendPushNotifications on (recreates the container)")
    parser.add_argument("--status", action="store_true", help="only show the settings")
    parser.add_argument("--sessions", help="comma-separated usernames whose sessions to show")
    args = parser.parse_args()

    env = load_env(os.path.join(DEV_SERVER, ".env"))
    base = os.environ.get("MM_URL") or "http://localhost:%s" % env.get("MM_PORT", "8065")
    client = Client(base)
    client.login(env["SEED_ADMIN_USERNAME"], env["SEED_ADMIN_PASSWORD"])
    try:
        if args.sessions:
            show_sessions(client, [u.strip() for u in args.sessions.split(",") if u.strip()])
            return
        if args.status:
            show_status(client)
            return

        status, _, body = client.request("PUT", "/config/patch", {"EmailSettings": {
            "PushNotificationServer": args.push_server,
            "PushNotificationContents": args.contents,
        }})
        if status != 200:
            sys.exit("error: PUT /config/patch failed (%s): %s" % (status, body))
        print("==> PushNotificationServer = %s, PushNotificationContents = %s" % (args.push_server, args.contents))

        email, pinned = show_status(client)
        if not email.get("SendPushNotifications"):
            if "SendPushNotifications" in pinned and not args.enable:
                print("note: SendPushNotifications is pinned to false by the dev server's environment;")
                print("      run again with --enable to recreate its container with %s" % os.path.join(HERE, "dev-server-push.override.yml"))
            elif "SendPushNotifications" in pinned:
                client.logout()
                recreate_with_override()
                if not wait_for_ping(base):
                    sys.exit("error: the dev server did not come back")
                client.login(env["SEED_ADMIN_USERNAME"], env["SEED_ADMIN_PASSWORD"])
                show_status(client)
            else:
                client.request("PUT", "/config/patch", {"EmailSettings": {"SendPushNotifications": True}})
                show_status(client)
    finally:
        client.logout()


if __name__ == "__main__":
    main()
