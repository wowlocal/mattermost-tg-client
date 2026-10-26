#!/usr/bin/env python3
"""Large-server data for Relay's performance checks (Phase 4B) on the local dev server (infra/dev-server).

Everything lives in one extra team, `relay-4b-large` ("4B Large"), and in users named `l4b0001`…; the seeded
teams, channels and users are not touched (except that the member named by --member, alice by default, joins
the team, some of its channels and gets DMs/GMs with load users):

  tools/mm-large-server.py seed                 # team, 1,000 channels, 2,000 users, ~40k posts (bulk import)
  tools/mm-large-server.py join                 # alice: team + 500 channels (read), 40 DMs, 5 GMs, then unread posts
  tools/mm-large-server.py mark-read            # alice reads all her load channels
  tools/mm-large-server.py unread [--count 150] # new posts by load users in alice's channels (some @alice)
  tools/mm-large-server.py status               # what exists, alice's memberships
  tools/mm-large-server.py detach               # alice leaves the team (and its channels); DMs/GMs hidden
  tools/mm-large-server.py purge                # delete the team and the load users permanently

The server's unlicensed user limits (GET /api/v4/limits/server: 200 soft, 250 hard on 11.7 Team Edition) cap
active users, so `seed` creates the first --active (190) load users active and the rest deactivated. Deactivated
users still author posts and are channel members, which is what the client has to load.

Standard library only. Passwords come from infra/dev-server/.env (read only); the load users that post share
SEED_USER_PASSWORD. Bulk import runs through `mmctl --local` inside the Mattermost container.
"""
import argparse
import concurrent.futures
import io
import json
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.request
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SERVER = os.environ.get("MM_URL", "http://localhost:8065")
DEV_SERVER = os.path.join(ROOT, "infra", "dev-server")
TEAM = "relay-4b-large"
TEAM_DISPLAY = "4B Large"
PREFIX = "l4b"
CHANNEL_PREFIX = "l4b-"
POSTERS = 5  # l4b0001…l4b0005: members of every channel, with passwords (they post the unread posts)

FIRST = ["Ada", "Ben", "Cleo", "Dan", "Eve", "Finn", "Gus", "Hana", "Ivo", "Jun", "Kai", "Lea", "Mo", "Nia",
         "Oz", "Pia", "Quin", "Rae", "Sol", "Tea", "Uma", "Vic", "Wen", "Xia", "Yuri", "Zoe"]
LAST = ["Abbott", "Brandt", "Costa", "Dietz", "Engel", "Fischer", "Garcia", "Hoffmann", "Ito", "Jansen",
        "Kowalski", "Lindqvist", "Moreau", "Nakamura", "Okafor", "Petrov", "Quist", "Rossi", "Sato", "Tanaka",
        "Ueda", "Varga", "Weber", "Xu", "Yilmaz", "Zimmer"]
TOPICS = ["alpha", "billing", "checkout", "data", "edge", "frontend", "growth", "hiring", "infra", "jobs",
          "kubernetes", "legal", "mobile", "network", "onboarding", "payments", "quality", "release", "search",
          "security", "support", "tooling", "ux", "vendors", "web", "yearly", "zones"]
LINES = [
    "Deploy of {topic} finished, all green.",
    "Can someone review the {topic} PR? It's small.",
    "**Heads-up:** {topic} maintenance window tonight 22:00–23:00 UTC.",
    "Notes from today's {topic} sync: https://example.com/notes/{n}",
    "I'll take the {topic} ticket #{n}.",
    "Benchmark for {topic}: p50 {n} ms, p99 {m} ms.",
    "`{topic}` flag is on for 10% of users.",
    "Thanks! :+1:",
    "lgtm",
    "Moving this to tomorrow's standup.",
    "Has anyone seen the {topic} alert firing?",
    "> quoted from the {topic} doc\nagreed with this part",
]


