#!/usr/bin/env bash
# Start the local Mattermost dev server (compose project "mmdev").
# Creates .env with random dev-only passwords on first run.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

compose() {
  docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" --env-file "$DIR/.env" "$@"
}

if [ ! -f .env ]; then
  echo "==> .env not found, generating one with random dev-only passwords"
  /usr/bin/env python3 - <<'PY'
import secrets
src = open(".env.example").read().splitlines()
out = []
for line in src:
    if line.strip().endswith("=change-me"):
        key = line.split("=", 1)[0]
        line = "%s=%s" % (key, secrets.token_urlsafe(18))
    out.append(line)
open(".env", "w").write("\n".join(out) + "\n")
PY
  chmod 600 .env
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a
PORT="${MM_PORT:-8065}"

# Refuse to start if somebody else already owns the port.
running="$(compose ps -q --status running mattermost 2>/dev/null || true)"
if [ -z "$running" ] && lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "error: port $PORT is already in use by another process:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2 || true
  echo "Pick a free port: set MM_PORT and MM_SITE_URL in .env." >&2
  exit 1
fi

echo "==> Starting mmdev (Mattermost + Postgres)"
compose up -d --wait --wait-timeout 600

echo "==> Waiting for the API"
for _ in $(seq 1 120); do
  if curl -fsS "http://127.0.0.1:$PORT/api/v4/system/ping" >/dev/null 2>&1; then
    version="$(curl -fsS -o /dev/null -D - "http://127.0.0.1:$PORT/api/v4/system/ping" | awk -F': ' 'tolower($1)=="x-version-id"{print $2}' | tr -d '\r')"
    echo "==> Mattermost is up: ${MM_SITE_URL:-http://localhost:$PORT} (X-Version-Id: $version)"
    echo "    Seed it with: $DIR/seed.py"
    exit 0
  fi
  sleep 1
done
echo "error: Mattermost did not answer /api/v4/system/ping in time; see: docker compose -p mmdev logs mattermost" >&2
exit 1
