#!/usr/bin/env python3
"""Capture sanitized REST and WebSocket fixtures for MattermostKit tests.

Logs in as alice, saves JSON responses of the key endpoints to
fixtures/rest/<name>.json, then records alice's WebSocket while this script
(as bob) types, posts, reacts, edits, replies and deletes in ~sandbox and
alice views the channel. Events go to fixtures/ws/.

Sanitizing: response headers (Token, Set-Cookie) are never stored, the
session tokens of alice and bob are replaced with "REDACTED" wherever they
appear, and token/cookie-like keys are dropped. IDs, emails and timestamps
are kept: they are dev-only data and the tests need them to be consistent.

Run ./seed.py first. Re-running overwrites the fixtures (IDs change after
./reset.sh). Standard library only.
"""

import json
import os
import shutil
import sys
import time

import mmlib
from mmlib import Api, ApiError

OUT = os.path.join(mmlib.HERE, "fixtures")
DROP_KEYS = {"token", "Token", "session_token", "MMAUTHTOKEN", "MMCSRF", "csrf", "Set-Cookie", "password"}
KEEP_HEADERS = ("Content-Type", "X-Version-Id", "Etag", "ETag", "Last-Modified")


class Capture:
    def __init__(self):
        self.env = mmlib.load_env()
        self.base = mmlib.base_url(self.env)
        mmlib.wait_for_server(self.base, timeout=60)
        pw = self.env["SEED_USER_PASSWORD"]
        self.alice = Api.login(self.base, "alice", pw)
        self.bob = Api.login(self.base, "bob", pw)
        self.secrets = [self.alice.token, self.bob.token]
        self.manifest = {"server": self.base, "captured_at": int(time.time() * 1000), "rest": [], "ws": []}
        self.login_body = self.alice.user

    # ---- sanitizing / writing ----

    def clean(self, obj):
        if isinstance(obj, dict):
            return {k: self.clean(v) for k, v in obj.items() if k not in DROP_KEYS}
        if isinstance(obj, list):
            return [self.clean(v) for v in obj]
        if isinstance(obj, str):
            for s in self.secrets:
                if s and s in obj:
                    obj = obj.replace(s, "REDACTED")
            return obj
        return obj

    def write(self, rel, obj):
        path = os.path.join(OUT, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        text = json.dumps(self.clean(obj), indent=2, ensure_ascii=False, sort_keys=False)
        for s in self.secrets:
            assert s not in text, "secret leaked into %s" % rel
        with open(path, "w") as f:
            f.write(text + "\n")

    def rest(self, name, method, path, query=None, body=None, api=None, expect_error=False):
        api = api or self.alice
        try:
            data = api.request(method, path, query=query, body=body)
        except ApiError as e:
            if not expect_error:
                raise
            data = e.json
        headers = {k: v for k, v in api.last_headers.items() if k in KEEP_HEADERS}
        self.write("rest/%s.json" % name, data)
        self.manifest["rest"].append({
            "file": "rest/%s.json" % name, "method": method, "path": "/api/v4" + path,
            "query": query or {}, "body": self.clean(body) if body is not None else None,
            "status": api.last_status, "headers": headers})
        print("  rest/%s.json  (%s %s -> %s)" % (name, method, path, api.last_status))
        return data

    # ---- lookups ----

    def find_post(self, channel_id, prefix, api=None):
        api = api or self.alice
        page = 0
        while page < 10:
            pl = api.get("/channels/%s/posts" % channel_id, query={"page": page, "per_page": 200})
            if not pl["order"]:
                break
            for pid in pl["order"]:
                if pl["posts"][pid]["message"].startswith(prefix):
                    return pl["posts"][pid]
            page += 1
        raise RuntimeError("post starting with %r not found; did ./seed.py run?" % prefix)

    # ---- REST ----

    def capture_rest(self):
        a = self.alice
        me = a.user
        eng = a.get("/teams/name/engineering")
        des = a.get("/teams/name/design")

        def chan(team, name):
            return a.get("/teams/%s/channels/name/%s" % (team["id"], name), query={"include_deleted": "true"})

        sandbox, arch, media = chan(eng, "sandbox"), chan(eng, "architecture"), chan(eng, "media")
        firehose, code, integ = chan(eng, "firehose"), chan(eng, "code-review"), chan(eng, "integrations")
        releases = chan(eng, "releases")
        bob_id = self.bob.user["id"]
        dm = a.post("/channels/direct", [me["id"], bob_id])
        self.ids = {"team_engineering": eng["id"], "team_design": des["id"], "sandbox": sandbox["id"],
                    "alice": me["id"], "bob": bob_id}
        t1 = self.find_post(arch["id"], "**RFC: Message ID allocation")
        files_post = self.find_post(media["id"], "Moodboard round 2")
        users = {u["username"]: u["id"] for u in a.post("/users/usernames",
                                                         ["alice", "bob", "carol", "dave", "buildbot"])}

        self.write("rest/users_login.json", self.login_body)
        self.manifest["rest"].append({"file": "rest/users_login.json", "method": "POST",
                                      "path": "/api/v4/users/login",
                                      "body": {"login_id": "alice", "password": "<see .env>"},
                                      "status": 200, "note": "response body only; Token header stripped"})
        print("  rest/users_login.json")
        self.rest("system_ping", "GET", "/system/ping", {"get_server_status": "true"})
        self.rest("users_me", "GET", "/users/me")
        self.rest("users_by_ids", "POST", "/users/ids", body=list(users.values()))
        self.rest("users_status_ids", "POST", "/users/status/ids", body=list(users.values()))
        self.rest("teams", "GET", "/users/me/teams")
        self.rest("team_members", "GET", "/users/me/teams/members")
        self.rest("teams_unread", "GET", "/users/me/teams/unread", {"include_collapsed_threads": "true"})
        self.rest("channels_engineering", "GET", "/users/me/teams/%s/channels" % eng["id"],
                  {"include_deleted": "true"})
        self.rest("channels_all", "GET", "/users/me/channels", {"include_deleted": "true"})
        self.rest("channel_members_engineering", "GET", "/users/me/teams/%s/channels/members" % eng["id"])
        self.rest("channel_members_all", "GET", "/users/me/channel_members", {"page": 0, "per_page": 200})
        self.rest("sidebar_categories_engineering", "GET",
                  "/users/me/teams/%s/channels/categories" % eng["id"])
        self.rest("channel_by_id", "GET", "/channels/%s" % code["id"])
        self.rest("channel_stats", "GET", "/channels/%s/stats" % code["id"])
        self.rest("posts_page_code_review", "GET", "/channels/%s/posts" % code["id"],
                  {"page": 0, "per_page": 60, "collapsedThreads": "true", "collapsedThreadsExtended": "false"})
        fh = self.rest("posts_page_firehose", "GET", "/channels/%s/posts" % firehose["id"],
                       {"page": 0, "per_page": 60, "collapsedThreads": "true"})
        oldest = fh["order"][-1]
        self.rest("posts_page_firehose_before", "GET", "/channels/%s/posts" % firehose["id"],
                  {"before": oldest, "per_page": 60, "collapsedThreads": "true"})
        self.rest("posts_around_unread_firehose", "GET",
                  "/users/me/channels/%s/posts/unread" % firehose["id"],
                  {"limit_before": 30, "limit_after": 30, "collapsedThreads": "true"})
        self.rest("posts_page_integrations", "GET", "/channels/%s/posts" % integ["id"],
                  {"page": 0, "per_page": 30, "collapsedThreads": "true"})
        self.rest("posts_page_dm_bob", "GET", "/channels/%s/posts" % dm["id"], {"page": 0, "per_page": 60})
        self.rest("thread", "GET", "/posts/%s/thread" % t1["id"], {"collapsedThreads": "true"})
        self.rest("thread_paged", "GET", "/posts/%s/thread" % t1["id"],
                  {"perPage": 20, "direction": "down", "collapsedThreads": "true", "skipFetchThreads": "false"})
        self.rest("post_with_files_reactions", "GET", "/posts/%s" % files_post["id"])
        self.rest("post_files_info", "GET", "/posts/%s/files/info" % files_post["id"])
        self.rest("post_reactions", "GET", "/posts/%s/reactions" % t1["id"])
        self.rest("pinned_posts_releases", "GET", "/channels/%s/pinned" % releases["id"])
        self.rest("flagged_posts", "GET", "/users/me/posts/flagged", {"per_page": 60})
        self.rest("user_threads", "GET", "/users/me/teams/%s/threads" % eng["id"],
                  {"per_page": 25, "extended": "false"})
        self.rest("user_thread", "GET", "/users/me/teams/%s/threads/%s" % (eng["id"], t1["id"]))
        self.rest("custom_emoji", "GET", "/emoji", {"page": 0, "per_page": 200, "sort": "name"})
        self.rest("preferences", "GET", "/users/me/preferences")
        self.rest("client_config", "GET", "/config/client", {"format": "old"})
        self.rest("client_license", "GET", "/license/client", {"format": "old"})
        self.rest("error_post_not_found", "GET", "/posts/zzzzzzzzzzzzzzzzzzzzzzzzzz", expect_error=True)

    # ---- WebSocket ----

    def capture_ws(self):
        ws_url = self.base.replace("http://", "ws://") + "/api/v4/websocket"
        events = []

        def drain(quiet=1.0, until=None, max_wait=8.0):
            deadline = time.time() + max_wait
            seen = False
            while time.time() < deadline:
                msg = ws.recv(timeout=quiet)
                if msg is None:
                    if until is None or seen:
                        return
                    continue
                ev = json.loads(msg)
                events.append(ev)
                name = ev.get("event") or ("response:%s" % ev.get("seq_reply"))
                print("  ws  %s" % name)
                if until and ev.get("event") in until:
                    seen = True

        ws = mmlib.WebSocket(ws_url, token=self.alice.token)
        try:
            drain(until={"hello"})
            sandbox = self.ids["sandbox"]
            # a client->server action with a reply (seq_reply)
            ws.send_json({"action": "get_statuses", "seq": 1})
            drain(quiet=0.5)
            b = self.bob
            bob_id = self.ids["bob"]
            try:
                b.post("/users/%s/typing" % bob_id, {"channel_id": sandbox, "parent_id": ""})
            except ApiError:
                bws = mmlib.WebSocket(ws_url, token=b.token)
                bws.send_json({"action": "user_typing", "seq": 1, "data": {"channel_id": sandbox, "parent_id": ""}})
                time.sleep(0.5)
                bws.close()
            drain(until={"typing"})
            post = b.post("/posts", {"channel_id": sandbox, "message": "fixture capture: hello from bob :wave:"})
            drain(until={"posted"})
            b.post("/reactions", {"user_id": bob_id, "post_id": post["id"], "emoji_name": "+1"})
            drain(until={"reaction_added"})
            b.put("/posts/%s/patch" % post["id"], {"message": "fixture capture: hello from bob :wave: (edited)"})
            drain(until={"post_edited"})
            b.delete("/users/%s/posts/%s/reactions/%s" % (bob_id, post["id"], "+1"))
            drain(until={"reaction_removed"})
            self.alice.post("/posts", {"channel_id": sandbox, "root_id": post["id"],
                                       "message": "alice replies (fixture capture)"})
            drain(quiet=0.7)
            b.post("/posts", {"channel_id": sandbox, "root_id": post["id"], "message": "bob replies in the thread"})
            drain(until={"thread_updated", "posted"}, quiet=1.0)
            b.delete("/posts/%s" % post["id"])
            drain(until={"post_deleted"})
            self.alice.post("/channels/members/%s/view" % self.ids["alice"],
                            {"channel_id": sandbox, "collapsed_threads_supported": True})
            drain(until={"channel_viewed", "multiple_channels_viewed"})
            drain(quiet=1.0, max_wait=2.0)
        finally:
            ws.close()

        self.write("ws/events.json", events)
        self.manifest["ws"].append({"file": "ws/events.json", "note": "full ordered recording"})
        firsts = {}
        for ev in events:
            key = ev.get("event") or "response_seq_%s" % ev.get("seq_reply")
            if ev.get("event") == "posted":
                data = ev.get("data", {})
                try:
                    root = json.loads(data.get("post", "{}")).get("root_id")
                except ValueError:
                    root = ""
                key = "posted_reply" if root else "posted"
            firsts.setdefault(key, ev)
        for key, ev in firsts.items():
            self.write("ws/%s.json" % key, ev)
            self.manifest["ws"].append({"file": "ws/%s.json" % key, "event": ev.get("event"),
                                        "seq": ev.get("seq")})
        wanted = {"hello", "posted", "typing", "reaction_added", "post_edited", "post_deleted"}
        missing = wanted - set(firsts)
        if "channel_viewed" not in firsts and "multiple_channels_viewed" not in firsts:
            missing.add("channel_viewed")
        if missing:
            print("warning: did not see events: %s" % ", ".join(sorted(missing)))
        self.manifest["ws_events_seen"] = sorted(firsts)

    def run(self):
        if os.path.isdir(OUT):
            for sub in ("rest", "ws"):
                shutil.rmtree(os.path.join(OUT, sub), ignore_errors=True)
        print("REST fixtures:")
        self.capture_rest()
        print("WebSocket events:")
        self.capture_ws()
        with open(os.path.join(OUT, "manifest.json"), "w") as f:
            json.dump(self.manifest, f, indent=2, ensure_ascii=False)
            f.write("\n")
        for api in (self.alice, self.bob):
            try:
                api.post("/users/logout")
            except ApiError:
                pass
        print("wrote %d REST and %d WS fixtures to %s" % (len(self.manifest["rest"]),
                                                          len(self.manifest["ws"]), OUT))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(__doc__)
        sys.exit(0)
    Capture().run()
