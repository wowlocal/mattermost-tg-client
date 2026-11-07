#!/usr/bin/env python3
import argparse
from pathlib import Path
import plistlib
import sys
import zipfile


def inspect_bundle(read, names):
    failures = []
    info = plistlib.loads(read("Info.plist"))
    extension_id = info.get("RTCScreenSharingExtension")
    group = info.get("RTCAppGroupIdentifier")
    if not extension_id or not group:
        failures.append("The app is missing its ReplayKit extension or app-group setting.")
    extensions = [name for name in names if name.startswith("PlugIns/") and name.count("/") == 2 and name.endswith(".appex/Info.plist")]
    broadcast_path = next((name for name in extensions if plistlib.loads(read(name)).get("CFBundleIdentifier") == extension_id), None)
    broadcast = plistlib.loads(read(broadcast_path)) if broadcast_path else None
    if broadcast is None:
        failures.append("The configured ReplayKit broadcast extension is not embedded.")
    else:
        if broadcast_path.removesuffix("Info.plist") + "PrivacyInfo.xcprivacy" not in names:
            failures.append("The broadcast extension is missing its privacy manifest.")
        if not str(broadcast.get("CFBundleDisplayName", "")).strip():
            failures.append("The broadcast extension has no CFBundleDisplayName; iOS will reject installation.")
        if broadcast.get("RTCAppGroupIdentifier") != group:
            failures.append("The app and broadcast extension use different app groups.")
        settings = broadcast.get("NSExtension", {})
        if settings.get("NSExtensionPointIdentifier") != "com.apple.broadcast-services-upload":
            failures.append("The broadcast extension has the wrong extension point.")
        if settings.get("NSExtensionPrincipalClass") != "RelayBroadcastSampleHandler":
            failures.append("The broadcast extension has the wrong sample handler.")
    for framework in ("LiveKitWebRTC", "RustLiveKitFFI"):
        binary = f"Frameworks/{framework}.framework/{framework}"
        if binary not in names or not read(binary):
            failures.append(f"{framework}.framework is not embedded; dyld cannot launch the app.")
    return failures


def main():
    parser = argparse.ArgumentParser(description="Check the install-time Relay Calls bundle requirements before launching on a simulator or device.")
    parser.add_argument("bundle", type=Path, help="The freshly built .ipa or extracted .app")
    args = parser.parse_args()
    if args.bundle.is_file():
        with zipfile.ZipFile(args.bundle) as archive:
            roots = [name.removesuffix("Info.plist") for name in archive.namelist() if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")]
            if len(roots) != 1:
                parser.error("Expected one app in the IPA payload.")
            root = roots[0]
            names = {name[len(root):] for name in archive.namelist() if name.startswith(root)}
            failures = inspect_bundle(lambda name: archive.read(root + name), names)
    else:
        root = args.bundle
        names = {str(path.relative_to(root)) for path in root.rglob("*")}
        failures = inspect_bundle(lambda name: (root / name).read_bytes(), names)
    for failure in failures:
        print(f"FAIL: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("Relay Calls bundle checks passed: broadcast metadata and privacy manifest, app group and both dynamic frameworks.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