def env_file():
    candidates = [os.environ.get("MM_DEV_ENV"), os.path.join(DEV_SERVER, ".env")]
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
        with urllib.request.urlopen(req, timeout=60) as response:
            text = response.read().decode()
            return response.status, dict(response.headers), (json.loads(text) if text else None)
    except urllib.error.HTTPError as error:
        text = error.read().decode()
        try:
            payload = json.loads(text)
        except ValueError:
            payload = text
        return error.code, dict(error.headers), payload


def login(login_id, password):
    status, headers, payload = request("POST", "/users/login", body={"login_id": login_id, "password": password})
    if status != 200:
        sys.exit("login as %s failed: %s %s" % (login_id, status, payload))
    token = headers.get("Token") or headers.get("token")
    return token, payload


def must(result, what):
    status, _, payload = result
    if status >= 300:
        raise RuntimeError("%s failed: %s %s" % (what, status, payload))
    return payload


def mmctl(*args, json_out=True, check=True):
    cmd = ["docker", "compose", "--project-directory", DEV_SERVER, "-f", os.path.join(DEV_SERVER, "docker-compose.yml"),
           "--env-file", env_file(), "exec", "-T", "mattermost", "mmctl", "--local", "--suppress-warnings"]
    if json_out:
        cmd.append("--json")
    cmd += list(args)
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out = p.stdout.decode("utf-8", "replace")
    if check and p.returncode != 0:
        raise RuntimeError("mmctl %s failed: %s %s" % (" ".join(args), out, p.stderr.decode("utf-8", "replace")))
    if json_out:
        try:
            return json.loads(out) if out.strip() else None
        except ValueError:
            return out
    return out


def admin():
    env = read_env()
    token, _ = login(env["SEED_ADMIN_USERNAME"], env["SEED_ADMIN_PASSWORD"])
    return token, env


def username(i):
    return "%s%04d" % (PREFIX, i)


def channel_name(i):
    return "%s%04d-%s" % (CHANNEL_PREFIX, i, TOPICS[i % len(TOPICS)])


def channel_display(i):
    return "4B %04d %s" % (i, TOPICS[i % len(TOPICS)].capitalize())


def fill(rng, i):
    line = rng.choice(LINES)
    return line.format(topic=TOPICS[(i + rng.randint(0, 3)) % len(TOPICS)], n=rng.randint(10, 9999), m=rng.randint(100, 9999))


