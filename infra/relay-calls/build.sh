#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/org.relaychat.calls/server/dist
cp plugin.json build/org.relaychat.calls/
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" go build -trimpath -ldflags='-s -w' -o "build/org.relaychat.calls/server/dist/plugin-linux-$arch" ./server
done
tar -czf build/org.relaychat.calls-0.1.0.tar.gz -C build org.relaychat.calls
