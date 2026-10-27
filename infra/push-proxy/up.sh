#!/usr/bin/env bash
# Render the push proxy config from .env + the template and start the proxy (compose project "relaypush").
# Needs the dev server's network (infra/dev-server/up.sh) and an APNs key (README).
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ ! -f .env ]; then
  echo "error: $DIR/.env not found. Copy .env.example to .env and fill it in (README)," >&2
  echo "       or run ./make-dev-key.sh for a throwaway key that only tests the wiring." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${APNS_KEY_FILE:?set APNS_KEY_FILE in .env}"
: "${APNS_KEY_ID:?set APNS_KEY_ID in .env}"
: "${APNS_TEAM_ID:?set APNS_TEAM_ID in .env}"
APNS_TOPIC="${APNS_TOPIC:-org.relaychat.Relay}"
LOG_LEVEL="${LOG_LEVEL:-debug}"

case "$APNS_KEY_FILE" in
  /*) ;;
  *) echo "error: APNS_KEY_FILE must be an absolute path" >&2; exit 1 ;;
esac
if [ ! -f "$APNS_KEY_FILE" ]; then
  echo "error: APNS_KEY_FILE ($APNS_KEY_FILE) does not exist" >&2
  exit 1
fi
case "$APNS_KEY_FILE" in
  "$DIR"/*) case "$APNS_KEY_FILE" in
      "$DIR"/.state/*) ;;  # make-dev-key.sh's throwaway key (git-ignored)
      *) echo "error: keep the APNs key outside the repository" >&2; exit 1 ;;
    esac ;;
esac
# The proxy runs as "nobody" and must be able to read the mounted key.
if [ ! -r "$APNS_KEY_FILE" ]; then
  echo "error: $APNS_KEY_FILE is not readable" >&2
  exit 1
fi

if ! docker network inspect mmdev_default >/dev/null 2>&1; then
  echo "error: the dev server's network mmdev_default does not exist; run infra/dev-server/up.sh first" >&2
  exit 1
fi

mkdir -p .state
sed -e "s|__APNS_KEY_ID__|$APNS_KEY_ID|g" \
    -e "s|__APNS_TEAM_ID__|$APNS_TEAM_ID|g" \
    -e "s|__APNS_TOPIC__|$APNS_TOPIC|g" \
    -e "s|__LOG_LEVEL__|$LOG_LEVEL|g" \
    mattermost-push-proxy.template.json > .state/mattermost-push-proxy.json
chmod 644 .state/mattermost-push-proxy.json

# --force-recreate: the rendered config is a bind mount, so a changed config alone would not restart a running proxy.
docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" up -d --force-recreate --wait --wait-timeout 120
echo "==> push proxy up: http://127.0.0.1:${PUSH_PROXY_PORT:-8066} (host), http://push-proxy:8066 (mmdev_default)"
docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" logs --no-log-prefix push-proxy | grep -E "Initializing apple|Failed to initialize|Server is listening|Loading" || true
echo "    Point the dev server at it: $DIR/configure-dev-server.py"
