#!/usr/bin/env python3
"""Seed the local mmdev Mattermost server with realistic test data.

Idempotent: every object is looked up by a natural key (username, team and
channel names, emoji names) or by a seed key recorded as a preference of the
seed admin (category "mmdev_seed"), so re-running never duplicates data. The
records live in the server's database, so ./reset.sh wipes them with the data.

Backdated history (firehose with 10k+ posts over two years, a 2013 batch,
per-channel and DM history) goes through the server's bulk import
(`mmctl import process --local`), because REST ignores create_at for regular
users. Everything that should happen "now" (threads, files, reactions,
mentions, edits, deletes, bot and webhook posts, read state) uses REST v4.

Usage:
  ./seed.py               seed (safe to re-run)
  ./seed.py --verify      only print the verification summary

See SEED.md for what gets created where. Standard library only.
"""

import argparse
import datetime as dt
import io
import json
import os
import random
import sys
import time
import zipfile

import mmassets as A
import mmlib
from mmlib import Api, ApiError

PREF_CAT = "mmdev_seed"
IMPORT_KEY = "import:v1"
CREDS_PATH = os.path.join(mmlib.STATE_DIR, "credentials.json")

# --------------------------------------------------------------------------
# People
# --------------------------------------------------------------------------

USERS = [
    dict(username="alice", first_name="Alice", last_name="Anderson", nickname="Al",
         position="iOS Engineer", picture=True),
    dict(username="bob", first_name="Bob", last_name="Brennan", nickname="",
         position="Backend Lead", picture=True),
    dict(username="carol", first_name="Carol", last_name="Núñez", nickname="CJ",
         position="Product Designer", picture=True),
    dict(username="dave", first_name="Dave", last_name="Okafor-Lindqvist", nickname="",
         position="Site Reliability Engineer", picture=False),
]
BOT = dict(username="buildbot", display_name="Build Bot",
           description="CI/CD notifications and interactive deploy approvals (seeded)")

TEAMS = [
    dict(name="engineering", display_name="Engineering", type="O",
         description="Engineering team: backend, iOS, infra.",
         members=["alice", "bob", "carol", "dave"], admins=["bob"]),
    dict(name="design", display_name="Design", type="I",
         description="Design team (invite only). bob is intentionally not a member.",
         members=["alice", "carol", "dave"], admins=["carol"]),
]

# Channel specs. `joined` join by themselves (system_join_channel), `added` are
# added by the creator (system_add_to_channel). `history` = number of backdated
# posts imported for that channel.
CHANNELS = [
    # ---- Engineering ----
    dict(team="engineering", name="town-square", default=True, history=30),
    dict(team="engineering", name="off-topic", default=True, history=25),
    dict(team="engineering", name="firehose", display="Firehose", type="O", creator="bob",
         joined=["alice", "carol"], added=["dave"],
         purpose="10k+ posts over two years plus a 2013 import. Scrolling, paging and hole-filling tests."),
    dict(team="engineering", name="backend", display="Backend", type="O", creator="bob",
         joined=["alice"], added=["carol", "dave"],
         header="Go services · on-call: @dave", purpose="Server-side discussion", history=25),
    dict(team="engineering", name="ios", display="iOS", type="O", creator="alice",
         added=["bob", "carol", "dave"],
         header="TestFlight: [internal builds](https://testflight.apple.com) · min iOS 16",
         purpose="iOS client", history=30),
    dict(team="engineering", name="android", display="Android", type="O", creator="bob",
         joined=["alice", "dave"], history=8),
    dict(team="engineering", name="releases", display="Releases", type="O", creator="bob",
         added=["alice", "carol", "dave"],
         purpose="Release announcements. Pinned: current notes and checklist.", history=15),
    dict(team="engineering", name="code-review", display="Code Review", type="O", creator="carol",
         added=["alice", "bob", "dave"], purpose="Markdown rendering test bed", history=12),
    dict(team="engineering", name="architecture", display="Architecture", type="O", creator="bob",
         added=["alice", "carol", "dave"], header="RFCs and ADRs. Long threads live here.", history=10),
    dict(team="engineering", name="incidents", display="Incidents", type="P", creator="dave",
         added=["alice", "bob"],
         header=":rotating_light: Sev1 bridge: https://meet.example.com/sev1 · [Runbook](https://example.com/runbooks/incident)",
         history=10),
    dict(team="engineering", name="leads", display="Leads", type="P", creator="bob",
         added=["alice"], purpose="Eng leads only", history=8),
    dict(team="engineering", name="security", display="Security", type="P", creator="bob",
         added=["dave"], purpose="alice is NOT a member (private channel visibility test)", history=6),
    dict(team="engineering", name="integrations", display="Integrations", type="O", creator="bob",
         added=["alice", "carol", "dave"],
         purpose="Bot and webhook posts: message attachments, buttons, menus"),
    dict(team="engineering", name="media", display="Media & Files", type="O", creator="carol",
         added=["alice", "bob", "dave"], purpose="File attachment test cases", history=5),
    dict(team="engineering", name="random-links", display="Links", type="O", creator="dave",
         joined=["alice", "bob", "carol"], purpose="Link and permalink previews", history=5),
    dict(team="engineering", name="on-call", display="On-call 📟", type="O", creator="dave",
         added=["alice", "bob"], history=12),
    dict(team="engineering", name="sandbox", display="Sandbox", type="O", creator="alice",
         added=["bob"], purpose="Scratch channel used by capture-fixtures.py"),
    dict(team="engineering", name="legacy-2019", display="Legacy (2019)", type="O", creator="bob",
         added=["alice", "dave"], purpose="Archived channel with 2019 history", legacy=True),
    # ---- Design ----
    dict(team="design", name="town-square", default=True, history=15),
    dict(team="design", name="off-topic", default=True, history=10),
    dict(team="design", name="ui-kit", display="UI Kit", type="O", creator="carol",
         added=["alice", "dave"], header="Figma: https://figma.example.com/ui-kit", history=12),
    dict(team="design", name="critiques", display="Critiques ✏️", type="O", creator="carol",
         added=["alice", "dave"], history=8),
    dict(team="design", name="research", display="User Research", type="O", creator="carol",
         added=["alice"], history=8),
    dict(team="design", name="design-systems", display="Design Systems", type="O", creator="carol",
         added=["alice", "dave"], history=6),
    dict(team="design", name="brand", display="Brand", type="P", creator="carol",
         added=["dave"], purpose="alice is NOT a member", history=5),
    dict(team="design", name="icons", display="Icons", type="O", creator="dave",
         added=["alice", "carol"], history=5),
    dict(team="design", name="motion", display="Motion", type="O", creator="carol",
         added=["alice"], history=5),
    dict(team="design", name="accessibility", display="Accessibility", type="O", creator="alice",
         added=["carol", "dave"], history=6),
    dict(team="design", name="copywriting", display="Copywriting", type="O", creator="carol",
         added=["alice"], history=4),
    dict(team="design", name="moodboard", display="Moodboard", type="O", creator="carol",
         added=["alice", "dave"], history=4),
    dict(team="design", name="design-ops", display="Design Ops", type="P", creator="carol",
         added=["alice"], history=4),
    dict(team="design", name="handoff", display="Handoff to Engineering", type="O", creator="alice",
         added=["carol"], history=4),
    dict(team="design", name="really-long-channel-name-for-truncation-tests",
         display="A really long display name to test truncation in the chat list",
         type="O", creator="carol", added=["alice"], history=3),
    dict(team="design", name="intl", display="Международный · 国際 · دولي 🌍", type="O", creator="carol",
         added=["alice", "dave"], purpose="Unicode, RTL and emoji rendering", history=4),
]

BOT_CHANNELS = ["engineering/integrations", "engineering/releases", "engineering/ios"]

DMS = {  # key -> members; history imported for each
    "dm:alice,bob": ["alice", "bob"],
    "dm:alice,carol": ["alice", "carol"],
    "dm:alice,dave": ["alice", "dave"],
    "dm:bob,carol": ["bob", "carol"],
    "dm:carol,dave": ["carol", "dave"],
    "gm:alice,bob,carol": ["alice", "bob", "carol"],
    "gm:alice,bob,carol,dave": ["alice", "bob", "carol", "dave"],
}
DM_HISTORY = {"dm:alice,bob": 60, "dm:alice,carol": 20, "dm:alice,dave": 10, "dm:bob,carol": 15,
              "dm:carol,dave": 8, "gm:alice,bob,carol": 20, "gm:alice,bob,carol,dave": 12}

SITE = "http://localhost:8065"  # replaced at runtime by MM_SITE_URL

# --------------------------------------------------------------------------
# Text corpora (deterministic generation)
# --------------------------------------------------------------------------

SERVICES = ["auth", "gateway", "push-proxy", "search", "files", "websocket", "sync", "notifications",
            "billing", "media-transcoder", "link-preview", "jobs"]
FILES = ["PostboxSync.swift", "MessageIdAllocator.swift", "ChatListController.swift", "WebSocketClient.swift",
         "api4/post.go", "app/channel.go", "store/sqlstore/thread_store.go", "Make.py", "BUILD.bazel",
         "AccountContext.swift", "HoleFiller.swift"]
TOPICS = ["message ID allocation", "hole filling", "offline mode", "the push proxy", "CRT in the chat list",
          "the custom emoji cache", "the new sync engine", "the Bazel remote cache", "Postbox schema migrations",
          "read receipts", "jump-to-permalink", "draft sync", "rate limiting"]
SNIPPETS = ["Date(timeIntervalSince1970: Double(createAt) / 1000)", "jq '.order | length'",
            "git bisect run make test", "xcrun simctl push booted", "SELECT count(*) FROM posts",
            "docker compose -p mmdev logs -f", "defer { lock.unlock() }"]
