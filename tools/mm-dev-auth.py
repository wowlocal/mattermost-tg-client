#!/usr/bin/env python3
"""Auth helpers for the local Mattermost dev server (infra/dev-server), standard library only.

Used to verify Relay's login lifecycle (docs/BUILD.md, "Login and account lifecycle checks"):

  tools/mm-dev-auth.py enable-server-mfa      # sysadmin: ServiceSettings.EnableMultifactorAuthentication = true
  tools/mm-dev-auth.py enable-mfa carol        # generate carol's TOTP secret and activate MFA
  tools/mm-dev-auth.py code carol              # print carol's current 6-digit code
  tools/mm-dev-auth.py disable-mfa carol       # sysadmin: turn carol's MFA off again
  tools/mm-dev-auth.py sessions dave           # sysadmin: list dave's sessions
  tools/mm-dev-auth.py revoke-sessions dave    # sysadmin: revoke all of dave's sessions (session expiry test)

Passwords come from infra/dev-server/.env (read only). TOTP secrets are kept in
build-input/dev-mfa-secrets.json (git-ignored), never under infra/.
"""
import base64
import hashlib
import hmac
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.environ.get("MM_URL", "http://localhost:8065")
SECRETS = os.path.join(ROOT, "build-input", "dev-mfa-secrets.json")


def env_file():
    candidates = [os.environ.get("MM_DEV_ENV"), os.path.join(ROOT, "infra", "dev-server", ".env")]
    # A git worktree under .claude/worktrees has no .env (git-ignored); use the main checkout's.
    marker = os.sep + ".claude" + os.sep + "worktrees" + os.sep
    if marker in ROOT:
        candidates.append(os.path.join(ROOT.split(marker)[0], "infra", "dev-server", ".env"))
    for path in candidates:
        if path and os.path.exists(path):
            return path
    sys.exit("no infra/dev-server/.env found (set MM_DEV_ENV)")


def read_env():
    values = {}
    with open(env_file()) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                values[key] = value
    return values


def request(method, path, token=None, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(SERVER + "/api/v4" + path, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req) as response:
            text = response.read().decode()
            return response.status, dict(response.headers), (json.loads(text) if text else None)
    except urllib.error.HTTPError as error:
        text = error.read().decode()
        try:
            payload = json.loads(text)
        except ValueError:
            payload = text
        return error.code, dict(error.headers), payload


def login(login_id, password, mfa=None):
    body = {"login_id": login_id, "password": password}
    if mfa:
        body["token"] = mfa
    status, headers, payload = request("POST", "/users/login", body=body)
    if status != 200:
        sys.exit("login %s failed: %s %s" % (login_id, status, payload))
    return headers.get("Token") or headers.get("token"), payload


def admin_token():
    env = read_env()
    token, _ = login(env["SEED_ADMIN_USERNAME"], env["SEED_ADMIN_PASSWORD"])
    return token


def user_id(token, username):
    status, _, payload = request("GET", "/users/username/" + username, token=token)
    if status != 200:
        sys.exit("no user %s: %s" % (username, payload))
    return payload["id"]


def load_secrets():
    if os.path.exists(SECRETS):
        with open(SECRETS) as f:
            return json.load(f)
    return {}


def save_secrets(secrets):
    os.makedirs(os.path.dirname(SECRETS), exist_ok=True)
    with open(SECRETS, "w") as f:
        json.dump(secrets, f, indent=2)
    os.chmod(SECRETS, 0o600)


def totp(secret, at=None, step=30, digits=6):
    key = base64.b32decode(secret.upper() + "=" * (-len(secret) % 8))
    counter = int((at if at is not None else time.time()) // step)
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF
    return str(value % (10 ** digits)).zfill(digits)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    command = argv[1]
    if command == "enable-server-mfa":
        status, _, payload = request("PUT", "/config/patch", token=admin_token(), body={"ServiceSettings": {"EnableMultifactorAuthentication": True}})
        print(status, (payload or {}).get("ServiceSettings", {}).get("EnableMultifactorAuthentication"))
    elif command == "enable-mfa":
        username = argv[2]
        password = read_env()["SEED_USER_PASSWORD"]
        token, user = login(username, password)
        status, _, payload = request("POST", "/users/%s/mfa/generate" % user["id"], token=token)
        if status != 200:
            sys.exit("generate failed: %s %s" % (status, payload))
        secret = payload["secret"]
        status, _, payload = request("PUT", "/users/%s/mfa" % user["id"], token=token, body={"activate": True, "code": totp(secret)})
        if status != 200:
            sys.exit("activate failed: %s %s" % (status, payload))
        secrets = load_secrets()
        secrets[username] = secret
        save_secrets(secrets)
        print("MFA active for %s; secret saved to %s" % (username, SECRETS))
    elif command == "code":
        secret = load_secrets().get(argv[2])
        if not secret:
            sys.exit("no saved secret for %s" % argv[2])
        print(totp(secret))
    elif command == "disable-mfa":
        token = admin_token()
        status, _, payload = request("PUT", "/users/%s/mfa" % user_id(token, argv[2]), token=token, body={"activate": False})
        print(status, payload)
    elif command == "sessions":
        token = admin_token()
        status, _, payload = request("GET", "/users/%s/sessions" % user_id(token, argv[2]), token=token)
        for session in payload or []:
            props = session.get("props", {})
            print(session["id"], time.strftime("%H:%M:%S", time.localtime(session["create_at"] / 1000)), props.get("platform", ""), props.get("browser", ""), props.get("os", ""))
    elif command == "revoke-sessions":
        token = admin_token()
        status, _, payload = request("POST", "/users/%s/sessions/revoke/all" % user_id(token, argv[2]), token=token)
        print(status, payload)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
