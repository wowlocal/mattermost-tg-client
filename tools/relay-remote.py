#!/usr/bin/env python3
"""Sends one command to a running debug build of Relay on a simulator (MattermostUI's debug remote,
docs/BUILD.md "Debug remote") and prints the result.

  tools/relay-remote.py <udid> state
  tools/relay-remote.py <udid> fill field=url text=http://localhost:8065
  tools/relay-remote.py <udid> press button=primary
  tools/relay-remote.py <udid> add-account
  tools/relay-remote.py <udid> switch username=bob
  tools/relay-remote.py <udid> logout username=alice
  tools/relay-remote.py <udid> relogin
  tools/relay-remote.py <udid> notifications                       # delivered notifications, newest first
  tools/relay-remote.py <udid> notification-open which=latest      # as a tap (which: latest, index, request id)
  tools/relay-remote.py <udid> notification-reply which=0 "text=On my way"
  tools/relay-remote.py <udid> notification-read which=0
  tools/relay-remote.py <udid> simulate-push file=<payload.apns> delay=3   # the extension's code, in the app

The command goes to <app data container>/Documents/relay-debug/command.json; the Darwin notification
org.relaychat.Relay.debug tells the app to run it; the app answers in relay-debug/result.json.
"""
import json
import os
import subprocess
import sys
import time
import uuid

BUNDLE_ID = "org.relaychat.Relay"


def main(argv):
    if len(argv) < 3:
        sys.exit(__doc__)
    udid, action = argv[1], argv[2]
    command = {"action": action, "id": uuid.uuid4().hex}
    for pair in argv[3:]:
        key, _, value = pair.partition("=")
        command[key] = value
    container = subprocess.check_output(["xcrun", "simctl", "get_app_container", udid, BUNDLE_ID, "data"], text=True).strip()
    directory = os.path.join(container, "Documents", "relay-debug")
    os.makedirs(directory, exist_ok=True)
    result_path = os.path.join(directory, "result.json")
    with open(os.path.join(directory, "command.json"), "w") as f:
        json.dump(command, f)
    subprocess.check_call(["xcrun", "simctl", "spawn", udid, "notifyutil", "-p", "org.relaychat.Relay.debug"])
    timeout = float(os.environ.get("RELAY_REMOTE_TIMEOUT", "15"))
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(result_path) as f:
                result = json.load(f)
            if result.get("id") == command["id"]:
                print(json.dumps(result, indent=2, sort_keys=True))
                sys.exit(0 if result.get("ok") else 1)
        except (OSError, ValueError):
            pass
        time.sleep(0.2)
    sys.exit("no result within %.0f s (is a debug build running? RELAY_REMOTE_TIMEOUT sets the wait)" % timeout)


if __name__ == "__main__":
    main(sys.argv)