TEMPLATES = [
    "Deploying {svc} {ver} to staging", "{svc} {ver} is live in prod :rocket:",
    "anyone else seeing 502s from {svc}?", "error rate on {svc} is up {pct}% since the last deploy",
    "rolling back {svc} to {ver}", "PR {pr} is ready for review: refactor of {file}",
    "merged {pr}, thanks @{user}", "CI is red on main again, flaky test in {file}",
    "can someone review {pr}? it's small, I promise", "{ticket}: crash on launch when the keychain is locked",
    "{ticket} is fixed in {ver}", "standup in 5", "I'm out tomorrow, @{user} has my reviews",
    "p99 for {svc}: {ms}ms (was {ms2}ms last week)", "migrating {svc} to Postgres {pg} this weekend",
    "TIL: `{snippet}`", "the {svc} dashboard is lying, the real number is {n}",
    "load test: {n} req/s sustained, {pct}% errors", "who owns {svc} these days?",
    "pairing on {file} after lunch if anyone wants to join", "new Xcode beta breaks our build again :upside_down_face:",
    "bumped the Bazel cache to {n} GB", "simulator build takes {mins} min on the new runner, down from {mins2}",
    "we should write an ADR for {topic}", "{topic} RFC is up, comments welcome", "how do we feel about {topic}?",
    "Summary of today's blip:\n- {svc} ran out of DB connections\n- raised the pool to {n}\n- follow-up: {ticket}",
    "```swift\nlet id = MessageId(peerId: peer, namespace: 0, id: {n})\n```",
    "Reminder: {svc} certificates expire in {d} days", "anyone know why `{snippet}` is slow here?",
    "nice catch @{user}!", "+1 to what @{user} said", "**Heads up:** {svc} maintenance window tonight 22:00–23:00 UTC",
    "Filed {ticket} for {topic}", "I'll take {ticket}", "is {pr} still needed or can we close it?",
    "benchmarks for {topic}: {ms}ms → {ms2}ms", "the {svc} logs are full of `context deadline exceeded`",
    "today I learned that {svc} retries {n} times before giving up", "> {svc} is down\nit's not, the VPN is",
    "rebased {pr} onto main, CI running", "can we move the {topic} sync to Thursday?",
]
SHORT = ["ok", "+1", "lgtm", "on it", "thanks!", ":thumbsup:", "haha", "same here", "👀", "done", "ack",
         "makes sense", "nope", "yes!", "will do", "looking", "fixed", ":tada:", "🙏", "lol", "ship it",
         "agreed", "hmm", "brb", "nice", "+1 :100:"]
BURSTS = [["wait", "no", "it's the CDN", "not redis"], ["ok so", "the build", "is green", "finally :tada:"],
          ["brb", "coffee", "☕"], ["ship it", "ship it", "SHIP IT"], ["one sec", "pushing a fix", "done"],
          ["hmm", "that's weird", "can't repro", "nvm, can repro", "it's the cache again"],
          ["a", "b", "c", "d", "e", "f"]]
LEGACY_2013 = [
    "HipChat is down again", "anyone tried the iOS 7 beta yet?", "moving the build server to Jenkins today",
    "SVN → git migration done! please re-clone", "who broke the nightly?", "flat design is here to stay, apparently",
    "new MacBook Pros are in, grab one from IT", "the staging DB is full again", "lunch at the Thai place?",
    "Xcode 5 DP crashes when opening storyboards", "AFNetworking 2.0 looks nice", "standup moved to 10:15",
    "our Jenkins slave ran out of disk", "pushed the hotfix for the login crash", "+1", "ok", "thanks!",
    "who has the iPad mini for testing?", "TestFlight invites sent", "release 1.2 is in review",
]
REACTION_POOL = ["+1", "heart", "joy", "eyes", "tada", "rocket", "white_check_mark", "100", "fire",
                 "pray", "shipit", "lgtm"]
CHANNEL_LINES = {
    "town-square": ["Reminder: all-hands on Thursday", "Welcome to the team, everyone new this week!",
                    "Office closed Monday for the holiday", "Quarterly planning doc is up",
                    "Please fill in the offsite survey", "The coffee machine is fixed :coffee:"],
    "off-topic": ["anyone watching the F1 race?", "best pizza near the office?", "my cat says hi 🐈",
                  "board games on Friday?", "new Ghibli movie is out", "who left the cake in the fridge"],
    "backend": ["{svc} p99 looks good after the index change", "Upgraded to Go 1.25",
                "We need a migration for the threads table", "Rate limiter tests are flaky again"],
    "ios": ["Simulator build is green", "TestFlight build uploaded", "Crash in ChatListController on iOS 16",
            "Bazel cache hit rate is 92% today", "Who has an iPhone SE for testing?"],
    "android": ["Android is out of scope for Phase 0", "Kotlin multiplatform? maybe later"],
    "releases": ["Release {ver} is out :rocket:", "Release {ver} is in review", "Hotfix {ver} shipped"],
    "code-review": ["Please keep PRs under 400 lines", "{pr} needs a second reviewer"],
    "architecture": ["ADR-012: use Postbox as the single source of truth", "RFC on {topic} is up"],
    "incidents": ["SEV3: elevated 5xx on {svc}, resolved", "Postmortem for last week's outage is published"],
    "leads": ["1:1 notes template updated", "Hiring sync moved to Wednesday"],
    "security": ["Rotated the APNs key", "Pen test scheduled for next month"],
    "media": ["Screenshots from the design review", "Uploading the new icons later"],
    "random-links": ["https://developers.mattermost.com", "https://core.telegram.org/api"],
    "on-call": ["Handing over on-call to @{user}", "Quiet night, no pages", "Paged twice for {svc}"],
    "ui-kit": ["New color tokens are in Figma", "Dark mode palette v2", "Button states updated"],
    "critiques": ["Feedback round 2 is open", "Love the new empty states"],
    "research": ["Interview #4 notes uploaded", "Survey closes Friday"],
    "design-systems": ["Spacing scale updated", "Deprecated the old card component"],
    "brand": ["New logo concepts", "Brand guidelines v3"],
    "icons": ["Icon set 2.0 in progress", "24px grid for all icons"],
    "motion": ["Spring animations everywhere", "Reduce motion audit done"],
    "accessibility": ["VoiceOver labels audit", "Contrast check for dark mode"],
    "copywriting": ["Saved messages or Saved posts?", "Error message tone guide"],
    "moodboard": ["Warm palettes this round", "More whitespace please"],
    "design-ops": ["Figma seats renewal", "Design review cadence"],
    "handoff": ["Specs for onboarding are ready", "Redlines attached in Figma"],
    "really-long-channel-name-for-truncation-tests": ["Does this truncate?", "It should."],
    "intl": ["Привет!", "こんにちは", "مرحبا", "שלום", "你好"],
}
DM_LINES = ["hey!", "got a minute?", "sure", "can you look at my PR?", "lunch?", "thanks a lot :pray:",
            "sounds good", "running late, 5 min", "did you see the incident report?", "yes, scary",
            "let's sync tomorrow", "👍", "haha", "on my way", "sent you the doc", "perfect"]


def ms(y, mo, d, h=0, mi=0, s=0):
    return int(dt.datetime(y, mo, d, h, mi, s, tzinfo=dt.timezone.utc).timestamp() * 1000)


def fill(rng, tpl, user_pool):
    return tpl.format(
        svc=rng.choice(SERVICES), ver="v%d.%d.%d" % (rng.randint(1, 3), rng.randint(0, 12), rng.randint(0, 9)),
        pct=rng.randint(2, 40), pr="#%d" % rng.randint(800, 4800), file=rng.choice(FILES),
        user=rng.choice(user_pool), ticket="MM-%d" % rng.randint(10000, 66000), ms=rng.randint(40, 900),
        ms2=rng.randint(40, 900), pg=rng.choice([16, 17, 18]), snippet=rng.choice(SNIPPETS),
        n=rng.randint(2, 5000), mins=rng.randint(4, 20), mins2=rng.randint(20, 45), topic=rng.choice(TOPICS),
        d=rng.randint(2, 30))


# --------------------------------------------------------------------------
# Rich REST content
# --------------------------------------------------------------------------

MARKDOWN_POST = """# MattermostKit API review :memo:

## Goals
1. **Typed** models for every v4 endpoint we use
2. _Zero_ third-party dependencies
   - `Foundation` only
   - no ~~Alamofire~~, no ~~Starscream~~
3. Testable with recorded fixtures

### Endpoint coverage

| Area | Endpoint | Status |
|:-----|:---------|:------:|
| Auth | `POST /users/login` | :white_check_mark: |
| Channels | `GET /users/me/teams/{id}/channels` | :white_check_mark: |
| Posts | `GET /channels/{id}/posts` | :construction: |
| Threads | `GET /users/me/teams/{id}/threads` | :x: |

> **Note:** collapsed reply threads are `default_on` on the dev server,
> so the client must send `collapsedThreads=true`.
>
> > Nested quote: *really*.

```swift
struct Post: Decodable, Identifiable {
    let id: String
    let createAt: Int64   // milliseconds since 1970
    let message: String
    let rootId: String?

    enum CodingKeys: String, CodingKey {
        case id, message
        case createAt = "create_at"
        case rootId = "root_id"
    }
}
```

Links: [API docs](https://developers.mattermost.com/api-documentation/), https://github.com/mattermost/mattermost, ~architecture and @alice.

Inline: `URLSessionWebSocketTask`, **bold**, *italic*, ***both***, ~~strikethrough~~, emoji :tada: :rocket: :+1: :shipit: and a #hashtag.

- [x] task list item (done)
- [ ] task list item (open)

---
*Last updated by @carol*"""

CODE_POST = """Some snippets from today's review:

```json
{"id": "8w5f3nd8xjfm7c3w3o1h1u5eyc", "create_at": 1729936800000, "message": "hello"}
```

```bash
docker compose -p mmdev logs -f mattermost | grep -i websocket
```

```diff
- let timeout: TimeInterval = 10
+ let timeout: TimeInterval = 30
```

```go
func (a *App) GetPostsPage(opts model.GetPostsOptions) (*model.PostList, error) {
\treturn a.Srv().Store().Post().GetPosts(opts, false, map[string]bool{})
}
```

```
plain fenced block without a language
```"""

LATEX_POST = """Math rendering check. Inline: $E = mc^2$ and a block:

```latex
\\sum_{i=0}^{n} i = \\frac{n(n+1)}{2}
```"""

RELEASE_NOTES = """## Release 2.4.0 :tada:

### Highlights
- Collapsed reply threads in the chat list
- Custom emoji picker
- Cold start is **38% faster**

### Fixes
1. Crash when opening a permalink to a deleted post
2. Unread badge stuck after marking a thread as read
3. Images with EXIF rotation shown sideways

| Platform | Min version | Status |
|---|---|---|
| iOS | 16.0 | :white_check_mark: |
| iPadOS | 16.0 | :white_check_mark: |
| macOS (Catalyst) | n/a | :x: |

Full changelog: https://example.com/changelog/2.4.0"""

CHECKLIST = """Release checklist :clipboard: (pinned)
- [x] Freeze strings
- [x] Update App Store screenshots
- [ ] Smoke test on iPhone SE and iPad
- [ ] Submit for review"""


def long_post():
    parts = ["**Code review: `HoleFiller.swift` (long post, tests \"Show more\")**", ""]
    for i in range(1, 41):
        parts.append("%d. Line %d: consider extracting the paging cursor into a value type; the current "
                     "tuple `(before: String?, after: String?)` makes call sites hard to read and we keep "
                     "passing them in the wrong order. Also add a test for the empty-page case." % (i, i * 7))
    return "\n".join(parts)


