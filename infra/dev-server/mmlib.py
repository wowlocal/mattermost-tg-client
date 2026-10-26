"""Small shared helpers for seed.py and capture-fixtures.py.

Standard library only (Python 3.9+): .env loading, a REST v4 client, a
multipart encoder, an `mmctl --local` wrapper and a minimal WebSocket client.
"""

import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_DIR = os.path.join(HERE, ".state")


# --------------------------------------------------------------------------
# .env
# --------------------------------------------------------------------------

def load_env(path=None):
    """Parse KEY=VALUE lines from .env (no shell expansion). Real environment
    variables win, so `MM_URL=... ./seed.py` works."""
    path = path or os.path.join(HERE, ".env")
    env = {}
    if not os.path.exists(path):
        sys.exit("error: %s not found; run ./up.sh first (it generates one)" % path)
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
                v = v[1:-1]
            env[k.strip()] = v
    for k in list(env):
        if k in os.environ:
            env[k] = os.environ[k]
    return env


def base_url(env):
    if os.environ.get("MM_URL"):
        return os.environ["MM_URL"].rstrip("/")
    return "http://localhost:%s" % env.get("MM_PORT", "8065")


# --------------------------------------------------------------------------
# REST
# --------------------------------------------------------------------------

class ApiError(Exception):
    def __init__(self, method, url, status, body):
        self.method, self.url, self.status = method, url, status
        self.body = body.decode("utf-8", "replace") if isinstance(body, bytes) else str(body)
        try:
            self.json = json.loads(self.body)
        except ValueError:
            self.json = None
        msg = self.json.get("message") if isinstance(self.json, dict) else self.body[:300]
        sid = self.json.get("id") if isinstance(self.json, dict) else ""
        super().__init__("%s %s -> %s %s: %s" % (method, url, status, sid, msg))

    @property
    def error_id(self):
        return self.json.get("id", "") if isinstance(self.json, dict) else ""


def encode_multipart(fields, files):
    """fields: {name: str}; files: [(field, filename, bytes, mime)]."""
    boundary = "----mmdev" + uuid.uuid4().hex
    out = []
    for name, value in fields.items():
        out.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"\r\n\r\n%s\r\n"
                    % (boundary, name, value)).encode())
    for field, filename, data, mime in files:
        out.append(("--%s\r\nContent-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n"
                    "Content-Type: %s\r\n\r\n" % (boundary, field, filename, mime)).encode())
        out.append(data)
        out.append(b"\r\n")
    out.append(("--%s--\r\n" % boundary).encode())
    return b"".join(out), "multipart/form-data; boundary=%s" % boundary


class Api:
    def __init__(self, base, token=None, label="anon"):
        self.base = base.rstrip("/")
        self.token = token
        self.label = label
        self.user = None
        self.last_headers = {}
        self.last_status = None

    def url(self, path, query=None):
        if path.startswith("http://") or path.startswith("https://"):
            u = path
        elif path.startswith("/static/"):
            u = self.base + path
        else:
            u = self.base + "/api/v4" + path
        if query:
            u += ("&" if "?" in u else "?") + urllib.parse.urlencode(query)
        return u

    def request(self, method, path, body=None, query=None, data=None,
                content_type=None, raw=False, timeout=120, headers=None):
        u = self.url(path, query)
        hdrs = {"Accept": "application/json", "X-Requested-With": "XMLHttpRequest"}
        if self.token:
            hdrs["Authorization"] = "Bearer " + self.token
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            content_type = "application/json"
        if content_type:
            hdrs["Content-Type"] = content_type
        if headers:
            hdrs.update(headers)
        req = urllib.request.Request(u, data=data, method=method, headers=hdrs)
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    payload = resp.read()
                    self.last_headers = dict(resp.headers.items())
                    self.last_status = resp.status
                break
            except urllib.error.HTTPError as e:
                payload = e.read()
                self.last_headers = dict(e.headers.items()) if e.headers else {}
                self.last_status = e.code
                if e.code in (429, 502, 503, 504) and attempt < 4:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise ApiError(method, u, e.code, payload)
            except (urllib.error.URLError, ConnectionError, socket.timeout) as e:
                if attempt < 4:
                    time.sleep(1.5 * (attempt + 1))
                    continue
                raise ApiError(method, u, 0, str(e).encode())
        if raw:
            return payload
        if not payload:
            return None
        try:
            return json.loads(payload)
        except ValueError:
            return payload.decode("utf-8", "replace")

    def get(self, path, **kw):
        return self.request("GET", path, **kw)

    def post(self, path, body=None, **kw):
        return self.request("POST", path, body=body, **kw)

    def put(self, path, body=None, **kw):
        return self.request("PUT", path, body=body, **kw)

    def delete(self, path, body=None, **kw):
        return self.request("DELETE", path, body=body, **kw)

    def get_or_none(self, path, **kw):
        try:
            return self.get(path, **kw)
        except ApiError as e:
            if e.status in (404, 403):
                return None
            raise

    def upload(self, path, fields, files):
        data, ctype = encode_multipart(fields, files)
        return self.request("POST", path, data=data, content_type=ctype, timeout=600)

    @classmethod
    def login(cls, base, login_id, password):
        api = cls(base, label=login_id)
        user = api.post("/users/login", {"login_id": login_id, "password": password})
        token = api.last_headers.get("Token") or api.last_headers.get("token")
        if not token:
            raise RuntimeError("login for %s returned no token" % login_id)
        api.token = token
        api.user = user
        return api

    def ping(self):
        try:
            return self.get("/system/ping", timeout=5)
        except ApiError:
            return None


