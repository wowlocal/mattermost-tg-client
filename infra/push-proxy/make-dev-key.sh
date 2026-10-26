#!/usr/bin/env bash
# Writes a THROWAWAY P-256 key in the APNs auth key format to .state/dev-key/ (git-ignored) and creates .env
# for it if there is none. It is NOT an Apple key: the proxy starts with it and sends to APNs, and APNs
# answers 403 InvalidProviderToken. That is enough to check the server → proxy → APNs wiring without a real
# key. Replace .env with the real key's values for delivery (README).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

KEY_ID="DEVKEY0001"
TEAM_ID="DEVTEAM001"
mkdir -p .state/dev-key
KEY_FILE="$DIR/.state/dev-key/AuthKey_$KEY_ID.p8"
if [ ! -f "$KEY_FILE" ]; then
  openssl ecparam -name prime256v1 -genkey -noout | openssl pkcs8 -topk8 -nocrypt -out "$KEY_FILE"
  # Readable by the proxy container's "nobody" user. Throwaway key only; never do this with a real one.
  chmod 644 "$KEY_FILE"
fi

if [ -f .env ]; then
  echo "==> .env exists; not touching it. For the throwaway key use:"
else
  cp .env.example .env
  chmod 600 .env
  echo "==> wrote .env with:"
fi
echo "APNS_KEY_FILE=$KEY_FILE"
echo "APNS_KEY_ID=$KEY_ID"
echo "APNS_TEAM_ID=$TEAM_ID"
if grep -q "^APNS_KEY_FILE=/absolute/path" .env; then
  sed -i '' -e "s|^APNS_KEY_FILE=.*|APNS_KEY_FILE=$KEY_FILE|" -e "s|^APNS_KEY_ID=.*|APNS_KEY_ID=$KEY_ID|" -e "s|^APNS_TEAM_ID=.*|APNS_TEAM_ID=$TEAM_ID|" .env
fi