def thread1_replies():
    """120 replies for the big RFC thread. alice participates early."""
    rng = random.Random(1201)
    lines = [
        "Option 2 (allocator with gaps) feels safest for permalinks.",
        "How do we handle two posts with the same create_at?",
        "Tie-break by post ID, lexicographically. They're sortable enough.",
        "What about imported history from 2013? IDs would be tiny.",
        "Start the allocator at 2^30 and grow both ways.",
        "Holes are Int32 ranges, so we must never reuse an ID.",
        "Can we persist the mapping in Postbox metadata?",
        "We need a property test with random interleavings.",
        "I'll prototype it in Spike C.",
        "Benchmarks: 10k posts mapped in 18 ms on an iPhone 12.",
        "Edits don't change create_at, so IDs stay stable. Good.",
        "Deleted posts keep their slot, right?",
        "Yes, tombstones keep the ID.",
        "What's our story for thread replies under CRT?",
        "Replies get IDs in the same space but are filtered from the main history.",
        "Let's write this down as ADR-014.",
    ]
    out = []
    users = ["bob", "carol", "dave", "alice"]
    alice_at = {2, 7, 14, 21, 29}
    for i in range(120):
        if i in alice_at:
            u = "alice"
        else:
            u = rng.choice(["bob", "carol", "dave"])
        msg = rng.choice(lines)
        if i == 90:
            msg = "@carol can you draw the allocator state machine? :pray:"
        if i == 110:
            msg = "Summary so far:\n- allocator with gaps\n- tie-break by post ID\n- ADR-014 to follow"
        out.append((u, "%s (#%d)" % (msg, i + 1)))
    del users
    return out


# --------------------------------------------------------------------------
# Seeder
# --------------------------------------------------------------------------

