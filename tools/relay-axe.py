#!/usr/bin/env python3
"""Real taps and typing on a simulator through AXe, addressed by accessibility label (Phase 4E).

Release builds have no debug remote (tools/relay-remote.py), so the regression checklist
(docs/release/REGRESSION.md) drives them like a person would: find an element by its VoiceOver label,
touch its centre, type with the hardware keyboard. Works on any device size, because coordinates come from
the accessibility tree, not from a table.

AXe is the binary bundled in XcodeBuildMCP's npm package (`npm pack xcodebuildmcp@2.7.0`, `package/bundled/axe`
next to its `Frameworks/`). Point AXE at it, or put it on PATH.

  tools/relay-axe.py <udid> tree                       # every labelled element: type, label, [value], frame
  tools/relay-axe.py <udid> find "Log In"              # elements whose label contains the text (--exact)
  tools/relay-axe.py <udid> tap "Log In"               # touch the first match's centre (--index N, --exact,
                                                       #   --value TEXT, --type Button, --hold SECONDS,
                                                       #   --below Y / --above Y: centre in that band)
  tools/relay-axe.py <udid> tap-xy 201 437             # touch a point (screen points)
  tools/relay-axe.py <udid> type "text"                # type into the focused field (--env NAME: text from
                                                       #   an environment variable, so passwords stay off the
                                                       #   command line and out of the output)
  tools/relay-axe.py <udid> key return                 # return, delete, tab, escape
  tools/relay-axe.py <udid> clear                      # empty the focused field (--count N: up to N characters each side of the cursor)
  tools/relay-axe.py <udid> wait "Chats" --timeout 20  # until an element with that label is on screen
  tools/relay-axe.py <udid> gone "Connecting" --timeout 30
  tools/relay-axe.py <udid> swipe 200 700 200 200      # x1 y1 x2 y2 (--duration S)
  tools/relay-axe.py <udid> shot out.png [--width 1000]
  tools/relay-axe.py <udid> ocr                        # text on screen (Vision OCR of a screenshot), with frames
  tools/relay-axe.py <udid> tap-text "OK"              # touch recognized text (--index N, --exact, --below Y,
                                                       #   --above Y: only text in that band of the screen)
  tools/relay-axe.py <udid> wait-text "Chats" --timeout 20 / gone-text "Connecting"

Labels match case-insensitively. AXe's tree misses Telegram's alerts, action sheets, tab bar and some bar
buttons; the `*-text` commands find those by their text instead (tools/relay-ocr.swift, compiled once into
build-input/relay-ocr). Exit status 1 when an element is not found.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import time

KEYCODES = {"return": 40, "escape": 41, "delete": 42, "tab": 43, "space": 44}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OCR_SOURCE = os.path.join(ROOT, "tools", "relay-ocr.swift")
OCR_BINARY = os.path.join(ROOT, "build-input", "relay-ocr")


def axe_path():
    path = os.environ.get("AXE") or shutil.which("axe")
    if not path:
        sys.exit("error: AXe not found; set AXE=/path/to/axe (XcodeBuildMCP's bundled/axe)")
    return path


def axe(*args, capture=True):
    cmd = [axe_path()] + [str(a) for a in args]
    p = subprocess.run(cmd, stdout=subprocess.PIPE if capture else None, stderr=subprocess.PIPE)
    if p.returncode != 0:
        sys.exit("error: %s failed: %s" % (" ".join(cmd[:3]), p.stderr.decode("utf-8", "replace").strip()))
    return p.stdout.decode("utf-8", "replace") if capture else ""


def elements(udid):
    raw = axe("describe-ui", "--udid", udid)
    start = raw.find("[")
    tree = json.loads(raw[start:]) if start >= 0 else []
    out = []

    def walk(node):
        frame = node.get("frame") or {}
        label = node.get("AXLabel")
        value = node.get("AXValue")
        if label or value:
            out.append({
                "type": node.get("type") or node.get("role") or "",
                "label": label or "",
                "value": "" if value is None else str(value),
                "x": float(frame.get("x", 0)), "y": float(frame.get("y", 0)),
                "w": float(frame.get("width", 0)), "h": float(frame.get("height", 0)),
                "enabled": node.get("enabled", True),
            })
        for child in node.get("children") or []:
            walk(child)

    for node in tree:
        walk(node)
    return out


def matches(udid, args):
    text = args.label.lower()
    found = []
    all_elements = elements(udid)
    screen = next((e for e in all_elements if e["type"] == "Application"), None)
    for e in all_elements:
        if screen is not None and e is not screen:
            cx, cy = e["x"] + e["w"] / 2, e["y"] + e["h"] / 2
            if not (0 <= cx <= screen["w"] and 0 <= cy <= screen["h"]):
                continue  # scrolled off screen: a touch there would hit something else

        label = e["label"].lower()
        if args.exact and label != text:
            continue
        if not args.exact and text not in label:
            continue
        if getattr(args, "value", None) and args.value.lower() not in e["value"].lower():
            continue
        if getattr(args, "type", None) and e["type"].lower() != args.type.lower():
            continue
        if getattr(args, "below", None) is not None and e["y"] + e["h"] / 2 < args.below:
            continue  # e.g. under the navigation bar, which takes the touch
        if getattr(args, "above", None) is not None and e["y"] + e["h"] / 2 > args.above:
            continue
        if e["w"] <= 0 or e["h"] <= 0:
            continue
        found.append(e)
    return found


def ocr_binary():
    if not os.path.exists(OCR_BINARY) or os.path.getmtime(OCR_BINARY) < os.path.getmtime(OCR_SOURCE):
        os.makedirs(os.path.dirname(OCR_BINARY), exist_ok=True)
        subprocess.run(["xcrun", "swiftc", "-O", "-o", OCR_BINARY, OCR_SOURCE], check=True,
                       stdout=subprocess.DEVNULL)
    return OCR_BINARY


def screen_text(udid):
    """Recognized text on the screen, frames in points."""
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        png = os.path.join(tmp, "screen.png")
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", png], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        width_px = int(subprocess.check_output(["sips", "-g", "pixelWidth", png], text=True).split()[-1])
        raw = axe("describe-ui", "--udid", udid)
        start = raw.find("[")
        tree = json.loads(raw[start:]) if start >= 0 else []
        width_pt = float(((tree[0] if tree else {}).get("frame") or {}).get("width") or 0) or width_px / 3.0
        out = subprocess.check_output([ocr_binary(), png, str(width_px / width_pt)])
    return [{"type": "Text", "label": t["text"], "value": "", "x": t["x"], "y": t["y"], "w": t["w"], "h": t["h"],
             "enabled": True} for t in json.loads(out)]


def text_matches(udid, args):
    text = args.label.lower()
    found = []
    for e in screen_text(udid):
        label = e["label"].lower()
        if (label != text) if args.exact else (text not in label):
            continue
        if args.below is not None and e["y"] < args.below:
            continue
        if args.above is not None and e["y"] > args.above:
            continue
        found.append(e)
    return found


def describe(e):
    value = (" [%s]" % e["value"].replace("\n", "\\n")[:60]) if e["value"] else ""
    return '%s "%s"%s @%d,%d %dx%d' % (e["type"], e["label"].replace("\n", "\\n")[:90], value,
                                       e["x"], e["y"], e["w"], e["h"])


def touch(udid, x, y, hold=0.15):
    axe("touch", "-x", "%.1f" % x, "-y", "%.1f" % y, "--down", "--up", "--delay", str(hold), "--udid", udid)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("udid")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("tree")
    for name in ("find", "tap", "wait", "gone"):
        p = sub.add_parser(name)
        p.add_argument("label")
        p.add_argument("--exact", action="store_true")
        p.add_argument("--value")
        p.add_argument("--type")
        p.add_argument("--below", type=float)
        p.add_argument("--above", type=float)
        p.add_argument("--index", type=int, default=0)
        p.add_argument("--hold", type=float, default=0.15)
        p.add_argument("--timeout", type=float, default=15.0)
    for name in ("tap-text", "wait-text", "gone-text"):
        p = sub.add_parser(name)
        p.add_argument("label")
        p.add_argument("--exact", action="store_true")
        p.add_argument("--index", type=int, default=0)
        p.add_argument("--below", type=float)
        p.add_argument("--above", type=float)
        p.add_argument("--hold", type=float, default=0.15)
        p.add_argument("--timeout", type=float, default=15.0)
    sub.add_parser("ocr")
    p = sub.add_parser("tap-xy")
    p.add_argument("x", type=float)
    p.add_argument("y", type=float)
    p.add_argument("--hold", type=float, default=0.15)
    p = sub.add_parser("type")
    p.add_argument("text", nargs="?")
    p.add_argument("--env")
    p = sub.add_parser("key")
    p.add_argument("name", choices=sorted(KEYCODES))
    p = sub.add_parser("clear")
    p.add_argument("--count", type=int, default=60)
    p = sub.add_parser("swipe")
    for c in ("x1", "y1", "x2", "y2"):
        p.add_argument(c, type=float)
    p.add_argument("--duration", type=float, default=0.4)
    p = sub.add_parser("shot")
    p.add_argument("path")
    p.add_argument("--width", type=int, default=0)
    args = ap.parse_args()
    udid = args.udid

    if args.cmd == "tree":
        for e in elements(udid):
            print(describe(e))
    elif args.cmd == "find":
        found = matches(udid, args)
        for e in found:
            print(describe(e))
        sys.exit(0 if found else 1)
    elif args.cmd == "tap":
        found = matches(udid, args)
        if len(found) <= args.index:
            sys.exit('error: no element labelled "%s" (%d found)' % (args.label, len(found)))
        e = found[args.index]
        touch(udid, e["x"] + e["w"] / 2, e["y"] + e["h"] / 2, args.hold)
        print("tapped " + describe(e))
    elif args.cmd in ("wait", "gone"):
        deadline = time.time() + args.timeout
        start = time.time()
        while True:
            found = matches(udid, args)
            if (args.cmd == "wait") == bool(found):
                print("%s after %.1f s%s" % ("found" if found else "gone", time.time() - start,
                                             (": " + describe(found[0])) if found else ""))
                return
            if time.time() > deadline:
                sys.exit('error: "%s" %s after %.0f s' % (args.label, "not found" if args.cmd == "wait" else
                                                          "still there", args.timeout))
            time.sleep(0.3)
    elif args.cmd == "ocr":
        for e in screen_text(udid):
            print(describe(e))
    elif args.cmd == "tap-text":
        found = text_matches(udid, args)
        if len(found) <= args.index:
            sys.exit('error: no text "%s" on screen (%d found)' % (args.label, len(found)))
        e = found[args.index]
        touch(udid, e["x"] + e["w"] / 2, e["y"] + e["h"] / 2, args.hold)
        print("tapped " + describe(e))
    elif args.cmd in ("wait-text", "gone-text"):
        deadline = time.time() + args.timeout
        start = time.time()
        while True:
            found = text_matches(udid, args)
            if (args.cmd == "wait-text") == bool(found):
                print("%s after %.1f s%s" % ("found" if found else "gone", time.time() - start,
                                             (": " + describe(found[0])) if found else ""))
                return
            if time.time() > deadline:
                sys.exit('error: text "%s" %s after %.0f s' % (args.label, "not found" if args.cmd == "wait-text"
                                                               else "still there", args.timeout))
            time.sleep(0.5)
    elif args.cmd == "tap-xy":
        touch(udid, args.x, args.y, args.hold)
        print("tapped %.0f,%.0f" % (args.x, args.y))
    elif args.cmd == "type":
        text = os.environ.get(args.env, "") if args.env else args.text
        if not text:
            sys.exit("error: nothing to type")
        p = subprocess.run([axe_path(), "type", "--stdin", "--udid", udid], input=text.encode("utf-8"),
                           stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        if p.returncode != 0:
            sys.exit("error: axe type failed: %s" % p.stderr.decode("utf-8", "replace").strip())
        print("typed %d characters" % len(text))
    elif args.cmd == "key":
        # `axe key` doesn't reach every text field here; a one-key sequence does.
        axe("key-sequence", "--keycodes", KEYCODES[args.name], "--udid", udid)
        print("pressed " + args.name)
    elif args.cmd == "clear":
        # Select-all doesn't reach every field; forward-delete then backspace clears from any cursor position.
        for code in ("76", "42"):
            left = args.count
            while left > 0:  # AXe takes at most 100 keys per sequence
                n = min(left, 50)
                axe("key-sequence", "--keycodes", ",".join([code] * n), "--delay", "0.02", "--udid", udid)
                left -= n
        print("cleared")
    elif args.cmd == "swipe":
        axe("swipe", "--start-x", args.x1, "--start-y", args.y1, "--end-x", args.x2, "--end-y", args.y2,
            "--duration", args.duration, "--udid", udid)
        print("swiped")
    elif args.cmd == "shot":
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", args.path], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if args.width:
            subprocess.run(["sips", "-Z", str(args.width), args.path], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(args.path)


if __name__ == "__main__":
    main()
