#!/bin/bash
# Release audit (Phase 4A): checks that a Relay build ships no debug code and shows its ATS settings,
# privacy manifests and version.
#
#   tools/relay-release-audit.sh bazel-bin/Telegram/Telegram.ipa      # or a Telegram.app directory
#
# Runs `strings -a` over every Mach-O binary in the bundle (app, frameworks, extensions) and counts debug
# markers: the RELAY_DEBUG_* launch hooks, the debug remote (its Darwin notification, its command file and
# the names of its commands), debug log prefixes and the dev server's address. Any hit fails the audit (exit 1).
# Debug code must be removed at compile time (`#if DEBUG`), so a release binary has none of these strings.
set -euo pipefail

INPUT="${1:?usage: $0 <Telegram.ipa | Telegram.app>}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if [[ -d "$INPUT" ]]; then
  APP="$INPUT"
else
  unzip -q -o "$INPUT" -d "$WORK"
  APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
fi
[[ -d "$APP" ]] || { echo "no .app found in $INPUT" >&2; exit 2; }

# Fixed strings. Debug remote command names that are ordinary words ("state", "fill", "press", "switch") are
# not listed: they occur in normal code too. The hyphenated ones are distinctive.
MARKERS=(
  "RELAY_DEBUG"
  "relay-debug"
  "org.relaychat.Relay.debug"
  "[Relay] debug"
  "debug login"
  "debug-write"
  "MattermostDebug"
  "MattermostDirectoryDebug"
  "RelayDebug"
  "relayDebug"
  "mattermostDebug"
  "debugScreenName"
  "debugFilledPasswordFields"
  "debugConfirmation"
  "debugState"
  "debugActions"
  "command.json"
  "localhost:8065"
  "127.0.0.1:8065"
  "simulate-push"
  "dump-chatlist"
  "dismiss-alerts"
  "title-relogin"
  "send-saved"
  "open-saved"
  "threads-list"
  "threads-row"
  "check-thread"
  "check-roots"
  "dialog-submit"
  "dialog-picker"
  "send-composer"
  "open-thread"
  "engine-search"
  "search-tap"
  "chat-search-step"
  "post-list-items"
  "post-list-tap"
  "peerinfo-search"
  "directory-do"
  "new-message"
  "info-add-member"
  "info-member"
  "info-leave"
  "info-state"
  "join-confirm"
  "tap-link"
  "tap-preview"
  "last-link"
  "notification-reply"
  "notification-read"
  "reaction-notifications"
  "RelaySecurityDebug"
  "RelayDiagnosticsDebug"
  "debugPressSetPasscode"
  "add-report"
  "press-set"
  "NSAllowsArbitraryLoads"
)

STRINGS_DIR="$WORK/strings"
mkdir -p "$STRINGS_DIR"
BINARIES=()
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    BINARIES+=("$f")
    rel="${f#"$APP"/}"
    strings -a "$f" > "$STRINGS_DIR/$(echo "$rel" | tr '/' '_').txt"
  fi
done < <(find "$APP" -type f -print0)

echo "Bundle: $APP"
echo "Version: $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Info.plist"))"
echo "Mach-O binaries scanned: ${#BINARIES[@]}"
echo

TOTAL=0
for marker in "${MARKERS[@]}"; do
  count=0
  where=()
  for s in "$STRINGS_DIR"/*.txt; do
    n=$(grep -cF -- "$marker" "$s" || true)
    if [[ "$n" -gt 0 ]]; then
      count=$((count + n))
      where+=("$(basename "$s" .txt):$n")
    fi
  done
  if [[ "$count" -gt 0 ]]; then
    printf '  %-32s %5d  %s\n' "$marker" "$count" "${where[*]}"
  fi
  TOTAL=$((TOTAL + count))
done
echo "Debug marker hits: $TOTAL"
echo

echo "ATS (NSAppTransportSecurity) and privacy manifest per bundle:"
PROBLEMS=()
while IFS= read -r -d '' plist; do
  bundle="$(dirname "$plist")"
  rel="${bundle#"$APP"}"; rel="${rel:-/}"
  ats="$(plutil -extract NSAppTransportSecurity json -o - "$plist" 2>/dev/null || echo 'none (ATS defaults: HTTPS only)')"
  privacy="no"
  [[ -f "$bundle/PrivacyInfo.xcprivacy" ]] && privacy="yes"
  printf '  %-60s ATS: %s  PrivacyInfo.xcprivacy: %s\n' "$rel" "$ats" "$privacy"
  if [[ "$ats" == *NSAllowsArbitraryLoads\"* || "$ats" == *NSExceptionDomains* ]]; then
    PROBLEMS+=("$rel: ATS exception for the app's own connections")
  fi
  if [[ "$privacy" == "no" && "$rel" != /Frameworks/* ]]; then
    PROBLEMS+=("$rel: no PrivacyInfo.xcprivacy")
  fi
done < <(find "$APP" \( -path '*/Frameworks/*.framework/Info.plist' -o -path '*/PlugIns/*.appex/Info.plist' -o -path "$APP/Info.plist" \) -print0)

# Closed-source SDKs (Phase 4A removed Telegram's RecaptchaEnterprise; none may come back unnoticed).
SDK_HITS=$(cat "$STRINGS_DIR"/*.txt | grep -cE 'RecaptchaEnterprise|FirebaseCore|GoogleUtilities|AppCenter|Crashlytics' || true)
echo
echo "Closed-source / analytics SDK markers: $SDK_HITS"
[[ "$SDK_HITS" -gt 0 ]] && PROBLEMS+=("closed-source or analytics SDK markers in the binaries")

echo
if [[ "$TOTAL" -gt 0 ]]; then
  PROBLEMS+=("debug markers in the binaries")
fi
if [[ "${#PROBLEMS[@]}" -gt 0 ]]; then
  printf 'FAIL: %s\n' "${PROBLEMS[@]}"
  exit 1
fi
echo "OK: no debug markers, no ATS exceptions for the app's own connections, privacy manifests present"
