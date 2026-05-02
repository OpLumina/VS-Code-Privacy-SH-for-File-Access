#!/usr/bin/env bash
# install.sh — scaffold the full vsmask project in the current directory.
set -euo pipefail

mkdir -p vsmask/scripts
mkdir -p vsmask/docker

# ── vsmask (CLI entry point) ──────────────────────────────────────────────────
cat << 'EOF' > vsmask/vsmask
#!/usr/bin/env bash
# vsmask — Launch an isolated VS Code (code-server) environment.
# Usage: vsmask <folder> [--port N] [--listen ADDR] [--no-persist] [--dry-run] [--cleanup <folder>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
SCRIPTS_DIR="$SCRIPT_DIR/scripts"
IMAGE_NAME="vsmask:latest"
DEFAULT_PORT=8080
DEFAULT_LISTEN="127.0.0.1"

die()  { echo "[vsmask] ERROR: $*" >&2; exit 1; }
info() { echo "[vsmask] $*"; }

usage() {
  cat <<USAGE
Usage:
  vsmask <folder>            Launch isolated VS Code for <folder>
  vsmask --cleanup <folder>  Force-commit persisted edits and purge volume
  vsmask --build             (Re)build the Docker image

Options:
  --port <n>     code-server port (default: $DEFAULT_PORT)
  --listen <ip>  Host interface to bind (default: $DEFAULT_LISTEN)
  --no-persist   Disable Docker volume; edits live only in tmpfs
  --dry-run      Print docker run command without executing
  -h, --help     Show this help
USAGE
  exit 0
}

FOLDER=""
PORT=$DEFAULT_PORT
LISTEN="$DEFAULT_LISTEN"
NO_PERSIST=false
DRY_RUN=false
CLEANUP=false

is_uint() { [[ "${1-}" =~ ^[0-9]+$ ]]; }

