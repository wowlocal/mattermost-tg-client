#!/bin/bash
# Regenerates Telegram/Relay/RelayLicenses.json (Settings → About Relay → Open Source Licenses) from the code
# that is linked into the app: bazel's configured dependency graph without build tools, plus the Rust crates'
# Cargo.toml and license files from bazel's external repositories. Run from the repository root after a build
# (Make.py has downloaded bazel and fetched the crates).
set -euo pipefail
cd "$(dirname "$0")/../.."
BAZEL="$(ls build-input/bazel-*-darwin-arm64 | head -1)"
PACKAGES="$(mktemp)"
trap 'rm -f "$PACKAGES"' EXIT
"$BAZEL" cquery 'deps(//Telegram:Telegram)' --notool_deps \
  --//Telegram:disableProvisioningProfiles -c opt --ios_multi_cpus=sim_arm64 --watchos_cpus=arm64_32 \
  --define=buildNumber=1 --output=label 2>/dev/null \
  | sed -E 's/ \(.*\)$//; s#^@@?([^/]*)//#@\1//#; s#:.*$##; s#^//##' | sort -u > "$PACKAGES"
python3 -I tools/relay-licenses/generate.py "$PACKAGES" "$("$BAZEL" info output_base 2>/dev/null)/external"
