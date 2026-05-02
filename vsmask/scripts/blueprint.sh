#!/usr/bin/env bash
# Phase 1: build .blueprint/ on the host.
# Usage: blueprint.sh <project_dir>

set -euo pipefail

PROJECT_DIR="${1:?Usage: blueprint.sh <project_dir>}"
VSALLOW="$PROJECT_DIR/.vsallow"
BLUEPRINT="$PROJECT_DIR/.blueprint"

[[ -f "$VSALLOW" ]] || { echo "[blueprint] ERROR: .vsallow not found in $PROJECT_DIR" >&2; exit 1; }

is_safe_relpath() {
  local p="${1-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || return 1
  [[ "$p" != *".."* ]] || return 1
  [[ "$p" != *$'\0'* ]] || return 1
  [[ "$p" != *":"* ]] || return 1
  return 0
}

rm -rf "$BLUEPRINT"
mkdir -p "$BLUEPRINT"

count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue

  rel_path="${line#/}"
  rel_path="${rel_path%/}"
  is_safe_relpath "$rel_path" || { echo "[blueprint] WARNING: unsafe path in .vsallow, skipping: $line" >&2; continue; }
  src="$PROJECT_DIR/$rel_path"

  if [[ ! -e "$src" ]]; then
    echo "[blueprint] WARNING: allowed path does not exist, skipping: $rel_path" >&2
    continue
  fi

  src_real="$(realpath "$src")"
  project_real="$(realpath "$PROJECT_DIR")"
  case "$src_real" in
    "$project_real"/*) ;;
    *) echo "[blueprint] WARNING: path escapes project dir, skipping: $rel_path" >&2; continue ;;
  esac

  dest_dir="$BLUEPRINT/$(dirname "$rel_path")"
  mkdir -p "$dest_dir"

  if [[ -f "$src" ]]; then
    cp -- "$src" "$BLUEPRINT/$rel_path"
    echo "[blueprint] Seeded: $rel_path"
    (( count++ ))
  elif [[ -d "$src" ]]; then
    cp -r -- "$src" "$dest_dir/"
    echo "[blueprint] Seeded dir: $rel_path"
    (( count++ ))
  fi

done < "$VSALLOW"

echo "[blueprint] Blueprint ready: $count item(s) seeded -> $BLUEPRINT"