is_safe_relpath() {
  local p="${1-}"
  [[ -n "$p" ]] || return 1
  [[ "$p" != /* ]] || return 1
  [[ "$p" != *".."* ]] || return 1
  [[ "$p" != *$'\0'* ]] || return 1
  [[ "$p" != *":"* ]] || return 1
  return 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       PORT="${2-}"; shift 2 ;;
    --listen)     LISTEN="${2-}"; shift 2 ;;
    --no-persist) NO_PERSIST=true; shift ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --cleanup)    CLEANUP=true; FOLDER="$2"; shift 2 ;;
    --build)      docker build -t "$IMAGE_NAME" "$SCRIPT_DIR/docker/"; exit 0 ;;
    -h|--help)    usage ;;
    -*)           die "Unknown option: $1" ;;
    *)            FOLDER="$1"; shift ;;
  esac
done

[[ -z "$FOLDER" ]] && usage

PROJECT_DIR="$(realpath "$FOLDER")"
[[ -d "$PROJECT_DIR" ]] || die "Folder not found: $PROJECT_DIR"

VSIGNORE="$PROJECT_DIR/.vsignore"
VSALLOW="$PROJECT_DIR/.vsallow"

is_uint "$PORT" || die "--port must be an integer"
(( PORT >= 1 && PORT <= 65535 )) || die "--port must be in range 1..65535"

if $CLEANUP; then
  info "Running cleanup/commit for: $PROJECT_DIR"
  VOLUME_NAME="vsmask-$(basename "$PROJECT_DIR")-persist"
  bash "$SCRIPTS_DIR/shutdown.sh" "$PROJECT_DIR" "$VOLUME_NAME"
  exit 0
fi

[[ -f "$VSIGNORE" ]] || die ".vsignore not found in $PROJECT_DIR"
[[ -f "$VSALLOW"  ]] || die ".vsallow not found in $PROJECT_DIR"

docker info &>/dev/null || die "Docker is not running."
docker image inspect "$IMAGE_NAME" &>/dev/null \
  || die "Image '$IMAGE_NAME' not found. Run: vsmask --build"

info "Phase 1: Building blueprint..."
bash "$SCRIPTS_DIR/blueprint.sh" "$PROJECT_DIR"

CONTAINER_NAME="vsmask-$(basename "$PROJECT_DIR")-$$"
VOLUME_NAME="vsmask-$(basename "$PROJECT_DIR")-persist"
NETWORK_NAME="vsmask-net"
BLUEPRINT_DIR="$PROJECT_DIR/.blueprint"

docker network inspect "$NETWORK_NAME" &>/dev/null \
  || docker network create --internal "$NETWORK_NAME" >/dev/null

TMPFS_FLAGS=()
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*# ]] && continue
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  path="${line%/}"
  is_safe_relpath "$path" || die "Unsafe entry in .vsignore: '$line' (must be a safe relative path)"
  TMPFS_FLAGS+=("--tmpfs" "/workspace/$path:rw,size=512m")
done < "$VSIGNORE"

VOLUME_FLAGS=()
if ! $NO_PERSIST; then
  VOLUME_FLAGS+=("-v" "${VOLUME_NAME}:/persist")
fi

CMD=(
  docker run
  --rm
  --name "$CONTAINER_NAME"
  --network "$NETWORK_NAME"
  --add-host "host.docker.internal:host-gateway"
  -p "${LISTEN}:${PORT}:8080"
  # Filesystem isolation
  --read-only
  --cap-drop ALL
  --security-opt no-new-privileges
  --tmpfs /tmp:rw,size=256m
  --tmpfs /home/coder/.local:rw,size=256m,uid=1000
  --tmpfs /home/coder/.config:rw,size=128m,uid=1000
  --tmpfs /home/coder/.cache:rw,size=128m,uid=1000
  # Workspace
  -v "${PROJECT_DIR}:/workspace"
  -v "${BLUEPRINT_DIR}:/blueprint:ro"
  "${VOLUME_FLAGS[@]}"
  "${TMPFS_FLAGS[@]+"${TMPFS_FLAGS[@]}"}"
  # Keep code-server state on tmpfs (avoid unix-socket issues on /workspace when it's a Windows mount)
  -e "HOME=/home/coder"
  -e "SHELL=/bin/bash"
  --workdir /workspace
  -e "VSALLOW_FILE=/workspace/.vsallow"
  -e "VSIGNORE_FILE=/workspace/.vsignore"
  -e "NO_PERSIST=${NO_PERSIST}"
  "$IMAGE_NAME"
)

if $DRY_RUN; then
  info "Dry-run mode — docker command:"
  printf '  %q' "${CMD[@]}"
  echo
  exit 0
fi

info "Phase 2: Starting isolated container..."
info "  Project : $PROJECT_DIR"
info "  Port    : $PORT -> http://localhost:$PORT"
info "  Volume  : $($NO_PERSIST && echo 'disabled (--no-persist)' || echo "$VOLUME_NAME")"
info "  Network : $NETWORK_NAME (no internet; host reachable via host.docker.internal)"
echo
info "Docker publish check: expected host mapping ${LISTEN}:${PORT} -> container 8080"

if [[ -n "${WSL_INTEROP-}" || -n "${WSL_DISTRO_NAME-}" ]]; then
  if [[ "$LISTEN" == "127.0.0.1" ]]; then
    info "WSL note: if http://localhost:$PORT doesn't open in Windows, try: vsmask \"$FOLDER\" --listen 0.0.0.0"
  fi
fi

cleanup_on_exit() {
  info "Shutting down container..."
  docker stop "$CONTAINER_NAME" 2>/dev/null || true
  if ! $NO_PERSIST; then
    info "Phase 4: Committing changes back to host..."
    bash "$SCRIPTS_DIR/shutdown.sh" "$PROJECT_DIR" "$VOLUME_NAME"
  fi
  info "Done."
}
trap cleanup_on_exit EXIT INT TERM

"${CMD[@]}"
EOF

# ── scripts/blueprint.sh ──────────────────────────────────────────────────────
cat << 'EOF' > vsmask/scripts/blueprint.sh
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
EOF

# ── scripts/entrypoint.sh ────────────────────────────────────────────────────
cat << 'EOF' > vsmask/scripts/entrypoint.sh
#!/usr/bin/env bash
# Runs INSIDE the container.
# Phase 2: Inject allowed files from /blueprint into tmpfs-masked paths.
# Phase 3: Start inotify watcher + code-server.

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
    info "Phase 3: Persistence disabled (--no-persist). Skipping watcher."
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

  WATCHER_PID=$!
  info "  Watcher PID: $WATCHER_PID"
}

start_watcher

info "Starting code-server on :8080..."
exec code-server \
  --bind-addr 0.0.0.0:8080 \
  --auth none \
  --disable-telemetry \
  --disable-workspace-trust \
  "$WORKSPACE"
EOF

# ── scripts/shutdown.sh ───────────────────────────────────────────────────────
cat << 'EOF' > vsmask/scripts/shutdown.sh
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
EOF

# ── docker/entrypoint.sh (baked into image) ───────────────────────────────────
cat << 'EOF' > vsmask/docker/entrypoint.sh
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
EOF

# ── docker/Dockerfile ─────────────────────────────────────────────────────────
cat << 'EOF' > vsmask/docker/Dockerfile
FROM codercom/code-server:latest

USER root

RUN apt-get update && apt-get install -y --no-install-recommends \
      inotify-tools \
      diffutils \
      rsync \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /usr/local/bin/vsmask-entrypoint
RUN chmod +x /usr/local/bin/vsmask-entrypoint

USER coder

EXPOSE 8080

VOLUME ["/persist"]

ENTRYPOINT ["/usr/local/bin/vsmask-entrypoint"]
EOF

# ── README.md ─────────────────────────────────────────────────────────────────
cat << 'EOF' > vsmask/README.md
# vsmask

Launch an isolated VS Code environment where specific host directories are invisible.

## Quick Start

```bash
# 1. Build the image (once)
vsmask --build

# 2. Add config files to your project
echo "node_modules" >> myproject/.vsignore
echo "secrets"      >> myproject/.vsignore
echo "node_modules/.bin/tsc" >> myproject/.vsallow
echo "secrets/dev.env"       >> myproject/.vsallow

# 3. Launch
vsmask myproject
# -> http://localhost:8080
```

## Install

```bash
git clone <this repo>
cd vsmask
chmod +x vsmask scripts/*.sh docker/entrypoint.sh
vsmask --build
sudo ln -s "$(pwd)/vsmask" /usr/local/bin/vsmask
```

## Config Files

### `.vsignore` - paths to mask (hide) inside the container
```
# Comments are supported
node_modules
.git
secrets/
internal/docs
```

### `.vsallow` - exceptions: files to restore inside masked paths
```
node_modules/.bin/tsc
secrets/dev.env
internal/docs/api-spec.md
```

## Options

| Flag | Description |
|------|-------------|
| `--port <n>`         | Override code-server port (default: 8080) |
| `--listen <ip>`      | Host interface to bind (default: 127.0.0.1) |
| `--no-persist`       | Disable Docker volume; edits live only in tmpfs |
| `--dry-run`          | Print the docker run command without executing |
| `--cleanup <folder>` | Force-commit persisted edits and purge volume |
| `--build`            | (Re)build the Docker image |

## Networking

The container cannot reach the internet, but `host.docker.internal` resolves
to the host's `127.0.0.1`. Use it to reach local dev servers:

```
http://host.docker.internal:3000   <- your local API server
http://host.docker.internal:5432   <- local PostgreSQL
```

## Tip: add .blueprint to .gitignore

```bash
echo ".blueprint/" >> .gitignore
```
EOF

# ── permissions ───────────────────────────────────────────────────────────────
chmod +x vsmask/vsmask \
         vsmask/scripts/blueprint.sh \
         vsmask/scripts/entrypoint.sh \
         vsmask/scripts/shutdown.sh \
         vsmask/docker/entrypoint.sh

echo ""
echo "vsmask scaffolded successfully."
echo ""
echo "Next steps:"
echo "  cd vsmask"
echo "  vsmask --build"
echo "  sudo ln -s \"\$(pwd)/vsmask\" /usr/local/bin/vsmask"