def build_import(args):
    rng = random.Random(4004)
    now = int(time.time() * 1000)
    lines = [{"type": "version", "version": 1}]
    lines.append({"type": "team", "team": {"name": TEAM, "display_name": TEAM_DISPLAY, "type": "O",
                                           "description": "Phase 4B large-server data (tools/mm-large-server.py)",
                                           "allow_open_invite": True}})
    members = {}  # channel index -> list of user indexes
    for c in range(1, args.channels + 1):
        lines.append({"type": "channel", "channel": {"team": TEAM, "name": channel_name(c), "display_name": channel_display(c),
                                                     "type": "O", "purpose": "Load channel %d (%s)" % (c, TOPICS[c % len(TOPICS)])}})
        extra = rng.sample(range(POSTERS + 1, args.users + 1), rng.randint(3, 15))
        members[c] = list(range(1, POSTERS + 1)) + extra
    by_user = {}
    for c, users in members.items():
        for u in users:
            by_user.setdefault(u, []).append(c)
    env = read_env()
    for u in range(1, args.users + 1):
        user = {"username": username(u), "email": "%s@example.com" % username(u),
                "first_name": FIRST[u % len(FIRST)], "last_name": LAST[(u // len(FIRST)) % len(LAST)],
                "position": rng.choice(["Engineer", "Designer", "PM", "Support", "SRE", ""]),
                "teams": [{"name": TEAM, "roles": "team_user",
                           "channels": [{"name": channel_name(c), "roles": "channel_user"} for c in by_user.get(u, [])]}]}
        if u <= POSTERS:
            user["password"] = env["SEED_USER_PASSWORD"]
        if u > args.active:
            user["delete_at"] = now - 86400000
        lines.append({"type": "user", "user": user})
    posts = []
    total = 0
    span = 60 * 86400000
    for c in range(1, args.channels + 1):
        if rng.random() < 0.1:
            n = rng.randint(100, 300)
        else:
            n = rng.randint(3, 40)
        t = now - span + rng.randint(0, span // 2)
        step = max(1000, (now - 3600000 - t) // (n + 1))
        for _ in range(n):
            t += rng.randint(step // 2, step * 3 // 2)
            t = min(t, now - 3600000 - rng.randint(0, 600000))
            post = {"team": TEAM, "channel": channel_name(c), "user": username(rng.choice(members[c])),
                    "message": fill(rng, c), "create_at": t}
            if rng.random() < 0.08:
                post["replies"] = [{"user": username(rng.choice(members[c])), "message": fill(rng, c),
                                    "create_at": t + (k + 1) * 30000} for k in range(rng.randint(1, 5))]
                total += len(post["replies"])
            posts.append((t, {"type": "post", "post": post}))
            total += 1
    posts.sort(key=lambda p: p[0])
    lines += [p[1] for p in posts]
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("import.jsonl", "\n".join(json.dumps(l, ensure_ascii=False) for l in lines) + "\n")
    return buf.getvalue(), len(lines), total


def run_import(data):
    os.makedirs(os.path.join(ROOT, "build-input"), exist_ok=True)
    path = os.path.join(ROOT, "build-input", "relay-4b-large-import.zip")
    with open(path, "wb") as f:
        f.write(data)
    dest = "/tmp/relay-4b-large-import.zip"
    subprocess.run(["docker", "compose", "--project-directory", DEV_SERVER, "-f", os.path.join(DEV_SERVER, "docker-compose.yml"),
                    "--env-file", env_file(), "cp", path, "mattermost:" + dest], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    job = mmctl("import", "process", "--bypass-upload", dest, "--extract-content=false")
    if isinstance(job, list):
        job = job[0]
    print("import job %s started" % job["id"])
    while True:
        time.sleep(3)
        j = mmctl("import", "job", "show", job["id"])
        if isinstance(j, list):
            j = j[0]
        status = j.get("status")
        if status == "success":
            print("import finished")
            return
        if status in ("error", "canceled"):
            raise RuntimeError("import failed: %s" % json.dumps(j.get("data"), ensure_ascii=False))
        print("  import %s (%s%%)" % (status, j.get("progress", 0)))


def team_id(token):
    status, _, payload = request("GET", "/teams/name/" + TEAM, token)
    return payload["id"] if status == 200 else None


def team_channels(token, tid):
    channels = []
    page = 0
    while True:
        batch = must(request("GET", "/teams/%s/channels?per_page=200&page=%d" % (tid, page), token), "channels")
        channels += batch
        if len(batch) < 200:
            break
        page += 1
    return sorted([c for c in channels if c["name"].startswith(CHANNEL_PREFIX)], key=lambda c: c["name"])


def user_by_name(token, name):
    return must(request("GET", "/users/username/" + name, token), "user " + name)


def cmd_seed(args):
    token, _ = admin()
    if team_id(token):
        print("team %s exists already; run purge first to rebuild it" % TEAM)
        return
    started = time.time()
    data, n_lines, n_posts = build_import(args)
    print("import: %d lines, %d posts, %d channels, %d users (%d active), %.1f MB" % (n_lines, n_posts, args.channels, args.users, min(args.active, args.users), len(data) / 1e6))
    run_import(data)
    print("seeded in %.0f s" % (time.time() - started))


def parallel(items, fn, workers=8):
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        return list(pool.map(fn, items))


def cmd_join(args):
    token, env = admin()
    tid = team_id(token)
    if not tid:
        sys.exit("no team %s; run seed first" % TEAM)
    member = user_by_name(token, args.member)
    must(request("POST", "/teams/%s/members" % tid, token, {"team_id": tid, "user_id": member["id"]}), "team join")
    channels = team_channels(token, tid)[: args.joined]
    started = time.time()

    def join(channel):
        status, _, payload = request("POST", "/channels/%s/members" % channel["id"], token, {"user_id": member["id"]})
        return status < 300
    ok = parallel(channels, join)
    print("%s joined %d/%d channels in %.1f s" % (args.member, sum(ok), len(channels), time.time() - started))
    # DMs and GMs with load users (as the member).
    member_token, _ = login(args.member, env["SEED_USER_PASSWORD"])
    rng = random.Random(4005)
    partners = [user_by_name(token, username(u)) for u in rng.sample(range(1, args.active + 1), args.dms + 2 * args.gms)]
    created = 0
    for p in partners[: args.dms]:
        channel = must(request("POST", "/channels/direct", member_token, [member["id"], p["id"]]), "DM")
        poster_token = None
        if p["username"] <= username(POSTERS):
            poster_token, _ = login(p["username"], env["SEED_USER_PASSWORD"])
        for k in range(rng.randint(2, 8)):
            who = poster_token if (poster_token and k % 2) else member_token
            must(request("POST", "/posts", who, {"channel_id": channel["id"], "message": "DM %d with %s" % (k + 1, p["username"])}), "DM post")
        created += 1
    rest = partners[args.dms:]
    for g in range(args.gms):
        ids = [member["id"], rest[2 * g]["id"], rest[2 * g + 1]["id"]]
        channel = must(request("POST", "/channels/group", member_token, ids), "GM")
        must(request("POST", "/posts", member_token, {"channel_id": channel["id"], "message": "GM %d hello" % (g + 1)}), "GM post")
        created += 1
    print("%d DMs/GMs with load users" % created)
    args.channels_list = channels
    cmd_mark_read(args)
    cmd_unread(args)


def cmd_mark_read(args):
    """The member reads every load channel (a member added by someone else starts with the whole history unread)."""
    token, env = admin()
    tid = team_id(token)
    channels = getattr(args, "channels_list", None) or team_channels(token, tid)[: args.joined]
    member_token, _ = login(args.member, env["SEED_USER_PASSWORD"])
    started = time.time()

    def view(channel):
        status, _, _ = request("POST", "/channels/members/me/view", member_token, {"channel_id": channel["id"]})
        return status < 300
    ok = parallel(channels, view)
    print("%s read %d/%d channels in %.1f s" % (args.member, sum(ok), len(channels), time.time() - started))


def cmd_unread(args):
    token, env = admin()
    tid = team_id(token)
    member = user_by_name(token, args.member)
    channels = getattr(args, "channels_list", None) or team_channels(token, tid)[: args.joined]
    rng = random.Random(int(time.time()))
    picked = rng.sample(channels, min(args.count, len(channels)))
    posters = [login(username(u), env["SEED_USER_PASSWORD"])[0] for u in range(1, POSTERS + 1)]
    started = time.time()

    def post(item):
        index, channel = item
        n = rng.randint(1, 4)
        for k in range(n):
            text = "Unread %d in %s" % (k + 1, channel["display_name"])
            if index % 5 == 0 and k == n - 1:
                text += " @%s please take a look" % args.member
            must(request("POST", "/posts", posters[(index + k) % POSTERS], {"channel_id": channel["id"], "message": text}), "post")
        return n
    counts = parallel(list(enumerate(picked)), post)
    print("%d unread posts in %d channels (%d with @%s) in %.1f s" % (sum(counts), len(picked), len(picked[::5]), args.member, time.time() - started))


def cmd_status(args):
    token, _ = admin()
    tid = team_id(token)
    print("limits:", json.dumps(must(request("GET", "/limits/server", token), "limits")))
    if not tid:
        print("no team %s" % TEAM)
        return
    stats = must(request("GET", "/teams/%s/stats" % tid, token), "team stats")
    channels = team_channels(token, tid)
    print("team %s: %d members (%d active), %d load channels" % (TEAM, stats["total_member_count"], stats["active_member_count"], len(channels)))
    member = user_by_name(token, args.member)
    status, _, team_member = request("GET", "/teams/%s/members/%s" % (tid, member["id"]), token)
    if status != 200 or team_member.get("delete_at", 0) != 0:
        print("%s: not in the team" % args.member)
        return
    ids = {c["id"] for c in channels}
    status, _, mine = request("GET", "/users/%s/teams/%s/channels/members?per_page=1000" % (member["id"], tid), token)
    print("%s: member of %d load channels" % (args.member, len([m for m in mine if m["channel_id"] in ids]) if status == 200 else 0))


def cmd_detach(args):
    token, env = admin()
    tid = team_id(token)
    member = user_by_name(token, args.member)
    if tid:
        status, _, payload = request("DELETE", "/teams/%s/members/%s" % (tid, member["id"]), token)
        print("%s left %s: %s" % (args.member, TEAM, status))
    # Hide DMs/GMs with load users (as the member), as closing them in a client does.
    member_token, _ = login(args.member, env["SEED_USER_PASSWORD"])
    channels = must(request("GET", "/users/me/channels", member_token), "channels")
    preferences = []
    for c in channels:
        if c["type"] == "D":
            other = [p for p in c["name"].split("__") if p != member["id"]]
            if other:
                status, _, user = request("GET", "/users/" + other[0], member_token)
                if status == 200 and user["username"].startswith(PREFIX):
                    preferences.append({"user_id": member["id"], "category": "direct_channel_show", "name": other[0], "value": "false"})
        elif c["type"] == "G":
            status, _, users = request("GET", "/channels/%s/members?per_page=20" % c["id"], member_token)
            ids = [m["user_id"] for m in users] if status == 200 else []
            names = [request("GET", "/users/" + i, member_token)[2]["username"] for i in ids if i != member["id"]]
            if names and all(n.startswith(PREFIX) for n in names):
                preferences.append({"user_id": member["id"], "category": "group_channel_show", "name": c["id"], "value": "false"})
    if preferences:
        must(request("PUT", "/users/%s/preferences" % member["id"], member_token, preferences), "preferences")
    print("hid %d DMs/GMs with load users" % len(preferences))


def cmd_purge(args):
    token, _ = admin()
    tid = team_id(token)
    if tid:
        print(mmctl("team", "delete", TEAM, "--confirm", json_out=False).strip())
    config = must(request("GET", "/config", token), "config")
    deletion = config["ServiceSettings"].get("EnableAPIUserDeletion")
    if not deletion:
        mmctl("config", "set", "ServiceSettings.EnableAPIUserDeletion", "true", json_out=False)
    names = []
    page = 0
    while True:
        batch = must(request("GET", "/users?per_page=200&page=%d&sort=" % page, token), "users")
        names += [u["username"] for u in batch if u["username"].startswith(PREFIX)]
        if len(batch) < 200:
            break
        page += 1
    for start in range(0, len(names), 100):
        mmctl("user", "delete", *names[start: start + 100], "--confirm", json_out=False, check=False)
    if not deletion:
        mmctl("config", "set", "ServiceSettings.EnableAPIUserDeletion", "false", json_out=False)
    print("deleted %d load users" % len(names))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["seed", "join", "mark-read", "unread", "status", "detach", "purge"])
    parser.add_argument("--channels", type=int, default=1000)
    parser.add_argument("--users", type=int, default=2000)
    parser.add_argument("--active", type=int, default=190)
    parser.add_argument("--member", default="alice")
    parser.add_argument("--joined", type=int, default=500)
    parser.add_argument("--dms", type=int, default=40)
    parser.add_argument("--gms", type=int, default=5)
    parser.add_argument("--count", type=int, default=150, help="unread: channels that get new posts")
    args = parser.parse_args()
    {"seed": cmd_seed, "join": cmd_join, "mark-read": cmd_mark_read, "unread": cmd_unread, "status": cmd_status, "detach": cmd_detach, "purge": cmd_purge}[args.command](args)


if __name__ == "__main__":
    main()
