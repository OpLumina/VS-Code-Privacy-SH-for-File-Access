#!/usr/bin/env bash
# Phase 4: Commit persisted edits back to host, then purge.
# Usage: shutdown.sh <project_dir> <volume_name>

set -euo pipefail

PROJECT_DIR="${1:?Usage: shutdown.sh <project_dir> <volume_name>}"
VOLUME_NAME="${2:?Usage: shutdown.sh <project_dir> <volume_name>}"
BLUEPRINT="$PROJECT_DIR/.blueprint"

info()  { echo "[shutdown] $*"; }
warn()  { echo "[shutdown] WARNING: $*" >&2; }

if ! docker volume inspect "$VOLUME_NAME" &>/dev/null; then
  info "No persist volume found ($VOLUME_NAME) - nothing to commit."
else
  info "Mounting persist volume to read changes..."

  docker run --rm \
    -v "${VOLUME_NAME}:/persist:ro" \
    -v "${PROJECT_DIR}:/host_project" \
    --entrypoint /bin/sh \
    alpine:3.19 \
    -c '
      set -e
      cd /persist
      find . -type f | while IFS= read -r rel_file; do
        rel="${rel_file#./}"
        host="/host_project/$rel"
        persist="/persist/$rel"
        if [ ! -f "$host" ]; then
          echo "[commit] NEW: $rel"
          mkdir -p "$(dirname "$host")"
          cp "$persist" "$host"
        elif ! diff -q "$persist" "$host" > /dev/null 2>&1; then
          echo "[commit] UPDATED: $rel"
          cp "$persist" "$host"
        else
          echo "[commit] UNCHANGED: $rel (skipped)"
        fi
      done
    '

  info "Commit complete."
  docker volume rm "$VOLUME_NAME" >/dev/null && info "Removed volume: $VOLUME_NAME"
fi

if [[ -d "$BLUEPRINT" ]]; then
  rm -rf "$BLUEPRINT"
  info "Removed .blueprint/"
fi

info "Shutdown complete."
