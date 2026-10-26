#!/usr/bin/env bash
# Wipe the mmdev project's containers and volumes (and nothing else),
# then start fresh and seed.
#
#   ./reset.sh          asks for confirmation
#   ./reset.sh --yes    no questions
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

if [ "${1:-}" != "--yes" ] && [ "${1:-}" != "-y" ]; then
  if [ -t 0 ]; then
    read -r -p "Delete ALL data of the local mmdev Mattermost server? [y/N] " answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1 ;; esac
  else
    echo "error: refusing to reset without --yes (non-interactive)" >&2
    exit 1
  fi
fi

start=$(date +%s)
ENV_FILE="$DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$DIR/.env.example"

echo "==> Removing mmdev containers, network and volumes"
# -v only removes the named volumes declared in docker-compose.yml for this
# project (mmdev_*). Images and other projects are untouched.
docker compose --project-directory "$DIR" -f "$DIR/docker-compose.yml" --env-file "$ENV_FILE" \
  down -v --remove-orphans

# Seed state (bot token, generated assets, import zip) belongs to the old data.
rm -rf "$DIR/.state"

"$DIR/up.sh"
/usr/bin/env python3 "$DIR/seed.py"

end=$(date +%s)
echo "==> Reset + seed finished in $((end - start))s"