def wait_for_server(base, timeout=300):
    api = Api(base)
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = api.ping()
        if isinstance(r, dict) and r.get("status") == "OK":
            return r
        time.sleep(2)
    sys.exit("error: %s did not answer /api/v4/system/ping within %ss (is ./up.sh running?)"
             % (base, timeout))


# --------------------------------------------------------------------------
# mmctl --local (inside the container)
# --------------------------------------------------------------------------

def compose_cmd(*args):
    env_file = os.path.join(HERE, ".env")
    cmd = ["docker", "compose", "--project-directory", HERE,
           "-f", os.path.join(HERE, "docker-compose.yml")]
    if os.path.exists(env_file):
        cmd += ["--env-file", env_file]
    return cmd + list(args)


def mmctl(*args, check=True, json_out=True):
    cmd = compose_cmd("exec", "-T", "mattermost", "mmctl", "--local", "--suppress-warnings")
    if json_out:
        cmd.append("--json")
    cmd += list(args)
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.decode("utf-8", "replace")
    if check and p.returncode != 0:
        raise RuntimeError("mmctl %s failed (%s): %s %s"
                           % (" ".join(args), p.returncode, out, p.stderr.decode("utf-8", "replace")))
    if json_out:
        try:
            return json.loads(out) if out.strip() else None
        except ValueError:
            return out
    return out


def compose_cp(src, dest_in_container):
    cmd = compose_cmd("cp", src, "mattermost:" + dest_in_container)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


# --------------------------------------------------------------------------
# Minimal WebSocket client (RFC 6455, client side, text frames only)
# --------------------------------------------------------------------------

class WebSocket:
    def __init__(self, url, token=None, timeout=10):
        p = urllib.parse.urlparse(url)
        host = p.hostname
        port = p.port or (443 if p.scheme == "wss" else 80)
        if p.scheme == "wss":
            raise NotImplementedError("wss not supported by this minimal client")
        path = p.path + ("?" + p.query if p.query else "")
        self.sock = socket.create_connection((host, port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        lines = [
            "GET %s HTTP/1.1" % path,
            "Host: %s:%s" % (host, port),
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: " + key,
            "Sec-WebSocket-Version: 13",
        ]
        if token:
            lines.append("Authorization: Bearer " + token)
        self.sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake: connection closed")
            resp += chunk
        head, self.buf = resp.split(b"\r\n\r\n", 1)
        status = head.split(b"\r\n", 1)[0]
        if b" 101 " not in status + b" ":
            raise ConnectionError("websocket handshake failed: %r" % head[:300])

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def _send_frame(self, opcode, payload):
        header = bytes([0x80 | opcode])
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack("!H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack("!Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_json(self, obj):
        self._send_frame(0x1, json.dumps(obj).encode())

    def recv(self, timeout=None):
        """Return the next text message (str), or None on timeout."""
        self.sock.settimeout(timeout)
        message = b""
        try:
            while True:
                b1, b2 = self._read(2)
                fin, opcode = b1 & 0x80, b1 & 0x0F
                n = b2 & 0x7F
                if n == 126:
                    n = struct.unpack("!H", self._read(2))[0]
                elif n == 127:
                    n = struct.unpack("!Q", self._read(8))[0]
                if b2 & 0x80:
                    mask = self._read(4)
                    payload = bytes(b ^ mask[i % 4] for i, b in enumerate(self._read(n)))
                else:
                    payload = self._read(n)
                if opcode == 0x9:  # ping
                    self._send_frame(0xA, payload)
                    continue
                if opcode == 0xA:  # pong
                    continue
                if opcode == 0x8:
                    raise ConnectionError("websocket closed by server")
                message += payload
                if fin:
                    return message.decode("utf-8", "replace")
        except socket.timeout:
            return None

    def close(self):
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        self.sock.close()
