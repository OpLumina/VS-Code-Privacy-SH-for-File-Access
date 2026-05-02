# vsmask

Launch an isolated VS Code environment where specific host directories are invisible.

## Quick Start

```bash
# 1. Build the image (once)
bash ./install.sh
vsmask --build

# 2. Add config files to your project
echo "node_modules" >> myproject/.vsignore
echo "secrets"      >> myproject/.vsignore
echo "node_modules/.bin/tsc" >> myproject/.vsallow
echo "secrets/dev.env"       >> myproject/.vsallow

# 3. Launch
vsmask myproject
# → http://localhost:8080
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

### `.vsignore` — paths to mask (hide) inside the container
```
# Comments are supported
node_modules
.git
secrets/
internal/docs
```

### `.vsallow` — exceptions: files to restore inside masked paths
```
node_modules/.bin/tsc
secrets/dev.env
internal/docs/api-spec.md
```

## Options

| Flag | Description |
|------|-------------|
| `--port <n>` | Override code-server port (default: 8080) |
| `--listen <ip>` | Host interface to bind (default: 127.0.0.1) |
| `--no-persist` | Disable Docker volume; edits live only in tmpfs |
| `--dry-run` | Print the docker run command without executing |
| `--cleanup <folder>` | Force-commit persisted edits and purge volume |
| `--build` | (Re)build the Docker image |

## Networking

The container cannot reach the internet, but `host.docker.internal` resolves to the host's `127.0.0.1`. Use it to reach local dev servers:

```
http://host.docker.internal:3000   ← your local API server
http://host.docker.internal:5432   ← local PostgreSQL
```

## Tip: add .blueprint to .gitignore

```bash
echo ".blueprint/" >> .gitignore
```

`.blueprint/` contains copies of your `.vsallow` files and is deleted on shutdown, but adding it to `.gitignore` prevents accidental commits if the cleanup is interrupted.