class Seeder:
    def __init__(self, env, base):
        global SITE
        self.env = env
        self.base = base
        SITE = env.get("MM_SITE_URL", base)
        self.admin = None
        self.users = {}
        self.apis = {}
        self.teams = {}
        self.channels = {}
        self.state = {}
        self.posts = {}
        self.creds = {}
        self.assets = {}
        self.t0 = time.time()

    # ---- logging / state ----

    def log(self, msg):
        print("[%6.1fs] %s" % (time.time() - self.t0, msg), flush=True)

    def load_state(self):
        try:
            prefs = self.admin.get("/users/%s/preferences/%s" % (self.admin_id, PREF_CAT)) or []
        except ApiError as e:
            if e.status != 404:
                raise
            prefs = []
        self.state = {p["name"]: p["value"] for p in prefs}
        for k, v in self.state.items():
            if k.startswith("p:"):
                self.posts[k[2:]] = v

    def mark(self, key, value="1"):
        assert len(key) <= 32, key
        self.admin.put("/users/%s/preferences" % self.admin_id,
                       [{"user_id": self.admin_id, "category": PREF_CAT, "name": key, "value": value}])
        self.state[key] = value

    def load_creds(self):
        if os.path.exists(CREDS_PATH):
            with open(CREDS_PATH) as f:
                self.creds = json.load(f)

    def save_creds(self):
        os.makedirs(mmlib.STATE_DIR, exist_ok=True)
        with open(CREDS_PATH, "w") as f:
            json.dump(self.creds, f, indent=2)
        os.chmod(CREDS_PATH, 0o600)

    # ---- assets (lazy, memoised) ----

    def asset(self, name):
        if name in self.assets:
            return self.assets[name]
        gen = {
            "sunset.png": lambda: ("image/png", A.png(1600, 1000, A.scene_landscape(1600, 1000, 11))),
            "portrait.jpg": lambda: ("image/jpeg", A.jpeg(600, 900, A.scene_landscape(600, 900, 12))),
            "lake.jpg": lambda: ("image/jpeg", A.jpeg(640, 480, A.scene_landscape(640, 480, 13))),
            "panorama.jpg": lambda: ("image/jpeg", A.jpeg(1200, 400, A.scene_landscape(1200, 400, 14))),
            "pattern.png": lambda: ("image/png", A.png(800, 800, A.scene_pattern(800, 800, 15))),
            "pattern-small.png": lambda: ("image/png", A.png(320, 200, A.scene_pattern(320, 200, 16))),
            "screenshot.png": lambda: ("image/png", A.png(390, 844, A.scene_screenshot(390, 844, 17))),
            "onboarding-1.png": lambda: ("image/png", A.png(390, 844, A.scene_screenshot(390, 844, 21))),
            "onboarding-2.png": lambda: ("image/png", A.png(390, 844, A.scene_screenshot(390, 844, 22))),
            "onboarding-3.png": lambda: ("image/png", A.png(390, 844, A.scene_screenshot(390, 844, 23))),
            "diagram.png": lambda: ("image/png", A.png(1024, 640, A.scene_pattern(1024, 640, 31))),
            "MattermostKit-spec.pdf": lambda: ("application/pdf", A.pdf("MattermostKit v0 spec", [
                ["1. Scope: REST v4 + WebSocket client in Swift, Foundation only.",
                 "2. Auth: password login, PAT, session token in Keychain.",
                 "3. Models: User, Team, Channel, ChannelMember, Post, PostList, Thread.",
                 "4. Paging: before/after cursors and since= for catch-up."],
                ["5. WebSocket: hello, posted, post_edited, post_deleted, typing, reactions.",
                 "6. Errors: AppError {id, message, status_code}.",
                 "7. Tests: recorded fixtures in infra/dev-server/fixtures."]])),
            "interviews.pdf": lambda: ("application/pdf", A.pdf("User interviews (5)", [
                ["P1: wants threads collapsed by default.", "P2: uses Saved messages as a todo list.",
                 "P3: misses chat folders.", "P4: wants faster cold start.", "P5: heavy emoji reactor."]])),
            "release-notes-2.4.0.txt": lambda: ("text/plain", RELEASE_NOTES.encode()),
            "crash.log": lambda: ("text/plain", ("\n".join(
                "Thread %d Crashed:\n0   Telegram  0x%012x ChatListController.update(_:) + %d" % (i, 0x100000 + i * 4096, i * 16)
                for i in range(40))).encode()),
            "notes.txt": lambda: ("text/plain", b"- rotate simulator certs\n- ask bob about 429s\n- read the CRT docs\n"),
            "handoff-checklist.txt": lambda: ("text/plain", b"[x] tokens exported\n[x] redlines\n[ ] motion specs\n"),
            "MessageIdAllocator.swift": lambda: ("text/plain", b"""import Foundation

/// Maps Mattermost post IDs to monotonic Int32 message IDs per peer.
final class MessageIdAllocator {
    private var next: Int32 = 1 << 30
    private var map: [String: Int32] = [:]

    func id(for postId: String) -> Int32 {
        if let id = map[postId] { return id }
        defer { next += 16 }
        map[postId] = next
        return next
    }
}
"""),
            "config.json": lambda: ("application/json", json.dumps(
                {"server": SITE, "collapsedThreads": True, "pageSize": 60}, indent=2).encode()),
            "logo.svg": lambda: ("image/svg+xml", A.svg_logo()),
            "voice-memo.wav": lambda: ("audio/wav", A.wav_tone(3.0)),
            "simulator-diagnostics.zip": lambda: ("application/zip", A.zip_blob(6 * 1024 * 1024)),
        }[name]
        mime, data = gen()
        self.assets[name] = (name, data, mime)
        return self.assets[name]

    # ---- bootstrap ----

    def bootstrap_admin(self):
        uname = self.env.get("SEED_ADMIN_USERNAME", "sysadmin")
        pw = self.env["SEED_ADMIN_PASSWORD"]
        try:
            self.admin = Api.login(self.base, uname, pw)
        except ApiError:
            found = mmlib.mmctl("user", "search", uname, check=False)
            exists = isinstance(found, (dict, list)) and bool(found)
            if not exists:
                self.log("creating system admin '%s' via mmctl --local" % uname)
                mmlib.mmctl("user", "create", "--email", "%s@example.com" % uname, "--username", uname,
                            "--password", pw, "--system-admin", "--email-verified",
                            "--firstname", "System", "--lastname", "Admin")
            else:
                self.log("resetting password of '%s' to the one in .env" % uname)
                mmlib.mmctl("user", "change-password", uname, "--password", pw)
                mmlib.mmctl("roles", "system-admin", uname, check=False)
            self.admin = Api.login(self.base, uname, pw)
        self.admin_id = self.admin.user["id"]
        if "system_admin" not in self.admin.user.get("roles", ""):
            mmlib.mmctl("roles", "system-admin", uname)
        self.users[uname] = self.admin.user
        self.apis[uname] = self.admin
        self.admin_name = uname

    def ensure_users(self):
        pw = self.env["SEED_USER_PASSWORD"]
        for spec in USERS:
            name = spec["username"]
            u = self.admin.get_or_none("/users/username/" + name)
            if not u:
                u = self.admin.post("/users", {
                    "username": name, "email": "%s@example.com" % name, "password": pw,
                    "first_name": spec["first_name"], "last_name": spec["last_name"],
                    "nickname": spec["nickname"], "position": spec["position"]})
                self.log("created user %s" % name)
            want = {k: spec[k] for k in ("first_name", "last_name", "nickname", "position")}
            if any(u.get(k, "") != v for k, v in want.items()):
                u = self.admin.put("/users/%s/patch" % u["id"], want)
            try:
                api = Api.login(self.base, name, pw)
            except ApiError:
                self.admin.put("/users/%s/password" % u["id"], {"new_password": pw})
                api = Api.login(self.base, name, pw)
            if spec["picture"] and not (u.get("last_picture_update") or 0) > 0:
                png = A.png(256, 256, A.avatar_identicon(name))
                self.admin.upload("/users/%s/image" % u["id"], {}, [("image", name + ".png", png, "image/png")])
            self.users[name] = u
            self.apis[name] = api

    def ensure_bot(self):
        b = BOT
        u = self.admin.get_or_none("/users/username/" + b["username"])
        if not u:
            bot = self.admin.post("/bots", {"username": b["username"], "display_name": b["display_name"],
                                            "description": b["description"]})
            u = self.admin.get("/users/" + bot["user_id"])
            self.log("created bot %s" % b["username"])
        uid = u["id"]
        if u.get("delete_at"):
            self.admin.post("/bots/%s/enable" % uid)
        if not (u.get("last_picture_update") or 0) > 0:
            png = A.png(256, 256, A.avatar_identicon("buildbot-robot"))
            self.admin.upload("/users/%s/image" % uid, {}, [("image", "buildbot.png", png, "image/png")])
        self.users[b["username"]] = u
        self.load_creds()
        token = self.creds.get("bot_token")
        ok = False
        if token:
            try:
                me = Api(self.base, token).get("/users/me")
                ok = me.get("id") == uid
            except ApiError:
                ok = False
        if not ok:
            t = self.admin.post("/users/%s/tokens" % uid, {"description": "mmdev seed token"})
            token = t["token"]
            self.creds.update({"bot_username": b["username"], "bot_user_id": uid,
                               "bot_token": token, "bot_token_id": t["id"]})
            self.save_creds()
            self.log("created bot access token (saved to .state/credentials.json)")
        api = Api(self.base, token, label=b["username"])
        api.user = u
        self.apis[b["username"]] = api

    def ensure_teams(self):
        for spec in TEAMS:
            t = self.admin.get_or_none("/teams/name/" + spec["name"])
            if not t:
                t = self.admin.post("/teams", {"name": spec["name"], "display_name": spec["display_name"],
                                               "type": spec["type"], "description": spec["description"]})
                self.log("created team %s" % spec["name"])
            self.teams[spec["name"]] = t
            members = self.admin.get("/teams/%s/members" % t["id"], query={"per_page": 200})
            have = {m["user_id"]: m for m in members}
            for name in spec["members"] + [BOT["username"]]:
                uid = self.users[name]["id"]
                if uid not in have:
                    m = self.admin.post("/teams/%s/members" % t["id"], {"team_id": t["id"], "user_id": uid})
                    have[uid] = m
            for name in spec["admins"]:
                uid = self.users[name]["id"]
                if "team_admin" not in (have[uid].get("roles") or "") and not have[uid].get("scheme_admin"):
                    self.admin.put("/teams/%s/members/%s/schemeRoles" % (t["id"], uid),
                                   {"scheme_admin": True, "scheme_user": True})

    def ensure_emoji(self):
        for name in ("shipit", "lgtm", "partyblob"):
            if self.admin.get_or_none("/emoji/name/" + name):
                continue
            png = A.png(128, 128, A.emoji_image(name), alpha=True)
            self.admin.upload("/emoji", {"emoji": json.dumps({"creator_id": self.admin_id, "name": name})},
                              [("image", name + ".png", png, "image/png")])
            self.log("created custom emoji :%s:" % name)

    def chan_members(self, spec):
        if spec.get("default"):
            team = next(t for t in TEAMS if t["name"] == spec["team"])
            return team["members"]
        return [spec["creator"]] + spec.get("joined", []) + spec.get("added", [])

    def ensure_channels(self):
        for spec in CHANNELS:
            key = "%s/%s" % (spec["team"], spec["name"])
            tid = self.teams[spec["team"]]["id"]
            ch = self.admin.get_or_none("/teams/%s/channels/name/%s" % (tid, spec["name"]),
                                        query={"include_deleted": "true"})
            if not ch and spec.get("default"):
                raise RuntimeError("default channel %s missing" % key)
            if not ch:
                ch = self.apis[spec["creator"]].post("/channels", {
                    "team_id": tid, "name": spec["name"], "display_name": spec["display"],
                    "type": spec["type"], "header": spec.get("header", ""), "purpose": spec.get("purpose", "")})
                self.log("created channel %s" % key)
            self.channels[key] = ch
            if ch.get("delete_at"):
                continue
            have = {m["user_id"] for m in self.admin.get("/channels/%s/members" % ch["id"],
                                                        query={"per_page": 200})}
            if spec.get("default"):
                for name in self.chan_members(spec):
                    if self.users[name]["id"] not in have:
                        self.admin.post("/channels/%s/members" % ch["id"], {"user_id": self.users[name]["id"]})
                continue
            for name in spec.get("joined", []):
                uid = self.users[name]["id"]
                if uid not in have:
                    self.apis[name].post("/channels/%s/members" % ch["id"], {"user_id": uid})
            for name in spec.get("added", []):
                uid = self.users[name]["id"]
                if uid not in have:
                    self.apis[spec["creator"]].post("/channels/%s/members" % ch["id"], {"user_id": uid})
        bot_id = self.users[BOT["username"]]["id"]
        for key in BOT_CHANNELS:
            ch = self.channels[key]
            if not self.admin.get_or_none("/channels/%s/members/%s" % (ch["id"], bot_id)):
                self.admin.post("/channels/%s/members" % ch["id"], {"user_id": bot_id})

    def ensure_dms(self):
        for key, members in DMS.items():
            ids = [self.users[m]["id"] for m in members]
            api = self.apis[members[0]]
            if len(ids) == 2:
                ch = api.post("/channels/direct", ids)
            else:
                ch = api.post("/channels/group", ids)
            self.channels[key] = ch
        a = self.users["alice"]["id"]
        self.channels["self:alice"] = self.apis["alice"].post("/channels/direct", [a, a])
        bot = self.apis[BOT["username"]]
        self.channels["dm:buildbot,alice"] = bot.post("/channels/direct", [bot.user["id"], a])

    def ensure_webhook(self):
        ch = self.channels["engineering/integrations"]
        hooks = self.admin.get("/hooks/incoming", query={"team_id": self.teams["engineering"]["id"],
                                                         "per_page": 200}) or []
        hook = next((h for h in hooks if h.get("display_name") == "CI notifications"), None)
        if not hook:
            hook = self.admin.post("/hooks/incoming", {
                "channel_id": ch["id"], "display_name": "CI notifications",
                "description": "Seeded incoming webhook (Slack-compatible payloads)",
                "username": "ci", "icon_url": SITE + "/static/images/favicon/android-chrome-192x192.png"})
            self.log("created incoming webhook")
        self.hook = hook
        self.creds["incoming_webhook_url"] = "%s/hooks/%s" % (SITE, hook["id"])
        self.save_creds()

    # ---- bulk import (backdated history) ----

    def build_import(self):
        rng = random.Random(20240601)
        posts = []  # (create_at, line)
        everyone = ["alice", "bob", "carol", "dave"]

        def P(team, channel, user, message, create_at, **extra):
            body = {"team": team, "channel": channel, "user": user, "message": message, "create_at": create_at}
            body.update(extra)
            posts.append((create_at, {"type": "post", "post": body}))

        def maybe_reactions(ts, author):
            if rng.random() >= 0.03:
                return {}
            out = []
            for emoji in rng.sample(REACTION_POOL, rng.randint(1, 3)):
                for u in rng.sample(everyone, rng.randint(1, 3)):
                    out.append({"user": u, "emoji_name": emoji, "create_at": ts + rng.randint(5000, 600000)})
            return {"reactions": out}

        # -- firehose: 2013 legacy batch (second precision, identical timestamps)
        fh = ("engineering", "firehose")
        legacy_users = ["bob", "carol", "dave", "alice", self.admin_name]
        t = ms(2013, 3, 4, 9, 30, 0)
        P(*fh, self.admin_name, "Welcome to the new chat server! History from the old HipChat room was imported "
          "(timestamps only have second precision).", t, is_pinned=True, flagged_by=["alice"])
        n2013 = 1
        end2013 = ms(2013, 6, 28, 18, 0, 0)
        gap = (end2013 - t) // 240
        while n2013 < 240:
            t += rng.randint(gap // 4, gap * 7 // 4)
            t = t // 1000 * 1000
            group = 1 if rng.random() < 0.8 else rng.randint(2, 4)
            for _ in range(group):
                P(*fh, rng.choice(legacy_users), rng.choice(LEGACY_2013), t)
                n2013 += 1

        # -- firehose: two years of chatter
        start = dt.date(2024, 11, 1)
        end = dt.date(2026, 10, 23)
        day = start
        n_recent = 0
        while day <= end:
            weekday = day.weekday() < 5
            n_conv = rng.randint(3, 5) if weekday else rng.randint(0, 2)
            for _ in range(n_conv):
                parts = rng.sample(everyone, rng.randint(2, 3))
                t = ms(day.year, day.month, day.day, rng.randint(7, 19), rng.randint(0, 59), rng.randint(0, 59))
                t += rng.randint(0, 999)
                length = rng.randint(1, 8)
                as_thread = rng.random() < 0.06 and length >= 3
                root = None
                for i in range(length):
                    t += rng.randint(3000, 240000)
                    user = rng.choice(parts)
                    if rng.random() < 0.04 and not as_thread:
                        sec = t // 1000 * 1000
                        burst = rng.choice(BURSTS)
                        offs = sorted(rng.sample(range(1000), len(burst)))
                        for word, off in zip(burst, offs):
                            P(*fh, user, word, sec + off)
                            n_recent += 1
                        t = sec + 999
                        continue
                    msg = fill(rng, rng.choice(TEMPLATES), [u for u in everyone if u != user]) \
                        if rng.random() < 0.7 else rng.choice(SHORT)
                    if as_thread and root is not None:
                        root["post"]["replies"].append({"user": user, "message": msg, "create_at": t})
                        n_recent += 1
                        continue
                    extra = maybe_reactions(t, user)
                    if as_thread:
                        extra["replies"] = []
                    P(*fh, user, msg, t, **extra)
                    n_recent += 1
                    if as_thread:
                        root = posts[-1][1]
            day += dt.timedelta(days=1)

        # one big imported thread and one pinned post deep in history
        t = ms(2025, 6, 12, 10, 0, 0)
        replies = []
        for i in range(60):
            t2 = t + (i + 1) * 45000 + i
            replies.append({"user": everyone[i % 4], "create_at": t2,
                            "message": "postmortem note %d: %s" % (i + 1, fill(rng, rng.choice(TEMPLATES), everyone))})
        P(*fh, "dave", "Postmortem thread for the June firehose outage :thread: (60 imported replies)", t,
          replies=replies, reactions=[{"user": "bob", "emoji_name": "shipit", "create_at": t + 1000}])
        n_recent += 61
        P(*fh, "bob", "On-call rotation doc lives at https://example.com/oncall (pinned, imported)",
          ms(2025, 2, 3, 9, 15, 0), is_pinned=True)
        n_recent += 1

        # -- per-channel backdated history
        hist_end = ms(2026, 10, 24, 18, 0, 0)
        for spec in CHANNELS:
            n = spec.get("history", 0)
            if spec["name"] == "firehose" or not n:
                continue
            members = [m for m in self.chan_members(spec)]
            lines = CHANNEL_LINES.get(spec["name"], []) + ["{x}"]
            t = hist_end - 60 * 86400000
            gap = 60 * 86400000 // (n + 1)
            for i in range(n):
                t += rng.randint(gap // 2, gap * 3 // 2)
                tpl = rng.choice(lines)
                msg = fill(rng, rng.choice(TEMPLATES), everyone) if tpl == "{x}" else \
                    fill(rng, tpl, [m for m in members])
                P(spec["team"], spec["name"], rng.choice(members), msg, min(t, hist_end - i))
        # legacy-2019 (archived later)
        t = ms(2019, 4, 1, 10, 0, 0)
        for i in range(40):
            t += rng.randint(1, 5) * 86400000 + rng.randint(0, 36000000)
            P("engineering", "legacy-2019", rng.choice(["alice", "bob", "dave"]),
              rng.choice(["Swift 5 is out!", "Migrating to Xcode 10.2", "Dark mode support?",
                          "SwiftUI announced, rewrite everything?", "Catalyst looks interesting",
                          "Moving CI to Bitrise", "Crash rate down to 0.1%", "%d tests green" % rng.randint(100, 900)]),
              t)

        lines = [{"type": "version", "version": 1}]
        posts.sort(key=lambda p: p[0])
        lines += [p[1] for p in posts]

        # -- DMs / GMs
        dposts = []
        for key, members in DMS.items():
            lines.append({"type": "direct_channel", "direct_channel": {"members": members}})
            n = DM_HISTORY[key]
            t = hist_end - 120 * 86400000
            for i in range(n):
                t += rng.randint(3600000, 4 * 86400000)
                dposts.append((min(t, hist_end), {"type": "direct_post", "direct_post": {
                    "channel_members": members, "user": rng.choice(members),
                    "message": rng.choice(DM_LINES) if rng.random() < 0.6 else fill(rng, rng.choice(TEMPLATES), members),
                    "create_at": min(t, hist_end) + i}}))
        dposts.sort(key=lambda p: p[0])
        lines += [p[1] for p in dposts]

        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            z.writestr("import.jsonl", "\n".join(json.dumps(l, ensure_ascii=False) for l in lines) + "\n")
        n_fire = n2013 + n_recent
        return buf.getvalue(), len(lines), n_fire, n2013

    def run_import(self):
        if self.state.get(IMPORT_KEY):
            self.log("bulk import already done (skipping)")
            return
        data, n_lines, n_fire, n2013 = self.build_import()
        os.makedirs(os.path.join(mmlib.STATE_DIR, "import"), exist_ok=True)
        path = os.path.join(mmlib.STATE_DIR, "import", "mmdev-seed-import.zip")
        with open(path, "wb") as f:
            f.write(data)
        self.log("bulk import: %d JSONL lines, firehose %d posts (%d from 2013), zip %.1f MB"
                 % (n_lines, n_fire, n2013, len(data) / 1e6))
        dest = "/tmp/mmdev-seed-import.zip"
        mmlib.compose_cp(path, dest)
        job = mmlib.mmctl("import", "process", "--bypass-upload", dest, "--extract-content=false")
        if isinstance(job, list):
            job = job[0]
        if not isinstance(job, dict) or "id" not in job:
            raise RuntimeError("unexpected mmctl import output: %r" % (job,))
        self.log("import job %s started" % job["id"])
        while True:
            time.sleep(3)
            j = mmlib.mmctl("import", "job", "show", job["id"])
            if isinstance(j, list):
                j = j[0]
            status = j.get("status")
            if status == "success":
                break
            if status in ("error", "canceled"):
                raise RuntimeError("import job failed: %s" % json.dumps(j.get("data"), ensure_ascii=False))
            self.log("  import %s (%s%%)" % (status, j.get("progress", 0)))
        self.log("bulk import finished")
        self.mark(IMPORT_KEY, job["id"])

    # ---- REST helpers ----

    def cid(self, chan):
        return self.channels[chan]["id"]

    def upload(self, user, chan, names):
        files = [("files",) + self.asset(n) for n in names]
        res = self.apis[user].upload("/files", {"channel_id": self.cid(chan)}, files)
        return [fi["id"] for fi in res["file_infos"]]

    def post(self, key, user, chan, message, root=None, files=None, props=None, priority=None):
        sk = "p:" + key
        if sk in self.state:
            self.posts[key] = self.state[sk]
            return self.posts[key]
        body = {"channel_id": self.cid(chan), "message": message}
        if root:
            body["root_id"] = self.posts[root]
        if files:
            body["file_ids"] = self.upload(user, chan, files)
        if props:
            body["props"] = props
        if priority:
            body["metadata"] = {"priority": {"priority": priority}}
        try:
            p = self.apis[user].post("/posts", body)
        except ApiError:
            if not priority:
                raise
            body.pop("metadata")
            p = self.apis[user].post("/posts", body)
        self.posts[key] = p["id"]
        self.mark(sk, p["id"])
        return p["id"]

    def react(self, key, emoji, users):
        sk = "r:%s:%s" % (key, emoji)
        if sk in self.state:
            return
        for u in users:
            self.apis[u].post("/reactions", {"user_id": self.users[u]["id"], "post_id": self.posts[key],
                                             "emoji_name": emoji})
        self.mark(sk)

    def once(self, key, fn):
        sk = "s:" + key
        if sk in self.state:
            return
        fn()
        self.mark(sk)

    # ---- content ----

    def seed_engineering(self):
        E = "engineering/"
        # town-square
        self.post("et-1", self.admin_name, E + "town-square",
                  "Welcome to **Engineering**! :wave: Announcements go here; release notes are pinned in ~releases.")
        self.post("et-2", "bob", E + "town-square",
                  "@channel Deploy freeze starts **Friday 17:00 UTC** for the 2.4 release. Land your PRs before then :lock:",
                  priority="important")
        self.post("et-3", "carol", E + "town-square", "Reminder: all-hands moved to Thursday :calendar:")
        self.post("et-4", "dave", E + "town-square",
                  "Status page is green again. Thanks to everyone who jumped on the push delay yesterday :pray:")
        self.react("et-2", "white_check_mark", ["alice", "carol", "dave"])
        # off-topic
        self.post("eo-1", "dave", E + "off-topic", ":coffee::coffee::coffee:")
        self.post("eo-2", "carol", E + "off-topic", "Who's up for board games on Friday? :game_die: We have Wingspan and Azul.")
        self.post("eo-3", "bob", E + "off-topic", "🎉")
        self.post("eo-4", "alice", E + "off-topic", "Count me in for Azul!")
        self.post("eo-5", "bob", E + "off-topic", "my cat walked over the keyboard during standup again 🐈‍⬛")
        self.react("eo-2", "partyblob", ["alice", "dave"])
        self.react("eo-5", "joy", ["carol", "alice"])
        # backend
        self.post("eb-1", "bob", E + "backend",
                  "Migrating `sessions` to the new index today at 14:00 UTC, expect a ~2 min blip on login.")
        self.post("eb-2", "dave", E + "backend",
                  "Heads-up: p99 for `GET /api/v4/channels/{id}/posts` went from 120 ms to 340 ms after the upgrade. Investigating.")
        self.post("eb-t2", "carol", E + "backend",
                  "Proposal: drop support for servers older than **10.11** in the mobile client. Thoughts? :thread:")
        self.post("eb-t2-1", "bob", E + "backend", "+1, WebSocket resume semantics changed in 10.x anyway.", root="eb-t2")
        self.post("eb-t2-2", "alice", E + "backend", "Agree. I'll check what our biggest customer runs.", root="eb-t2")
        self.post("eb-t2-3", "dave", E + "backend", "They've been on 11.7 ESR since September.", root="eb-t2")
        self.post("eb-t2-4", "carol", E + "backend", "Great, let's do it then.", root="eb-t2")
        self.once("backend-header", lambda: self.apis["bob"].put(
            "/channels/%s/patch" % self.cid(E + "backend"),
            {"header": "Go services · on-call: @dave · [Runbook](https://example.com/runbook) · SLOs: https://grafana.example.com/d/api"}))
        self.post("eb-3", "dave", E + "backend",
                  "@alice can you check whether the iOS client backs off on HTTP 429? We saw a retry storm from build 2.3.1.")
        self.post("eb-4", "bob", E + "backend", "Here's the limiter we use server-side:\n```go\n"
                  "limiter := rate.NewLimiter(rate.Every(100*time.Millisecond), 20)\nif !limiter.Allow() {\n"
                  "\treturn c.Err(http.StatusTooManyRequests)\n}\n```")
        # ios
        self.post("ei-1", "alice", E + "ios", "Simulator build is green on Xcode 26 :white_check_mark:")
        self.post("ei-2", "alice", E + "ios", "Minimum supported iOS is **16.0**. Rationale in ~architecture.")
        self.post("ei-3", "bob", E + "ios", "oops, wrong channel, ignore me")
        self.post("ei-t4", "bob", E + "ios",
                  "MattermostKit: should `Post.metadata` be decoded eagerly or lazily? Eager is simpler but costs ~15% on big pages.")
        self.post("ei-t4-1", "carol", E + "ios", "Lazily, if the API surface stays the same.", root="ei-t4")
        self.post("ei-t4-2", "dave", E + "ios", "Eager. Measure first: 15% of what?", root="ei-t4")
        self.post("ei-t4-3", "bob", E + "ios", "@alice could you weigh in? You wrote the decoder.", root="ei-t4")
        self.post("ei-t4-4", "dave", E + "ios", "Benchmarks are in the PR description.", root="ei-t4")
        self.once("ios-purpose", lambda: self.apis["alice"].put(
            "/channels/%s/patch" % self.cid(E + "ios"),
            {"purpose": "iOS client (Telegram-iOS fork): builds, TestFlight, crash triage"}))
        self.post("ei-4", BOT["username"], E + "ios", "TestFlight build **2.4.0 (1187)** is ready for internal testing.",
                  props={"attachments": [{"color": "#2AABEE", "title": "Build 1187", "fields": [
                      {"title": "Version", "value": "2.4.0", "short": True},
                      {"title": "Size", "value": "48.2 MB", "short": True}]}]})
        self.post("ei-5", "carol", E + "ios",
                  "@alice the new MattermostKit fixtures landed in `infra/dev-server/fixtures`, PTAL :eyes:")
        self.react("ei-1", "+1", ["bob"])
        # android: dave joined by himself; carol joins and leaves (system messages)
        self.post("ea-1", "dave", E + "android", "Android parity tracking moved to the board.")

        def carol_join_leave():
            cid = self.cid(E + "android")
            cu = self.users["carol"]["id"]
            self.apis["carol"].post("/channels/%s/members" % cid, {"user_id": cu})
            self.apis["carol"].delete("/channels/%s/members/%s" % (cid, cu))
        self.once("android-joinleave", carol_join_leave)
        self.post("ea-2", "bob", E + "android", "We're not doing Android in Phase 0, right?")
        self.post("ea-3", "dave", E + "android", "Correct, iOS only for now.")
        # releases
        self.post("er-1", "bob", E + "releases", RELEASE_NOTES)
        self.post("er-2", "carol", E + "releases", CHECKLIST)
        self.post("er-t3", "dave", E + "releases", "2.3.1 retro: what went wrong with the push delay? :thread:")
        self.post("er-t3-1", "bob", E + "releases", "Root cause: the proxy's APNs token expired.", root="er-t3")
        self.post("er-t3-2", "carol", E + "releases", "Can we alert on that?", root="er-t3")
        self.post("er-t3-3", "dave", E + "releases", "Added an alert, see ~incidents.", root="er-t3")
        self.post("er-3", BOT["username"], E + "releases", "Release **v2.4.0** tagged by @bob :label:")
        self.react("er-1", "tada", ["alice", "carol", "dave"])
        self.react("er-1", "rocket", ["dave"])
        self.react("er-1", "lgtm", ["carol"])
        self.react("er-1", "heart", ["alice"])
        # code-review (markdown)
        self.post("ec-1", "carol", E + "code-review", MARKDOWN_POST)
        self.post("ec-2", "bob", E + "code-review", long_post())
        self.post("ec-3", "dave", E + "code-review", CODE_POST)
        self.post("ec-4", "alice", E + "code-review",
                  "`URLSession` vs `NWConnection` for the WebSocket? I'd go with `URLSessionWebSocketTask`; "
                  "~~Starscream~~ is overkill. See [RFC 6455](https://datatracker.ietf.org/doc/html/rfc6455). #websocket #architecture")
        self.post("ec-5", "bob", E + "code-review", LATEX_POST)
        self.post("ec-t6", "alice", E + "code-review", "Should we enforce SwiftLint in CI? :thread:")
        self.post("ec-t6-1", "bob", E + "code-review", "Yes, but only on changed files.", root="ec-t6")
        self.post("ec-t6-2", "dave", E + "code-review", "+1, and warnings only for the first month.", root="ec-t6")
        self.post("ec-t6-3", "alice", E + "code-review", "Deal. I'll set it up.", root="ec-t6")
        # architecture: the big thread
        self.post("ear-t1", "bob", E + "architecture",
                  "**RFC: Message ID allocation for the Telegram-iOS fork** :thread:\n\n"
                  "Telegram wants `Int32` message IDs per peer, monotonic with time; Mattermost gives us 26-char IDs and "
                  "`create_at` in ms. Proposal: an allocator with gaps (option 2 in the plan). Reply here, this thread will get long.")
        t1 = thread1_replies()
        for i, (u, msg) in enumerate(t1):
            files = ["diagram.png"] if i == 64 else None
            self.post("ear-t1-%d" % i, u, E + "architecture", msg, root="ear-t1", files=files)
        self.once("t1-delete-reply", lambda: self.apis[t1[50][0]].delete("/posts/%s" % self.posts["ear-t1-50"]))
        self.post("ear-2", "carol", E + "architecture", "Diagram for the hole-filling flow", files=["diagram.png"])
        self.react("ear-t1", "+1", ["alice", "carol", "dave"])
        self.react("ear-t1", "shipit", ["bob", "dave"])
        self.react("ear-t1", "eyes", ["carol"])
        # incidents (private)
        self.post("ein-1", "dave", E + "incidents",
                  "**SEV2**: push notifications delayed up to 15 min for iOS. Bridge: https://meet.example.com/sev2 "
                  "@alice @bob please join.")
        self.post("ein-2", "bob", E + "incidents", "Joining.")
        self.post("ein-3", "dave", E + "incidents", "Mitigated at 14:32 UTC. Postmortem doc to follow.")
        # leads (private): dave added then removed by the admin -> system messages
        self.post("el-1", "bob", E + "leads", "Q4 headcount: one more iOS engineer approved.")

        def leads_add_remove():
            cid = self.cid(E + "leads")
            du = self.users["dave"]["id"]
            self.admin.post("/channels/%s/members" % cid, {"user_id": du})
            self.admin.delete("/channels/%s/members/%s" % (cid, du))
        self.once("leads-addremove", leads_add_remove)
        self.post("el-2", "alice", E + "leads", "Great news! I'll update the job post.")
        # security (alice not a member)
        self.post("es-1", "bob", E + "security", "Rotating the APNs auth key on Monday.")
        # media
        self.post("em-1", "carol", E + "media", "Sunset from the offsite :sunrise_over_mountains:", files=["sunset.png"])
        self.post("em-2", "dave", E + "media", "Portrait orientation test", files=["portrait.jpg"])
        self.post("em-3", "carol", E + "media", "Moodboard round 2: five options, vote with reactions :ballot_box:",
                  files=["pattern.png", "lake.jpg", "screenshot.png", "panorama.jpg", "pattern-small.png"])
        self.post("em-4", "bob", E + "media", "Spec for MattermostKit v0 :page_facing_up:", files=["MattermostKit-spec.pdf"])
        self.post("em-5", "dave", E + "media", "Release notes draft and last night's crash log",
                  files=["release-notes-2.4.0.txt", "crash.log"])
        self.post("em-6", "alice", E + "media", "Voice memo from the train :microphone:", files=["voice-memo.wav"])
        self.post("em-7", "bob", E + "media", "Simulator diagnostics (~6 MB, for download progress UI)",
                  files=["simulator-diagnostics.zip"])
        self.post("em-8", "carol", E + "media", "New logo concept (SVG)", files=["logo.svg"])
        self.post("em-9", "dave", E + "media", "Code + config attachments", files=["MessageIdAllocator.swift", "config.json"])
        self.post("em-10", "carol", E + "media", "Image plus document in one post", files=["lake.jpg", "MattermostKit-spec.pdf"])
        self.react("em-3", "heart_eyes", ["alice"])
        self.react("em-3", "fire", ["bob"])
        self.react("em-3", "partyblob", ["dave"])
        # random-links (link + permalink previews; display name change)
        self.post("erl-1", "dave", E + "random-links", "https://github.com/TelegramMessenger/Telegram-iOS")
        self.post("erl-2", "bob", E + "random-links", "Good read on CRDTs: https://crdt.tech/")
        self.post("erl-3", "carol", E + "random-links",
                  "[Mattermost API reference](https://developers.mattermost.com/api-documentation/)")
        self.post("erl-4", "alice", E + "random-links", "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        self.post("erl-5", "dave", E + "random-links",
                  "Inline image: ![Mattermost](%s/static/images/logo-email.png)" % SITE)
        self.post("erl-6", "bob", E + "random-links",
                  "Permalink preview: %s/engineering/pl/%s" % (SITE, self.posts["er-1"]))
        self.once("links-rename", lambda: self.apis["dave"].put(
            "/channels/%s/patch" % self.cid(E + "random-links"), {"display_name": "Random Links"}))
        self.react("erl-4", "laughing", ["bob", "carol"])
        # on-call
        self.post("eoc-1", "dave", E + "on-call", "Handing over on-call to @bob for the week.")
        self.post("eoc-2", "bob", E + "on-call", "Ack :saluting_face:")
        self.post("eoc-3", "dave", E + "on-call", "PagerDuty schedule updated.")
        # sandbox
        self.post("esb-1", "alice", E + "sandbox", "Scratch channel for `capture-fixtures.py`. Posts come and go here.")

    def seed_design(self):
        D = "design/"
        self.post("dt-1", "carol", D + "town-square", "Welcome to **Design** :art:")
        self.post("du-1", "carol", D + "ui-kit", "New button tokens are in Figma: primary, secondary, destructive.",
                  files=["screenshot.png"])
        self.post("du-2", "carol", D + "ui-kit",
                  "@alice can you double-check the dark-mode contrast on the destructive button?")
        self.post("du-3", "dave", D + "ui-kit", "Looks good on my side.")
        self.post("dc-t5", "carol", D + "critiques", "Feedback round 3: onboarding screens :thread:",
                  files=["onboarding-1.png", "onboarding-2.png", "onboarding-3.png"])
        self.post("dc-t5-1", "alice", D + "critiques", "Love the illustration on screen 2", root="dc-t5")
        self.post("dc-t5-2", "dave", D + "critiques", "Screen 3's CTA is below the fold on iPhone SE", root="dc-t5")
        self.post("dc-t5-3", "carol", D + "critiques", "Good catch, moving it up.", root="dc-t5")
        self.post("dc-t5-4", "alice", D + "critiques", "+1", root="dc-t5")
        self.react("dc-t5", "heart", ["alice", "dave"])
        self.post("dr-1", "carol", D + "research", "Interview notes from 5 users", files=["interviews.pdf"])
        self.post("dr-2", "alice", D + "research", "Thanks! Key takeaway: people want threads collapsed by default.")
        self.post("dds-1", "carol", D + "design-systems",
                  "Spacing scale:\n\n| Token | pt |\n|---|---:|\n| xs | 4 |\n| s | 8 |\n| m | 16 |\n| l | 24 |\n| xl | 32 |")
        self.post("db-1", "carol", D + "brand", "Logo concepts v4 (alice is not in this channel)")
        self.post("di-1", "dave", D + "icons", "Icon set 2.0 preview", files=["pattern-small.png"])
        self.post("dm-1", "carol", D + "motion", "Spring params: damping 0.8, response 0.35")
        self.post("da-1", "alice", D + "accessibility", "Dynamic Type audit: 14 screens left.")
        self.post("dcw-1", "carol", D + "copywriting", "Is it \"Saved messages\" or \"Saved posts\"?")
        self.post("dmb-1", "carol", D + "moodboard", "Warm palette options", files=["lake.jpg", "sunset.png"])
        self.post("ddo-1", "carol", D + "design-ops", "Figma seats renewal is next month.")
        self.post("dh-1", "alice", D + "handoff", "Handoff checklist for onboarding", files=["handoff-checklist.txt"])
        self.post("dl-1", "carol", D + "really-long-channel-name-for-truncation-tests", "Does this truncate nicely?")
        self.post("dx-1", "carol", D + "intl", "Привет! Как дела? 👋")
        self.post("dx-2", "dave", D + "intl", "こんにちは、元気ですか？ 日本語のテキストです。")
        self.post("dx-3", "alice", D + "intl", "مرحبا! هذا نص باللغة العربية من اليمين إلى اليسار.")
        self.post("dx-4", "carol", D + "intl", "שלום! טקסט בעברית with English mixed in.")
        self.post("dx-5", "dave", D + "intl",
                  "ZWJ & flags: 👩🏽‍💻 🧑‍🤝‍🧑 🏳️‍🌈 🇺🇦 🇯🇵 · combining: é ñ · zalgo: Z̤͔ͧ̑̓ä͖̭̈̇lͮ̒ͫǧ̗͚̚o̙̔ͮ̇͐̇")
        self.post("dx-6", "alice", D + "intl", "中文测试：你好，世界。")

    def seed_dms(self):
        ab = "dm:alice,bob"
        self.post("dab-1", "bob", ab, "hey, got a sec?")
        self.post("dab-2", "alice", ab, "sure, what's up?")
        self.post("dab-3", "bob", ab, "the fixture capture script: does it need my password?")
        self.post("dab-4", "alice", ab, "no, it reads `.env`, nothing to copy-paste")
        self.post("dab-5", "bob", ab, "perfect :+1:")
        self.react("dab-5", "joy", ["alice"])
        self.post("dab-6", "bob", ab, "look at this sunset from the office", files=["lake.jpg"])
        self.post("dab-7", "bob", ab, "also, lunch tomorrow?")
        self.post("dac-1", "carol", "dm:alice,carol", "Sent you the Figma link")
        self.post("dac-2", "alice", "dm:alice,carol", "Got it, thanks!")
        self.post("dad-1", "dave", "dm:alice,dave", "Can you cover on-call on Saturday?")
        self.post("dad-2", "alice", "dm:alice,dave", "Yes, no problem.")
        self.post("dbc-1", "bob", "dm:bob,carol", "Do you have the brand assets?")
        self.post("dbc-2", "carol", "dm:bob,carol", "They're in ~brand")
        self.post("das-1", "alice", "self:alice", "TODO: rotate simulator certs")
        self.post("das-2", "alice", "self:alice", "Read later: https://developers.mattermost.com/api-documentation/")
        self.post("das-3", "alice", "self:alice", "notes to self", files=["notes.txt"])
        g1 = "gm:alice,bob,carol"
        self.post("g1-1", "carol", g1, "Lunch at 12:30?")
        self.post("g1-2", "bob", g1, "Sure")
        self.post("g1-3", "carol", g1, "@alice you in?")
        g2 = "gm:alice,bob,carol,dave"
        self.post("g2-1", "dave", g2, "Team photo from the offsite :camera:", files=["sunset.png"])
        self.post("g2-2", "alice", g2, "Great photo!")
        self.post("bot-dm-1", BOT["username"], "dm:buildbot,alice",
                  "Your build **2.4.0 (1187)** finished :white_check_mark:",
                  props={"attachments": [{
                      "color": "#2EB67D", "title": "Build 1187 passed", "text": "All 1,204 tests passed in 12m 4s.",
                      "actions": [{"id": "rerun", "name": "Re-run", "type": "button", "style": "default",
                                   "integration": {"url": "http://localhost:9/mmdev/actions/rerun",
                                                   "context": {"build": 1187}}}]}]})

    def seed_integrations(self):
        ch = "engineering/integrations"
        bot = BOT["username"]
        action_url = "http://localhost:9/mmdev/actions/"   # deliberately points at nothing
        self.post("bi-1", bot, ch, "Deploy **2.4.0** to production?", props={"attachments": [{
            "fallback": "Deploy 2.4.0 to production?", "color": "#FFA500",
            "pretext": "Deployment approval required",
            "title": "Release 2.4.0", "title_link": "https://example.com/releases/2.4.0",
            "text": "Changes: 42 commits, 3 migrations. Approve within **30 minutes**.",
            "fields": [{"title": "Requested by", "value": "@bob", "short": True},
                       {"title": "Environment", "value": "production", "short": True}],
            "actions": [
                {"id": "approve", "name": "Approve", "type": "button", "style": "good",
                 "integration": {"url": action_url + "approve", "context": {"release": "2.4.0", "action": "approve"}}},
                {"id": "reject", "name": "Reject", "type": "button", "style": "danger",
                 "integration": {"url": action_url + "reject", "context": {"release": "2.4.0", "action": "reject"}}},
                {"id": "envselect", "name": "Pick environment", "type": "select",
                 "integration": {"url": action_url + "env", "context": {"release": "2.4.0"}},
                 "options": [{"text": "Staging", "value": "staging"}, {"text": "Production", "value": "production"},
                             {"text": "Canary (5%)", "value": "canary"}]},
                {"id": "reviewer", "name": "Assign reviewer", "type": "select", "data_source": "users",
                 "integration": {"url": action_url + "reviewer", "context": {"release": "2.4.0"}}},
            ],
            "footer": "buildbot", "footer_icon": SITE + "/static/images/favicon/favicon-default-64x64.png"}]})
        self.post("bi-2", bot, ch, "Which channel should get release notes?", props={"attachments": [{
            "text": "Pick a channel:",
            "actions": [{"id": "chan", "name": "Choose channel", "type": "select", "data_source": "channels",
                         "integration": {"url": action_url + "channel", "context": {}}}]}]})
        self.post("bi-3", bot, ch, "", props={"attachments": [{
            "fallback": "Nightly build report", "color": "#2AABEE",
            "author_name": "buildbot", "author_icon": SITE + "/static/images/favicon/favicon-default-64x64.png",
            "title": "Nightly build report", "text": "| Target | Result |\n|---|---|\n| iOS sim | :white_check_mark: |\n| iOS device | :x: |",
            "fields": [{"title": "Duration", "value": "38m", "short": True}, {"title": "Cache hit", "value": "91%", "short": True},
                       {"title": "Notes", "value": "Device build failed on code signing.", "short": False}],
            "image_url": SITE + "/static/images/logo-email.png"}]})
        payloads = [
            ("wh-1", {"text": "", "attachments": [{
                "fallback": "Build #4512 passed", "color": "#2EB67D", "author_name": "GitHub Actions",
                "title": "Build #4512 passed", "title_link": "https://example.com/ci/4512",
                "fields": [{"title": "Branch", "value": "main", "short": True},
                           {"title": "Commit", "value": "`a1b2c3d`", "short": True},
                           {"title": "Duration", "value": "12m 4s", "short": True},
                           {"title": "Tests", "value": "1,204 passed", "short": True}],
                "footer": "CI", "ts": int(time.time())}]}),
            ("wh-2", {"username": "ci", "attachments": [{
                "fallback": "Build #4513 failed", "color": "#E01E5A", "title": "Build #4513 failed",
                "text": "```\nFAIL: MessageIdAllocatorTests.testMonotonic\nXCTAssertLessThan failed: (\"1073741840\") is not less than (\"1073741824\")\n```",
                "thumb_url": SITE + "/static/images/favicon/android-chrome-192x192.png",
                "actions": [{"id": "retry", "name": "Retry", "type": "button",
                             "integration": {"url": action_url + "retry", "context": {"build": 4513}}}]}]}),
            ("wh-3", {"text": "Nightly backup completed: 12.4 GB in 3m 12s :floppy_disk:",
                      "username": "backup-cron", "icon_emoji": ":floppy_disk:"}),
        ]
        hook_api = Api(self.base)
        for key, payload in payloads:
            sk = "w:" + key
            if sk in self.state:
                continue
            hook_api.post("%s/hooks/%s" % (self.base, self.hook["id"]), payload)
            self.mark(sk)
        self.react("bi-1", "eyes", ["alice", "dave"])

    def seed_edits_pins_flags(self):
        # edited post
        target = "Simulator build is green on Xcode 26.1 :white_check_mark:"
        p = self.admin.get("/posts/%s" % self.posts["ei-1"])
        if p["message"] != target:
            self.apis["alice"].put("/posts/%s/patch" % self.posts["ei-1"], {"message": target})
        # deleted post
        self.once("ios-delete", lambda: self.apis["bob"].delete("/posts/%s" % self.posts["ei-3"]))
        # pins
        for key, user in (("er-1", "bob"), ("er-2", "carol"), ("ei-2", "alice"), ("ear-t1", "bob")):
            self.once("pin:" + key, lambda key=key, user=user: self.apis[user].post("/posts/%s/pin" % self.posts[key]))
        # saved (flagged) posts for alice
        aid = self.users["alice"]["id"]
        flagged = [self.posts[k] for k in ("er-1", "ear-t1", "em-3", "dad-1", "ec-1")]
        self.apis["alice"].put("/users/%s/preferences" % aid,
                               [{"user_id": aid, "category": "flagged_post", "name": pid, "value": "true"}
                                for pid in flagged])

    def archive(self):
        ch = self.channels["engineering/legacy-2019"]
        if not ch.get("delete_at"):
            self.apis["bob"].delete("/channels/%s" % ch["id"])
            self.log("archived ~legacy-2019")

    def seed_threads_follow(self):
        aid = self.users["alice"]["id"]
        tid = self.teams["engineering"]["id"]
        base = "/users/%s/teams/%s/threads/" % (aid, tid)
        a = self.apis["alice"]
        a.delete(base + self.posts["eb-t2"] + "/following")          # unfollowed thread
        a.put(base + self.posts["er-t3"] + "/following")              # explicitly followed
        self.post("er-t3-4", "bob", "engineering/releases",
                  "Follow-up: rotated keys now live in the secret store.", root="er-t3")
        self.post("er-t3-5", "carol", "engineering/releases", "Thanks, closing the retro.", root="er-t3")

    def seed_profile_state(self):
        # statuses and custom statuses
        for name, status in (("bob", "away"), ("carol", "dnd"), ("dave", "offline"), ("alice", "online")):
            uid = self.users[name]["id"]
            self.apis[name].put("/users/%s/status" % uid, {"user_id": uid, "status": status})
        self.apis["carol"].put("/users/%s/status/custom" % self.users["carol"]["id"],
                               {"emoji": "art", "text": "In design review"})
        self.apis["dave"].put("/users/%s/status/custom" % self.users["dave"]["id"],
                              {"emoji": "palm_tree", "text": "OOO until Monday"})
        a = self.apis["alice"]
        aid = self.users["alice"]["id"]
        tid = self.teams["engineering"]["id"]
        # mute off-topic
        a.put("/channels/%s/members/%s/notify_props" % (self.cid("engineering/off-topic"), aid),
              {"mark_unread": "mention"})
        # sidebar: custom category + favorites
        cats = a.get("/users/%s/teams/%s/channels/categories" % (aid, tid))
        by_name = {c["display_name"]: c for c in cats["categories"]}
        spike = [self.cid("engineering/" + n) for n in ("ios", "architecture", "backend")]
        if "Spike D" not in by_name:
            a.post("/users/%s/teams/%s/channels/categories" % (aid, tid),
                   {"user_id": aid, "team_id": tid, "display_name": "Spike D", "type": "custom", "channel_ids": spike})
            cats = a.get("/users/%s/teams/%s/channels/categories" % (aid, tid))
        fav = next(c for c in cats["categories"] if c["type"] == "favorites")
        want = [self.cid("engineering/releases"), self.cid("dm:alice,bob")]
        if set(want) - set(fav["channel_ids"]):
            fav["channel_ids"] = list(dict.fromkeys(want + fav["channel_ids"]))
            a.put("/users/%s/teams/%s/channels/categories/%s" % (aid, tid, fav["id"]), fav)
        # a server-side draft
        drafts = a.get_or_none("/users/%s/teams/%s/drafts" % (aid, tid)) or []
        if not any(d.get("channel_id") == self.cid("engineering/backend") for d in drafts):
            try:
                a.post("/drafts", {"user_id": aid, "channel_id": self.cid("engineering/backend"), "root_id": "",
                                   "message": "Re 429s: we back off exponentially with jitter, capped at 30 s, but"})
            except ApiError as e:
                self.log("note: drafts API unavailable (%s)" % e)

    # ---- alice's read state ----

    READ_PLAN = [
        ("engineering/town-square", "from", "et-2"),       # @channel mention
        ("engineering/off-topic", "from", "eo-5"),         # unread but muted
        ("engineering/firehose", "last", 25),
        ("engineering/backend", "from", "eb-3"),           # @alice mention
        ("engineering/ios", "from", "ei-4"),               # mention in ei-5
        ("engineering/android", "last", 2),
        ("engineering/releases", "read", None),
        ("engineering/code-review", "from", "ec-3"),
        ("engineering/architecture", "read", None),
        ("engineering/incidents", "from", "ein-1"),        # @alice mention (private)
        ("engineering/leads", "read", None),
        ("engineering/integrations", "last", 4),
        ("engineering/media", "last", 3),
        ("engineering/random-links", "read", None),
        ("engineering/on-call", "last", 3),
        ("engineering/sandbox", "read", None),
        ("engineering/legacy-2019", "read", None),
        ("design/town-square", "read", None),
        ("design/off-topic", "read", None),
        ("design/ui-kit", "from", "du-2"),                 # @alice mention
        ("design/critiques", "read", None),
        ("design/research", "read", None),
        ("design/design-systems", "last", 1),
        ("design/icons", "last", 1),
        ("design/motion", "read", None),
        ("design/accessibility", "read", None),
        ("design/copywriting", "last", 1),
        ("design/moodboard", "last", 1),
        ("design/design-ops", "read", None),
        ("design/handoff", "read", None),
        ("design/really-long-channel-name-for-truncation-tests", "last", 1),
        ("design/intl", "last", 3),
        ("dm:alice,bob", "from", "dab-6"),
        ("dm:alice,carol", "read", None),
        ("dm:alice,dave", "read", None),
        ("self:alice", "read", None),
        ("gm:alice,bob,carol", "from", "g1-3"),            # mention in a group message
        ("gm:alice,bob,carol,dave", "read", None),
        ("dm:buildbot,alice", "last", 1),
    ]

    def set_read_state(self):
        a = self.apis["alice"]
        aid = self.users["alice"]["id"]
        for chan, mode, arg in self.READ_PLAN:
            cid = self.cid(chan)
            try:
                if mode == "read":
                    a.post("/channels/members/%s/view" % aid,
                           {"channel_id": cid, "collapsed_threads_supported": True})
                    continue
                if mode == "from":
                    pid = self.posts[arg]
                else:
                    pl = a.get("/channels/%s/posts" % cid, query={"per_page": 60, "collapsedThreads": "true"})
                    order = [p for p in pl["order"] if not pl["posts"][p]["type"].startswith("system_")]
                    pid = order[min(arg, len(order)) - 1]
                a.post("/users/%s/posts/%s/set_unread" % (aid, pid), {"collapsed_threads_supported": True})
            except ApiError as e:
                self.log("warning: read state for %s: %s" % (chan, e))
        # threads (engineering): T1 unread from reply 100, T4 has an unread @mention, T3 unread follow-ups.
        tid = self.teams["engineering"]["id"]
        base = "/users/%s/teams/%s/threads/" % (aid, tid)
        a.post(base + "%s/set_unread/%s" % (self.posts["ear-t1"], self.posts["ear-t1-100"]))
        a.post(base + "%s/set_unread/%s" % (self.posts["ei-t4"], self.posts["ei-t4-3"]))
        a.post(base + "%s/set_unread/%s" % (self.posts["er-t3"], self.posts["er-t3-4"]))
        now = int(time.time() * 1000)
        a.put(base + "%s/read/%d" % (self.posts["ec-t6"], now))
        dtid = self.teams["design"]["id"]
        a.put("/users/%s/teams/%s/threads/%s/read/%d" % (aid, dtid, self.posts["dc-t5"], now))

    # ---- verification ----

    def verify(self):
        adm = self.admin
        out = {}
        out["ping"] = adm.get("/system/ping", query={"get_server_status": "true"}).get("status")
        out["server_version"] = adm.get("/config/client", query={"format": "old"}).get("Version")
        users = adm.get("/users", query={"per_page": 200})
        out["users"] = sorted(u["username"] for u in users if not u.get("is_bot"))
        out["bots"] = sorted(u["username"] for u in users if u.get("is_bot"))
        teams = adm.get("/teams", query={"per_page": 200})
        out["teams"] = sorted(t["name"] for t in teams)
        chans = adm.get("/channels", query={"per_page": 500, "include_deleted": "true",
                                            "exclude_default_channels": "false"})
        out["channels"] = {t["name"]: {
            "total": sum(c["team_id"] == t["id"] for c in chans),
            "public": sum(c["team_id"] == t["id"] and c["type"] == "O" for c in chans),
            "private": sum(c["team_id"] == t["id"] and c["type"] == "P" for c in chans),
            "archived": sum(c["team_id"] == t["id"] and bool(c["delete_at"]) for c in chans)} for t in teams}
        try:
            stats = {r["name"]: r["value"] for r in adm.get("/analytics/old", query={"name": "standard"})}
            out["server_totals"] = {k: stats.get(k) for k in ("channel_open_count",
                                                             "channel_private_count", "team_count",
                                                             "unique_user_count")}
        except ApiError:
            pass
        out["custom_emoji"] = sorted(e["name"] for e in adm.get("/emoji", query={"per_page": 200}))
        fh = adm.get("/teams/%s/channels/name/firehose" % self.teams["engineering"]["id"])
        count, user_posts, oldest, page = 0, 0, None, 0
        while True:
            pl = adm.get("/channels/%s/posts" % fh["id"], query={"page": page, "per_page": 200})
            if not pl["order"]:
                break
            for pid in pl["order"]:
                p = pl["posts"][pid]
                count += 1
                user_posts += not p["type"]
                oldest = p["create_at"] if oldest is None else min(oldest, p["create_at"])
            page += 1
        out["firehose"] = {"posts": count, "user_posts": user_posts,
                           "oldest": dt.datetime.fromtimestamp(oldest / 1000, dt.timezone.utc).isoformat(),
                           "total_msg_count": fh["total_msg_count"]}
        a = self.apis.get("alice")
        if a:
            unread = a.get("/users/me/teams/unread", query={"include_collapsed_threads": "true"})
            out["alice_unread_by_team"] = {self._team_name(u["team_id"]): {
                "msg_count": u["msg_count"], "mention_count": u["mention_count"],
                "thread_count": u.get("thread_count"),
                "thread_mention_count": u.get("thread_mention_count")} for u in unread}
            names = {u["id"]: u["username"] for u in users}
            rows = {}
            for t in teams:
                tch = {c["id"]: c for c in a.get("/users/me/teams/%s/channels" % t["id"],
                                                 query={"include_deleted": "true"})}
                for m in a.get("/users/me/teams/%s/channels/members" % t["id"], query={"per_page": 500}):
                    c = tch.get(m["channel_id"])
                    if not c:
                        continue
                    if c["type"] in "DG":
                        label = "%s:%s" % (c["type"], ",".join(sorted(
                            names.get(x, x) for x in c["name"].split("__") if x != a.user["id"]) or ["self"]))
                        if c["type"] == "G":
                            label = "G:" + c["display_name"].replace(" ", "")
                    else:
                        label = "%s/%s" % (t["name"], c["name"])
                    unread_root = c.get("total_msg_count_root", 0) - m.get("msg_count_root", 0)
                    if unread_root or m["mention_count"]:
                        rows[label] = "unread=%d mentions=%d" % (unread_root, m["mention_count_root"]
                                                                  if "mention_count_root" in m else m["mention_count"])
            out["alice_unread_channels"] = dict(sorted(rows.items()))
            out["alice_mention_channels"] = sorted(k for k, v in rows.items() if not v.endswith("mentions=0"))
            th = a.get("/users/me/teams/%s/threads" % self.teams["engineering"]["id"], query={"per_page": 50})
            out["alice_threads_engineering"] = {"followed": th.get("total"),
                                                "unread": th.get("total_unread_threads"),
                                                "unread_mentions": th.get("total_unread_mentions")}
        return out

    def _team_name(self, tid):
        return next((n for n, t in self.teams.items() if t["id"] == tid), tid)

    def logout_all(self):
        for name, api in self.apis.items():
            if name in (BOT["username"],) or api is self.admin:
                continue
            try:
                api.post("/users/logout")
            except ApiError:
                pass
        try:
            self.admin.post("/users/logout")
        except ApiError:
            pass

    # ---- main ----

    def run(self, verify_only=False):
        mmlib.wait_for_server(self.base)
        self.bootstrap_admin()
        self.load_state()
        if verify_only:
            for spec in TEAMS:
                self.teams[spec["name"]] = self.admin.get("/teams/name/" + spec["name"])
            self.apis["alice"] = Api.login(self.base, "alice", self.env["SEED_USER_PASSWORD"])
            print(json.dumps(self.verify(), indent=2, ensure_ascii=False))
            self.logout_all()
            return
        self.log("users");               self.ensure_users()
        self.log("bot");                 self.ensure_bot()
        self.log("teams");               self.ensure_teams()
        self.log("custom emoji");        self.ensure_emoji()
        self.log("channels");            self.ensure_channels()
        self.log("DMs / GMs");           self.ensure_dms()
        self.log("webhook");             self.ensure_webhook()
        self.log("bulk import");         self.run_import()
        self.log("engineering posts");   self.seed_engineering()
        self.log("design posts");        self.seed_design()
        self.log("DM posts");            self.seed_dms()
        self.log("bot + webhook posts"); self.seed_integrations()
        self.log("edits, deletes, pins, saved posts"); self.seed_edits_pins_flags()
        self.log("thread follow state"); self.seed_threads_follow()
        self.log("archive");             self.archive()
        self.log("statuses, sidebar, draft"); self.seed_profile_state()
        self.log("alice read state");    self.set_read_state()
        self.log("verify")
        print(json.dumps(self.verify(), indent=2, ensure_ascii=False))
        self.logout_all()
        self.log("done")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verify", action="store_true", help="only print the verification summary")
    args = ap.parse_args()
    env = mmlib.load_env()
    for k in ("SEED_ADMIN_PASSWORD", "SEED_USER_PASSWORD"):
        if not env.get(k) or env[k] == "change-me":
            sys.exit("error: %s is not set in .env" % k)
    Seeder(env, mmlib.base_url(env)).run(verify_only=args.verify)


if __name__ == "__main__":
    main()
