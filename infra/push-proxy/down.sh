#!/usr/bin/env bash
# Stop the push proxy (compose project "relaypush").
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$DIR/.env.example"

# APNS_KEY_FILE is only needed to start; give compose a dummy so `down` works without .env.
APNS_KEY_FILE="${APNS_KEY_FILE:-/dev/null}" docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" --env-file "$ENV_FILE" down "$@"
