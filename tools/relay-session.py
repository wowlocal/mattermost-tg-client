#!/usr/bin/env python3
"""A scripted Relay session on a simulator for runtime checks (Phase 4B): drives the main flows through the
debug remote (tools/relay-remote.py) in a loop and samples the app's memory and the requests parked by the
null network engine once a minute.

  tools/relay-session.py <udid> [--minutes 10] [--out session.jsonl] [--no-background]

Each cycle: chat list → firehose (scroll to top and back, profile) → town square (thread) → DM with bob
(profile) → Saved Messages → sandbox (a draft with a link, not sent) → search → Settings rows and screens (status, Data and Storage,
Privacy, Notifications, Appearance) → threads list → background/foreground (Settings app, then Relay).

Samples (one JSON line each): wall time, the app's phys_footprint and resident size from inside the app (the
debug remote's `runtime`), `footprint` from the host when available, and the parked-request totals. The last
line is the final `runtime` report with every parked function.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REMOTE = os.path.join(HERE, "relay-remote.py")
BUNDLE_ID = "org.relaychat.Relay"


def remote(udid, action, **args):
    cmd = [sys.executable, REMOTE, udid, action] + ["%s=%s" % (k, v) for k, v in args.items()]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=40)
    try:
        return json.loads(p.stdout)
    except ValueError:
        return {"ok": False, "error": (p.stderr or p.stdout).strip()[-200:]}


def app_pid(udid):
    p = subprocess.run(["pgrep", "-f", "%s/.*/Telegram.app/Telegram$" % udid], stdout=subprocess.PIPE, text=True)
    pids = [int(x) for x in p.stdout.split()]
    return pids[0] if pids else None


def host_footprint(pid):
    if not pid:
        return None
    p = subprocess.run(["footprint", str(pid)], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    match = re.search(r"Footprint:\s*([\d.]+)\s*([KMG]B)", p.stdout)
    if not match:
        return None
    value, unit = float(match.group(1)), match.group(2)
    return value * {"KB": 1 / 1024.0, "MB": 1.0, "GB": 1024.0}[unit]


def sample(udid, started, label):
    report = remote(udid, "runtime").get("extra", {})
    memory = report.get("memory", {})
    pid = app_pid(udid)
    line = {
        "t": round(time.time() - started, 1),
        "label": label,
        "pid": pid,
        "footprintMB": round(memory.get("physFootprintMB", 0), 1),
        "residentMB": round(memory.get("residentMB", 0), 1),
        "hostFootprintMB": host_footprint(pid),
        "parkedKinds": report.get("parkedKinds"),
        "parkedTotal": report.get("parkedTotal"),
        "parkedLive": report.get("parkedLive"),
    }
    return line, report


STEPS = [
    ("chats-tab", {}),
    ("chat", {"query": "firehose"}), ("scroll", {"to": "top"}), ("scroll", {"to": "bottom"}), ("peerinfo", {}), ("back", {}), ("back", {}),
    ("chat", {"query": "engineering/town-square"}), ("replies", {"index": "0"}), ("back", {}), ("back", {}),
    ("chat", {"query": "dm:bob"}), ("peerinfo", {}), ("back", {}), ("back", {}),
    ("chat", {"query": "saved"}), ("back", {}),
    ("chat", {"query": "sandbox"}), ("compose", {"text": "4B session draft https://example.com/4b", "focus": "0"}), ("compose", {"text": "", "focus": "0"}), ("back", {}),
    ("search", {"query": "deploy"}), ("search-cancel", {}),
    ("settings-row", {"row": "status"}), ("chats-tab", {}),
    ("screen", {"name": "data"}), ("screen", {"name": "privacy"}), ("screen", {"name": "notifications"}), ("screen", {"name": "appearance"}),
    ("chats-tab", {}),
    ("threads", {}), ("back", {}),
]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("udid")
    parser.add_argument("--minutes", type=float, default=10.0)
    parser.add_argument("--out")
    parser.add_argument("--no-background", action="store_true")
    args = parser.parse_args()
    out = open(args.out, "w") if args.out else None

    def emit(line):
        text = json.dumps(line, sort_keys=True)
        print(text, flush=True)
        if out:
            out.write(text + "\n")
            out.flush()

    started = time.time()
    deadline = started + args.minutes * 60
    next_sample = started
    cycle = 0
    failures = {}
    while time.time() < deadline:
        cycle += 1
        for action, params in STEPS:
            if time.time() >= next_sample:
                line, _ = sample(args.udid, started, "cycle %d" % cycle)
                emit(line)
                next_sample += 60
            if time.time() >= deadline:
                break
            result = remote(args.udid, action, **params)
            if not result.get("ok"):
                key = "%s %s" % (action, json.dumps(params, sort_keys=True))
                failures[key] = failures.get(key, 0) + 1
        if not args.no_background and time.time() < deadline:
            subprocess.run(["xcrun", "simctl", "launch", args.udid, "com.apple.Preferences"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(5)
            subprocess.run(["xcrun", "simctl", "launch", args.udid, BUNDLE_ID], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            time.sleep(3)
    line, report = sample(args.udid, started, "end after %d cycles" % cycle)
    emit(line)
    emit({"final": report.get("parked", []), "failures": failures, "cycles": cycle})


if __name__ == "__main__":
    main()
