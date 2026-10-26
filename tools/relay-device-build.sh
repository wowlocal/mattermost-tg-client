#!/bin/bash
# Device build signed with your own Apple Developer team, and install on a connected device.
#
#   tools/relay-device-build.sh build [debug_arm64|release_arm64]   # default debug_arm64
#   tools/relay-device-build.sh install <device udid or name>       # the last build's .ipa
#
# Needs (docs/BUILD.md "Device builds"):
#   RELAY_TEAM_ID       your 10-character team id (or set once in build-input/relay-device-team-id)
#   RELAY_PROFILES_DIR  the four development profiles (default ~/.relay-secrets/profiles): org.relaychat.Relay,
#                       .NotificationService, .NotificationContent, .Share; Make.py picks each by its App ID
#   an "Apple Development" identity of that team in the login keychain
#
# The team id only goes into git-ignored build-input/ (the committed configs keep a placeholder).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

cmd="${1:-build}"

case "$cmd" in
  build)
    configuration="${2:-debug_arm64}"
    team_id="${RELAY_TEAM_ID:-$(cat build-input/relay-device-team-id 2>/dev/null || true)}"
    [[ "$team_id" =~ ^[A-Z0-9]{10}$ ]] || { echo "set RELAY_TEAM_ID (10 characters) or build-input/relay-device-team-id" >&2; exit 1; }
    profiles="${RELAY_PROFILES_DIR:-$HOME/.relay-secrets/profiles}"
    compgen -G "$profiles/*.mobileprovision" >/dev/null || { echo "no .mobileprovision in $profiles" >&2; exit 1; }

    mkdir -p build-input
    printf '%s\n' "$team_id" > build-input/relay-device-team-id
    python3 - "$team_id" <<'EOF'
import json, sys
configuration = json.load(open('build-config/development-configuration.json'))
configuration['team_id'] = sys.argv[1]
json.dump(configuration, open('build-input/relay-device-configuration.json', 'w'), indent='\t')
EOF
    rm -rf build-input/relay-codesigning
    mkdir -p build-input/relay-codesigning/profiles build-input/relay-codesigning/certs
    cp "$profiles"/*.mobileprovision build-input/relay-codesigning/profiles/

    python3 build-system/Make/Make.py --cacheDir "${RELAY_BAZEL_CACHE:-/Volumes/X5/relay-bazel-cache}" build \
      --configurationPath build-input/relay-device-configuration.json \
      --codesigningInformationPath build-input/relay-codesigning \
      --buildNumber="$(git rev-list --count HEAD)" \
      --configuration="$configuration"
    echo "==> bazel-bin/Telegram/Telegram.ipa"
    ;;
  install)
    device="${2:?usage: $0 install <device udid or name> (idevice_id -l, xcrun devicectl list devices)}"
    # libimobiledevice (brew install ideviceinstaller) installs over usbmuxd and works with any device that
    # trusts this Mac; CoreDevice lists a device only once Xcode's own pairing has happened.
    if command -v ideviceinstaller >/dev/null && idevice_id -l 2>/dev/null | grep -qx "$device"; then
      ideviceinstaller -u "$device" install bazel-bin/Telegram/Telegram.ipa
    else
      work="$(mktemp -d)"
      trap 'rm -rf "$work"' EXIT
      unzip -q bazel-bin/Telegram/Telegram.ipa -d "$work"
      xcrun devicectl device install app --device "$device" "$work/Payload/Telegram.app"
    fi
    ;;
  *)
    echo "usage: $0 build [configuration] | install <device>" >&2
    exit 1
    ;;
esac
