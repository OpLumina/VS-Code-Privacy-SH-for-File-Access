#!/usr/bin/env bash
# Baked into the Docker image as /usr/local/bin/vsmask-entrypoint

set -euo pipefail

WORKSPACE="/workspace"
BLUEPRINT="/blueprint"
PERSIST="/persist"
VSALLOW="${VSALLOW_FILE:-/workspace/.vsallow}"
NO_PERSIST="${NO_PERSIST:-false}"

info()  { echo "[entrypoint] $*"; }
warn()  { echo "[entrypoint] WARNING: $*" >&2; }

is_safe_relpath() {
  local p="${1-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || return 1
  [[ "$p" != *".."* ]] || return 1
  [[ "$p" != *$'\0'* ]] || return 1
  [[ "$p" != *":"* ]] || return 1
  return 0
}

info "Phase 2: Injecting allowed files into masked paths..."

inject_count=0
if [[ -d "$BLUEPRINT" ]]; then
  while IFS= read -r -d '' src_file; do
    rel="${src_file#$BLUEPRINT/}"
    dest="$WORKSPACE/$rel"
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir"
    cp "$src_file" "$dest"
    info "  Injected: $rel"
    (( inject_count++ ))
  done < <(find "$BLUEPRINT" -type f -print0)
else
  warn "/blueprint not mounted - no files will be injected."
fi

info "Phase 2 complete: $inject_count file(s) injected."

start_watcher() {
  if $NO_PERSIST; then
    info "Phase 3: Persistence disabled. Skipping watcher."
    return
  fi

  [[ -d "$PERSIST" ]] || { warn "/persist volume not mounted. Skipping watcher."; return; }

  info "Phase 3: Starting inotify watcher on masked paths..."

  local watch_dirs=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    rel="${line#/}"
    rel="${rel%/}"
    is_safe_relpath "$rel" || { warn "Unsafe path in .vsallow, skipping: $line"; continue; }
    dir="$WORKSPACE/$(dirname "$rel")"
    [[ -d "$dir" ]] && watch_dirs+=("$dir")
  done < "$VSALLOW"

  if [[ ${#watch_dirs[@]} -eq 0 ]]; then
    warn "No watch directories found. Skipping watcher."
    return
  fi

  mapfile -t watch_dirs < <(printf '%s\n' "${watch_dirs[@]}" | sort -u)
  info "  Watching: ${watch_dirs[*]}"

  (
    inotifywait -m -r -e close_write --format '%w%f' "${watch_dirs[@]}" 2>/dev/null \
    | while IFS= read -r changed_file; do
        rel="${changed_file#$WORKSPACE/}"
        persist_path="$PERSIST/$rel"
        persist_dir="$(dirname "$persist_path")"
        mkdir -p "$persist_dir"
        cp "$changed_file" "$persist_path"
        echo "[watcher] Persisted: $rel"
      done
  ) &

  info "  Watcher PID: $!"
}

start_watcher

info "Starting code-server on :8080..."
exec code-server \
  --bind-addr 0.0.0.0:8080 \
  --auth none \
  --disable-telemetry \
  --disable-workspace-trust \
  "$WORKSPACE"
