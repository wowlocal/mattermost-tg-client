#!/usr/bin/env bash
# Stop the local Mattermost dev server. Data (named volumes) is kept.
# Use ./reset.sh to wipe data.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$DIR/.env.example"

docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" --env-file "$ENV_FILE" down "$@"
