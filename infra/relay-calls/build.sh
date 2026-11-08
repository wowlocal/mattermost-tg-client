#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
version=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' plugin.json | head -n 1)
if [ -z "$version" ]; then
  echo "plugin.json has no version" >&2
  exit 1
fi
rm -rf build/org.relaychat.calls
mkdir -p build/org.relaychat.calls/server/dist
cp plugin.json build/org.relaychat.calls/
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags='-s -w' -o "build/org.relaychat.calls/server/dist/plugin-linux-$arch" ./server
done
tar -czf "build/org.relaychat.calls-$version.tar.gz" -C build org.relaychat.calls
echo "build/org.relaychat.calls-$version.tar.gz"
