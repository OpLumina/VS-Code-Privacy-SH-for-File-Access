# vmask (WIP)

A rootless privacy shield for VS Code. `vmask` uses **Linux namespaces** (via `bubblewrap`) to launch VS Code in a sandboxed environment where sensitive directories are replaced by empty `tmpfs` mounts. 

To VS Code—and any extensions like Codex or Gemini Code assist, language servers, or plugins running inside it, the masked folders appear completely empty. Because this happens in a private namespace, your original files remain fully accessible to the rest of your system and are never modified.

---

## Key Features

* **No Sudo Required**: Uses `bubblewrap` to create unprivileged user namespaces, eliminating the need for `sudo` or root permissions.
* **Zero-Footprint Cleanup**: Since masking occurs inside a private namespace, all virtual mounts vanish instantly when VS Code closes. No manual unmounting or "cleanup traps" are required.
* **WSL-Ready**: Automatically detects and converts Windows-style paths (e.g., `C:\Users\...`) to Unix paths for seamless use in WSL.
* **Granular Control**: Supports a `.vsallow` file to exempt specific files from broad wildcard masks (e.g., mask all of `~/.ssh/*` but allow `~/.ssh/known_hosts`).

---

## Requirements
On the first run of the script, it will have a user input asking you if you'd like to install the required external dependencies (bubblewrap)
* **Linux or WSL**
* **bubblewrap (`bwrap`)**: Used to create the sandbox.
* **VS Code CLI (`code`)**: Must be available in PATH.
* **Bash 4+**

---

## Usage

```bash
./vmask.sh [--mask FILE] [--allow FILE] [TARGET_DIR]
```

| Argument | Default | Description |
|---|---|---|
| `--mask FILE` | `.vsignore` | File listing paths to hide. |
| `--allow FILE` | `.vsallow` | File listing paths to keep visible. |
| `TARGET_DIR` | `.` | The directory to open in VS Code. |

### Examples

```bash
# Launch with default .vsignore and .vsallow in the current dir
./vmask.sh

# Open a specific project with custom masks
./vmask.sh --mask ~/work.vsignore ~/projects/secret-app
```

---

## Configuration

`vmask` uses two configuration files (one path per line). Lines starting with `#` are ignored.

### `.vsignore` (The Mask List)
Define what to hide. You can use standard shell wildcards (globs).
```text
/home/user/.ssh
/home/user/projects/top-secret/*
C:\Users\User\Documents\Financials
```
**Note:** Wildcards are expanded safely using `compgen` to prevent shell injection.

### `.vsallow` (The Exceptions)
Define what should remain visible. This file always overrides the mask list.
```text
/home/user/.ssh/known_hosts
```

---

## How It Works (The Sandbox)

Instead of mounting a filesystem globally, `vmask` executes the following sequence:
1.  **Namespace Creation**: `bwrap` creates a new, private mount namespace.
2.  **Filesystem Mapping**: The real filesystem is mapped into the sandbox as a base layer.
3.  **Shadowing**: For every path in your mask list, an empty `tmpfs` is mounted over the top within the sandbox.
4.  **Execution**: VS Code is launched inside this "hall of mirrors."
5.  **Termination**: When VS Code exits, the namespace is destroyed, and the virtual mounts disappear from memory automatically.

---

## License

This project is licensed under the **MIT License**.
