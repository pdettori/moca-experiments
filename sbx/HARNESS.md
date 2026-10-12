# E14 harness: every script and config used

All code for E14, verbatim from the runs except for these substitutions, so nothing internal is
published:

| Variable | Stands for |
| --- | --- |
| `$MOCA` | a checkout of the main repo at `feat/relay-client-tokens` (`pdettori/moca`, commit `467b874`) |
| `$JUMP`, `$RIG` | the SSH jump host and the bare-metal rig (`user@host`) |
| `$AWS_RIG`, `$AWS_SSH_OPTS` | the AWS rig of rounds 1–2's MCP path, and its ssh options (key) |
| `LITELLM_BASE_URL`, `LITELLM_KEY` | the model gateway and its key (any Anthropic-compatible endpoint) |

Paths under `/tmp/...` are the scratch locations the runs used; [`RUNBOOK.md`](RUNBOOK.md) says
which file goes where and in what order. Three pieces have no other published home yet, so this
file is their only copy: the `sbx` CLI, the MCP server (rounds 1–2's MCP path), and the SWE-bench
harness.

**Contents**

1. [Rig setup (bare metal)](#1-rig-setup-bare-metal)
2. [Client: sbx CLI and configs (gRPC path)](#2-client-sbx-cli-and-configs-grpc-path)
3. [Client: MCP server and configs (MCP path)](#3-client-mcp-server-and-configs-mcp-path)
4. [Rounds 1–2 runners](#4-rounds-12-runners)
5. [Round 3: SWE-bench harness](#5-round-3-swe-bench-harness)

## 1. Rig setup (bare metal)

Run as a sudo-capable user on the KVM host, in order. Each phase appends to
`~/sbx-backend-manifest.md`, the record of every change made, for undoing it.

### Phase 1: code, pi-fork, worker binary

Expects `/tmp/sbx-backend.bundle` (`git bundle create /tmp/sbx-backend.bundle feat/relay-client-tokens` in `$MOCA`) and `/tmp/build-rootfs.sh` (`git show upstream/main:deploy/microvm/build-rootfs.sh` in the main repo).

```bash
#!/bin/bash
# Phase 1: code into /opt/sbx-backend (branch feat/relay-client-tokens), pi-fork built, deps installed,
# microvm-worker built. Touches nothing of the existing P6 install. Logged to ~/sbx-backend-manifest.md.
set -euo pipefail
M=~/sbx-backend-manifest.md
D=/opt/sbx-backend
[ -e "$D" ] && { echo "$D already exists; refusing"; exit 1; }
{
  echo "# sbx gRPC backend (relay + microvm-worker, standalone from P6) — manifest"
  echo "started $(date -u +%FT%TZ) by $(id -un) on $(hostname)"
  echo
  echo "## Found"
  echo "- P6 running: $(systemctl is-active sh-relay sh-supervisor sh-control-plane | tr '\n' ' ')(relay 9443/9444, sh-redis 6379); /opt/serverless-harness has uncommitted changes, left untouched"
  echo "- /srv: $(ls /srv | tr '\n' ' ')(experiment leftovers, left untouched)"
  echo "- ports 9543 9544 6390 8787 free; no microvm units installed"
  echo
  echo "## Changes"
} > "$M"

sudo install -d -o "$(id -un)" -g "$(id -gn)" -m 755 "$D"
git clone -q --branch feat/relay-client-tokens /tmp/sbx-backend.bundle "$D"
git -C "$D" remote set-url origin https://github.com/pdettori/moca
echo "- created $D: clone of feat/relay-client-tokens @ $(git -C "$D" rev-parse --short HEAD)" >> "$M"

git -C "$D" submodule update --init pi-fork
(cd "$D/pi-fork" && npm ci --no-audit --no-fund > /tmp/sbx-pi-ci.log 2>&1 && npm run build > /tmp/sbx-pi-build.log 2>&1)
echo "- pi-fork submodule checked out and built in $D/pi-fork" >> "$M"

(cd "$D" && npx -y pnpm@9.15.9 install --frozen-lockfile > /tmp/sbx-pnpm.log 2>&1)
echo "- pnpm install in $D" >> "$M"

(cd "$D/remote-worker" && CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags='-s -w' -o /tmp/sbx-microvm-worker ./cmd/microvm-worker)
sudo install -m 755 /tmp/sbx-microvm-worker /usr/local/bin/sbx-microvm-worker
echo "- installed /usr/local/bin/sbx-microvm-worker (built from $D/remote-worker)" >> "$M"

echo "phase 1 ok: $(git -C "$D" log --oneline -1)"
```

### Phase 2: golden snapshot

```bash
#!/bin/bash
# Phase 2: golden snapshot for the standalone backend under /srv/sbx (one filesystem with its
# workspaces and jail, as build-snapshot.sh requires). Logged to ~/sbx-backend-manifest.md.
set -euo pipefail
M=~/sbx-backend-manifest.md
D=/opt/sbx-backend
B=/srv/sbx/build
P="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin"
IMAGE=ghcr.io/rossoctl/moca-remote-worker:latest

sudo install -d -m 755 /srv/sbx "$B" /srv/sbx/snapshots
echo "- created /srv/sbx (build, snapshots)" >> "$M"

# 1. Kernel: Firecracker CI's, as in P4-ON-P6.md ("Build the golden snapshot").
ARCH="$(uname -m)"; S3="https://s3.amazonaws.com/spec.ccfc.min"
CI=$(curl -fsSL "$S3?list-type=2&prefix=firecracker-ci/&delimiter=/" |
  grep -oP "(?<=<Prefix>)firecracker-ci/[0-9]{8}-[^/]+/(?=</Prefix>)" | sort | tail -1)
KEY=$(curl -fsSL "$S3?list-type=2&prefix=${CI}${ARCH}/vmlinux-" |
  grep -oP "(?<=<Key>)(${CI}${ARCH}/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3})(?=</Key>)" | sort -V | tail -1)
KERNEL="$B/vmlinux-${KEY##*vmlinux-}"
sudo curl -fsSL -o "$KERNEL" "$S3/$KEY"
echo "- downloaded kernel $KERNEL ($KEY)" >> "$M"

# 2. Rootfs: the P6 sandbox image's own filesystem.
sudo env "$P" podman image exists "$IMAGE" || sudo env "$P" podman pull -q "$IMAGE"
sudo env "$P" bash /tmp/build-rootfs.sh --out "$B/rootfs" --image "$IMAGE" > /tmp/sbx-rootfs.log 2>&1
echo "- built rootfs tree $B/rootfs from $IMAGE ($(sudo cat "$B/rootfs/etc/moca-rootfs-source" | tr '\n' ' '))" >> "$M"

# 3. Snapshot, from this tree's own build-snapshot.sh and guest agent.
sudo env "$P" bash "$D/deploy/microvm/build-snapshot.sh" --kernel "$KERNEL" --rootfs "$B/rootfs" \
  --agent "$D/remote-worker" --image default --vmm firecracker --guest-ram-mb 256 \
  --out /srv/sbx/snapshots/default > /tmp/sbx-snapshot.log 2>&1 || { tail -30 /tmp/sbx-snapshot.log; exit 1; }
echo "- built snapshot /srv/sbx/snapshots/default" >> "$M"
sudo cat /srv/sbx/snapshots/default/manifest.json
```

### Phase 3: Redis, relay and worker units, tokens

Generates the client token into `~/sbx-exec-client.token` (mode 600) for hand-off.

```bash
#!/bin/bash
# Phase 3: standalone services for the sbx gRPC backend. Logged to ~/sbx-backend-manifest.md.
set -euo pipefail
M=~/sbx-backend-manifest.md
D=/opt/sbx-backend
E=/etc/sbx-backend
U=/etc/systemd/system
P="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin"

# Redis for the relay's presence records: its own, so P6's supervisor never sees this worker.
sudo env "$P" podman run -d --name sbx-redis --restart=always -p 127.0.0.1:6390:6379 \
  docker.io/library/redis:7-alpine > /dev/null
echo "- started podman container sbx-redis (127.0.0.1:6390, --restart=always)" >> "$M"

ATTACH=$(openssl rand -hex 32) EXEC=$(openssl rand -hex 32) CLIENT=$(openssl rand -hex 32)
sudo install -d -m 755 "$E"
sudo install -m 600 /dev/null "$E/relay.env"
sudo tee "$E/relay.env" > /dev/null <<EOF
# sbx gRPC backend relay (standalone from P6's sh-relay). See $D/deploy/vm/env/relay.env.example.
SH_RELAY_PORT=9543
MOCA_RELAY_EXEC_ADDR=127.0.0.1:9544
REDIS_URL=redis://127.0.0.1:6390
SH_RELAY_TOKEN_moca_microvm_0=$ATTACH
MOCA_RELAY_EXEC_TOKEN=$EXEC
MOCA_RELAY_CLIENT_TOKENS=moca_microvm_0:sbx-exec-:$CLIENT
EOF
sudo install -m 600 /dev/null "$E/worker.env"
sudo tee "$E/worker.env" > /dev/null <<EOF
RELAY_ADDR=127.0.0.1:9543
SANDBOX_ID=moca_microvm_0
SANDBOX_TOKEN=$ATTACH
SH_WORKSPACE_IDLE=8h
EOF
install -m 600 /dev/null ~/sbx-exec-client.token
echo "$CLIENT" > ~/sbx-exec-client.token
echo "- created $E/relay.env and $E/worker.env (root 600; fresh attach, exec and one client token, prefix sbx-exec-); ~/sbx-exec-client.token (600, hand-off)" >> "$M"

sudo install -d -m 755 /srv/sbx/workspaces /srv/sbx/jail
sudo install -m 644 "$D/deploy/microvm/microvm-vms.slice" "$U/microvm-vms.slice"
echo "- created /srv/sbx/workspaces, /srv/sbx/jail; installed $U/microvm-vms.slice (repo's, unchanged)" >> "$M"

sudo tee "$U/sbx-relay.service" > /dev/null <<EOF
[Unit]
Description=sbx gRPC backend: sandbox relay with client tokens (standalone from P6's sh-relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=harness
Group=harness
WorkingDirectory=$D/packages/sandbox-relay
EnvironmentFile=$E/relay.env
ExecStart=/usr/bin/node --import tsx src/main.ts
Restart=always
RestartSec=2
KillMode=control-group
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
# The repo's microvm-worker.service, with this backend's binary, paths and env file.
sed -e "s#^ExecStart=.*#ExecStart=/usr/local/bin/sbx-microvm-worker#" \
    -e "s#^Description=.*#Description=sbx gRPC backend: microvm-worker (standalone from P6)#" \
    -e "s#SH_SNAPSHOT_DIR=/srv/snapshots#SH_SNAPSHOT_DIR=/srv/sbx/snapshots#" \
    -e "s#SH_WORKSPACE_ROOT=/srv/workspaces#SH_WORKSPACE_ROOT=/srv/sbx/workspaces#" \
    -e "s#SH_CHROOT_BASE=/srv/jail#SH_CHROOT_BASE=/srv/sbx/jail#" \
    -e "s#^\[Install\]#EnvironmentFile=$E/worker.env\n\n[Install]#" \
    "$D/deploy/microvm/microvm-worker.service" | sudo tee "$U/sbx-microvm-worker.service" > /dev/null
echo "- installed $U/sbx-relay.service and $U/sbx-microvm-worker.service" >> "$M"

sudo systemctl daemon-reload
sudo systemctl enable --now sbx-relay.service sbx-microvm-worker.service 2>&1 | grep -v "Created symlink" || true
echo "- enabled and started sbx-relay, sbx-microvm-worker" >> "$M"
sleep 15
systemctl is-active sbx-relay sbx-microvm-worker
sudo journalctl -u sbx-relay -n 2 --no-pager -o cat
sudo journalctl -u sbx-microvm-worker -n 4 --no-pager -o cat
grep -E "^Environment(File)?=.*(SNAPSHOT_DIR|WORKSPACE_ROOT|CHROOT|worker.env)" "$U/sbx-microvm-worker.service"
```

### Phase 4: verify with the client token

```bash
#!/bin/bash
# Phase 4: verify the backend with the client token, from the rig itself (grpcurl).
set -uo pipefail
D=/opt/sbx-backend
TOK=$(cat ~/sbx-exec-client.token)
call() { # $1 workspace_key, $2 command, $3 token
  grpcurl -plaintext -max-time 60 -import-path "$D/proto" -proto sandbox/v1/sandbox.proto \
    -rpc-header "authorization: Bearer $3" \
    -d "{\"sandbox_id\":\"moca_microvm_0\",\"exec\":{\"req_id\":\"$RANDOM$RANDOM\",\"command\":\"$2\",\"timeout_s\":60,\"streaming\":true,\"workspace_key\":\"$1\"}}" \
    localhost:9544 sandbox.v1.SandboxExec/Exec 2>&1
}
decode() { grep -oE '"data": "[^"]*"|exitCode": -?[0-9]+|Code: [A-Za-z]+|Message: .*' | sed -E 's/"data": "([^"]*)"/\1/' |
  while read -r l; do if [[ $l == *Code* || $l == *Message* || $l == exitCode* ]]; then echo "  $l"; else echo "$l" | base64 -d | sed 's/^/  /'; fi; done; }

t=$(date +%s%N); echo "--- first exec (cold):"; call sbx-exec-check 'uname -r; nproc; python3 --version; git --version; echo persisted > /workspace/marker; ls /workspace' "$TOK" | decode
echo "  ($(( ($(date +%s%N) - t) / 1000000 )) ms)"
for i in 1 2 3; do t=$(date +%s%N); call sbx-exec-check 'cat /workspace/marker' "$TOK" > /dev/null; echo "--- warm exec $i: $(( ($(date +%s%N) - t) / 1000000 )) ms"; done
echo "--- second exec reads the marker:"; call sbx-exec-check 'cat /workspace/marker; ls /tmp' "$TOK" | decode
echo "--- outside the prefix:"; call other-ws 'true' "$TOK" | decode
echo "--- wrong token:"; call sbx-exec-check 'true' "$(openssl rand -hex 32)" | decode
echo "--- P6 untouched: $(systemctl is-active sh-relay sh-supervisor sh-control-plane | tr '\n' ' ')"
```

### Round 3 prerequisite: SWE-bench dependencies in the snapshot

```bash
#!/bin/bash
# SWE-bench subset deps baked into the sbx backend's snapshot. Logged to ~/sbx-backend-manifest.md.
set -euo pipefail
M=~/sbx-backend-manifest.md
D=/opt/sbx-backend
B=/srv/sbx/build
P="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin"
PKGS="mpmath==1.3.0 asgiref==3.7.2 typing_extensions==4.12.2 sqlparse==0.4.4 pytz==2024.1 tzdata==2024.1"

rm -rf /tmp/sbx-swe-deps
pip3 install -q --target /tmp/sbx-swe-deps --python-version 3.9 --only-binary=:all: --no-deps $PKGS
sudo cp -a /tmp/sbx-swe-deps/. "$B/rootfs/usr/lib/python3.9/site-packages/"
sudo chown -R root:root "$B/rootfs/usr/lib/python3.9/site-packages"
echo "- $(date -u +%FT%TZ) added to $B/rootfs/usr/lib/python3.9/site-packages (SWE-bench subset deps): $PKGS" >> "$M"
sudo chroot "$B/rootfs" /usr/bin/python3 -c "import mpmath, asgiref, sqlparse, pytz, tzdata, zoneinfo; zoneinfo.ZoneInfo('America/Chicago'); print('deps import ok in rootfs')"

sudo env "$P" bash "$D/deploy/microvm/build-snapshot.sh" --kernel "$(ls $B/vmlinux-*)" --rootfs "$B/rootfs" \
  --agent "$D/remote-worker" --image default --vmm firecracker --guest-ram-mb 256 \
  --out /srv/sbx/snapshots/default-swe > /tmp/sbx-snapshot-swe.log 2>&1 || { tail -30 /tmp/sbx-snapshot-swe.log; exit 1; }
sudo systemctl stop sbx-microvm-worker
sudo mv /srv/sbx/snapshots/default /srv/sbx/snapshots/default-v1
sudo mv /srv/sbx/snapshots/default-swe /srv/sbx/snapshots/default
sudo systemctl start sbx-microvm-worker
echo "- rebuilt snapshot with those deps: /srv/sbx/snapshots/default (previous kept as default-v1); restarted sbx-microvm-worker" >> "$M"
sleep 10
sudo journalctl -u sbx-microvm-worker -n 3 --no-pager -o cat
sudo cat /srv/sbx/snapshots/default/manifest.json | grep -E '"hash"|built_at'
```

### Round 3 prerequisite: `/workspace` on `sys.path` (editable-install stand-in)

```bash
#!/bin/bash
# /workspace importable in the guest, like SWE-bench's editable install. Logged to the manifest.
set -euo pipefail
M=~/sbx-backend-manifest.md
D=/opt/sbx-backend
B=/srv/sbx/build
P="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin"
echo /workspace | sudo tee "$B/rootfs/usr/lib/python3.9/site-packages/workspace.pth" > /dev/null
echo "- $(date -u +%FT%TZ) added $B/rootfs/usr/lib/python3.9/site-packages/workspace.pth (/workspace on sys.path, as an editable install)" >> "$M"
sudo env "$P" bash "$D/deploy/microvm/build-snapshot.sh" --kernel "$(ls $B/vmlinux-*)" --rootfs "$B/rootfs" \
  --agent "$D/remote-worker" --image default --vmm firecracker --guest-ram-mb 256 \
  --out /srv/sbx/snapshots/default-swe2 > /tmp/sbx-snapshot-swe2.log 2>&1 || { tail -30 /tmp/sbx-snapshot-swe2.log; exit 1; }
sudo systemctl stop sbx-microvm-worker
sudo rm -rf /srv/sbx/snapshots/default
sudo mv /srv/sbx/snapshots/default-swe2 /srv/sbx/snapshots/default
sudo systemctl start sbx-microvm-worker
echo "- rebuilt /srv/sbx/snapshots/default with it (the deps-only one replaced; default-v1 still kept); restarted sbx-microvm-worker" >> "$M"
sleep 10
sudo journalctl -u sbx-microvm-worker -n 1 --no-pager -o cat
```

## 2. Client: sbx CLI and configs (gRPC path)

`sandbox_v1_client.py`, which `sbx.py` imports, is committed at `$MOCA/docs/api/examples/sandbox_v1_client.py`; generate the stubs it needs with `python -m grpc_tools.protoc -I $MOCA/proto --python_out=/tmp/sbx-py --grpc_python_out=/tmp/sbx-py sandbox/v1/sandbox.proto`.

### `sbx.py`

```python
"""sbx: a command-line client for one sandbox/v1 workspace, built on sandbox_v1_client.py.

Meant for a coding agent whose shell tool is restricted to `sbx ...`: every command runs in a fresh
microVM over the workspace, and nothing runs on the local machine. See sandbox-v1-direct-client.md.

    sbx run [COMMAND...]      run COMMAND (or, with no arguments, the script on stdin) in /workspace
    sbx put PATH              write stdin to PATH in the workspace (parent directories created)
    sbx push [DIR]            replace /workspace with DIR's git working tree; commit it as the baseline
    sbx pull                  print every change since the push as a git patch

Environment: SBX_ADDR, SBX_SANDBOX_ID, SBX_WORKSPACE_KEY, and SBX_TOKEN or SBX_TOKEN_FILE.
Optional: SBX_TIMEOUT (seconds per command, default 600), SBX_LOG (append one JSON line per call).
`sbx run` exits with the command's own exit code; 124 means it timed out, 125 that the sandbox failed.
"""

import io
import json
import os
import subprocess
import sys
import tarfile
import time

from sandbox_v1_client import Sandbox

# The sandbox image has python3 and git but not tar/gzip, so the archive is extracted with tarfile.
PUSH = (
    "cd /workspace && find . -mindepth 1 -delete && "
    "python3 -W ignore -c 'import sys,tarfile; tarfile.open(fileobj=sys.stdin.buffer, mode=\"r|gz\").extractall(\".\")' && "
    "git init -q && "
    "printf '%s\\n' __pycache__/ '*.pyc' node_modules/ .venv/ venv/ .pytest_cache/ .mypy_cache/ > .git/info/exclude && "
    "git add -A && git -c user.name=sbx -c user.email=sbx@localhost commit -q --no-verify -m sbx-baseline && "
    "git ls-files | wc -l"
)
PULL = "cd /workspace && git add -A -N . && git diff --binary HEAD"


def sandbox() -> Sandbox:
    env = os.environ
    token = env.get("SBX_TOKEN") or open(env["SBX_TOKEN_FILE"]).read().strip()
    return Sandbox(env["SBX_ADDR"], env["SBX_SANDBOX_ID"], env["SBX_WORKSPACE_KEY"], token)


def log(op: str, started: float, code: int) -> None:
    if path := os.environ.get("SBX_LOG"):
        with open(path, "a") as f:
            rec = {"t": time.time(), "op": op, "ms": round((time.time() - started) * 1000), "exit": code}
            f.write(json.dumps(rec) + "\n")


def run(command: str, stdin: bytes = b"", op: str = "run") -> int:
    started = time.time()
    try:
        r = sandbox().exec(command, stdin=stdin, timeout_s=int(os.environ.get("SBX_TIMEOUT", "600")))
    except RuntimeError as e:
        msg = str(e)
        code = 124 if "timeout:" in msg else 125
        print(f"sbx: {'command timed out' if code == 124 else msg}", file=sys.stderr)
        log(op, started, code)
        return code
    sys.stdout.buffer.write(r.stdout)
    sys.stderr.buffer.write(r.stderr)
    if r.truncated:
        print("sbx: stdout exceeded 8 MiB and was cut", file=sys.stderr)
    code = r.exit_code if r.exit_code >= 0 else 128 + 9
    log(op, started, code)
    return code


def push(directory: str) -> int:
    files = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=directory, check=True, capture_output=True,
    ).stdout.split(b"\0")
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tar:
        for name in filter(None, files):
            path = os.path.join(directory, name.decode())
            if os.path.lexists(path):  # tracked but deleted locally: skip
                tar.add(path, arcname=name.decode(), recursive=False)
    data = buf.getvalue()
    if len(data) > 12 << 20:
        print(f"sbx: tree is {len(data) >> 20} MiB compressed; the limit is 12", file=sys.stderr)
        return 1
    return run(PUSH, stdin=data, op="push")


def main(argv: list) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0 if argv else 2
    cmd, args = argv[0], argv[1:]
    if cmd == "run":
        return run(" ".join(args) if args else sys.stdin.read())
    if cmd == "put" and len(args) == 1:
        q = "'" + args[0].replace("'", "'\\''") + "'"
        return run(f'mkdir -p "$(dirname -- {q})" && cat > {q}', stdin=sys.stdin.buffer.read(), op="put")
    if cmd == "push":
        return push(args[0] if args else ".")
    if cmd == "pull":
        return run(PULL, op="pull")
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
```

### `sbx` wrapper

```sh
#!/bin/sh
# /tmp/sbx-bin/sbx -- puts the sandbox/v1 stubs and the example client on the path.
PYTHONPATH=/tmp/sbx-py:$MOCA/docs/api/examples exec /tmp/sbx-venv/bin/python $MOCA/docs/api/examples/sbx.py "$@"
```

### `AGENTS.md` / `CLAUDE.md` (identical)

Copied into the project root for both agents.

```markdown
# Working in the MOCA sandbox

This project's code lives in a remote sandbox, not on this machine. Your shell tool may run only the
sandbox client, `sbx`; every other command, and every other file tool, is denied. In the sandbox the
working directory is `/workspace`.

- Run a bash script in the sandbox (to read, search, edit, or run tests):

      sbx run <<'EOF'
      cat calc.py
      python3 -m unittest
      EOF

- Write a whole file:

      sbx put path/to/file.py <<'EOF'
      ...contents...
      EOF

- Every `sbx` call runs in a fresh VM. No process survives between calls: never start a server,
  watcher or background job expecting it to be there on the next call.
- Files under `/workspace` persist between calls. Nothing else does.
- The sandbox has no network access: package installs will fail.
- One command runs at a time. Batch work: several reads, or an edit plus its test run, in one call.
- `sbx run` exits with the script's own exit code.
```

### OpenCode `opencode.json` (gRPC path)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "tools": {
    "read": false,
    "edit": false,
    "write": false,
    "patch": false,
    "glob": false,
    "grep": false,
    "list": false,
    "lsp": false,
    "webfetch": false,
    "websearch": false,
    "task": false
  },
  "permission": {
    "bash": { "*": "deny", "sbx run*": "allow", "sbx put *": "allow" },
    "read": "deny",
    "edit": "deny",
    "glob": "deny",
    "grep": "deny",
    "lsp": "deny",
    "webfetch": "deny",
    "websearch": "deny",
    "task": "deny",
    "external_directory": "deny"
  }
}
```

### OpenCode provider config (`OPENCODE_CONFIG`)

Merged with the project `opencode.json`; replace `<LITELLM_BASE_URL>`.

```json
{
  "$schema": "https://opencode.ai/config.json",
  "provider": {
    "litellm": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "LiteLLM",
      "options": { "baseURL": "<LITELLM_BASE_URL>/v1", "apiKey": "{env:LITELLM_KEY}" },
      "models": { "aws/claude-sonnet-5-5": { "name": "Claude Sonnet 5.5" } }
    }
  },
  "model": "litellm/aws/claude-sonnet-5-5"
}
```

### Claude Code (gRPC path): flags, not a settings file

A project `.claude/settings.json` `permissions.allow` is ignored until the folder has been trusted
interactively, so the headless runs pass everything as flags:

```sh
claude -p "$PROMPT" --model aws/claude-sonnet-5-5 --setting-sources project --strict-mcp-config \
  --allowedTools 'Bash(sbx run:*)' 'Bash(sbx put:*)' \
  --disallowedTools Read Edit Write Glob Grep NotebookEdit WebFetch WebSearch Agent Task EnterWorktree ExitWorktree Workflow \
  --output-format stream-json --verbose < /dev/null
```

Round 3 dropped `Agent Task` from the deny list (subagents allowed in both modes; they inherit the
same restrictions). `< /dev/null` matters: without closed stdin OpenCode hangs headless.

## 3. Client: MCP server and configs (MCP path)

An npm workspace package in the main repo (`packages/sandbox-mcp`, branch `spike/sandbox-mcp`, not pushed). It also needs two lines added to `packages/k8s-sandbox/src/index.ts` exporting `createPod{Bash,Edit,Find,Ls,Read,Write}Ops` from `./operations.js` and `createPodGrepTool` from `./grep-tool.js`.

### `packages/sandbox-mcp/package.json`

```json
{
  "name": "@moca/sandbox-mcp",
  "type": "module",
  "version": "0.0.0",
  "private": true,
  "description": "SPIKE: Pi's seven tools served over MCP against a sandbox relay (docs/moca 2026-10-09 prototype plan)",
  "exports": {
    ".": "./src/index.ts"
  },
  "scripts": {
    "start": "node --import tsx src/main.ts",
    "test": "vitest run",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "@earendil-works/pi-coding-agent": "link:../../pi-fork/packages/coding-agent",
    "@grpc/grpc-js": "^1.14.5",
    "@moca/k8s-sandbox": "workspace:*",
    "@modelcontextprotocol/sdk": "^1.32.1"
  },
  "devDependencies": {
    "@types/node": "^22.0.0",
    "tsx": "^4.23.15",
    "typescript": "^5.5.0",
    "vitest": "^2.0.0"
  }
}
```

### `packages/sandbox-mcp/src/main.ts`

```ts
import { createServer } from 'node:http';
import { credentials, InterceptingCall, type Interceptor } from '@grpc/grpc-js';
import { GrpcRelayTransport, SandboxExecClient, type ExecClientLike } from '@moca/k8s-sandbox';
import { createHandler } from './server.js';

function required(name: string): string {
  const v = process.env[name];
  if (!v) {
    console.error(`${name} is required`);
    process.exit(2);
  }
  return v;
}

const relayAddr = required('SH_RELAY_ADDR');
const token = required('MOCA_RELAY_EXEC_TOKEN');
const sandboxId = required('SBX_SANDBOX_ID');
// microvm-worker refuses an empty key; the container worker ignores it.
const workspaceKey = process.env.SBX_WORKSPACE_KEY ?? '';
// Loopback by default: the only way in is an SSH tunnel (prototype plan, "Corners cut").
const host = process.env.SBX_HOST ?? '127.0.0.1';
const port = Number(process.env.SBX_PORT ?? '8787');

const bearer: Interceptor = (options, nextCall) =>
  new InterceptingCall(nextCall(options), {
    start(metadata, listener, next) {
      metadata.set('authorization', `Bearer ${token}`);
      next(metadata, listener);
    },
  });

const client = new SandboxExecClient(relayAddr, credentials.createInsecure(), {
  interceptors: [bearer],
}) as unknown as ExecClientLike;
const transport = GrpcRelayTransport(sandboxId, client, { workspaceKey });

const handler = createHandler(transport.exec, (rec) =>
  console.log(JSON.stringify({ t: new Date().toISOString(), ...rec })),
);

createServer((req, res) => void handler(req, res)).listen(port, host, () => {
  console.error(
    `sandbox-mcp listening on http://${host}:${port}/mcp -> ${relayAddr} sandbox=${sandboxId} workspace=${workspaceKey || '(shared)'}`,
  );
});
```

### `packages/sandbox-mcp/src/server.ts`

```ts
import type { IncomingMessage, ServerResponse } from 'node:http';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  type CallToolResult,
} from '@modelcontextprotocol/sdk/types.js';
import type { ExecInPod } from '@moca/k8s-sandbox';
import { buildTools, WORKSPACE } from './tools.js';

/** One line per tool call or transfer: the measurement this spike exists for. */
export interface CallRecord {
  op: string;
  ms: number;
  execs: number;
  ok: boolean;
  error?: string;
}

export type Logger = (rec: CallRecord) => void;

/** Wraps the exec seam so one tool call can count the Execs (VMs, on the microVM tier) it made. */
function counted(exec: ExecInPod): { exec: ExecInPod; count: () => number } {
  let n = 0;
  return {
    exec: (command, opts) => {
      n++;
      return exec(command, opts);
    },
    count: () => n,
  };
}

/** Tool schemas never depend on the exec seam, so list them once from a seam that is never called. */
const neverExec: ExecInPod = () => Promise.reject(new Error('unreachable'));

export function createMcpServer(exec: ExecInPod, log: Logger): Server {
  const server = new Server(
    { name: 'moca-sandbox', version: '0.0.0-spike' },
    {
      capabilities: { tools: {} },
      instructions:
        `Every tool runs in a remote sandbox whose working directory is ${WORKSPACE}. ` +
        'Each call runs in a fresh VM: no process survives between calls, so never start ' +
        'background jobs or servers expecting them to keep running. Files under ' +
        `${WORKSPACE} persist. The sandbox has no network access.`,
    },
  );

  server.setRequestHandler(ListToolsRequestSchema, async () => ({
    tools: buildTools(neverExec).map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.parameters as { type: 'object' },
    })),
  }));

  server.setRequestHandler(CallToolRequestSchema, async (req, extra): Promise<CallToolResult> => {
    const c = counted(exec);
    const tool = buildTools(c.exec).find((t) => t.name === req.params.name);
    if (!tool) {
      return {
        isError: true,
        content: [{ type: 'text', text: `unknown tool: ${req.params.name}` }],
      };
    }
    const started = Date.now();
    try {
      const r = await tool.execute(
        `mcp-${String(extra.requestId)}`,
        (req.params.arguments ?? {}) as Record<string, unknown>,
        extra.signal,
      );
      log({ op: tool.name, ms: Date.now() - started, execs: c.count(), ok: true });
      return { content: r.content as CallToolResult['content'] };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      log({ op: tool.name, ms: Date.now() - started, execs: c.count(), ok: false, error: message });
      return { isError: true, content: [{ type: 'text', text: message }] };
    }
  });

  return server;
}

/** Push replaces the workspace with a gzipped tar and commits it as the baseline that pull diffs. */
export const PUSH_COMMAND =
  `cd ${WORKSPACE} && find . -mindepth 1 -delete && ` +
  // The sandbox runtime image ships python3 and git but not tar/gzip.
  `if command -v tar >/dev/null && command -v gzip >/dev/null; then tar -xzf - ; else ` +
  `python3 -c 'import sys,tarfile; tarfile.open(fileobj=sys.stdin.buffer, mode="r|gz").extractall(".")'; fi && ` +
  `git init -q && ` +
  // Build output a repo forgot to .gitignore must not come back in the pull patch (SBX1 O12).
  `printf '%s\\n' __pycache__/ '*.pyc' node_modules/ .venv/ venv/ .pytest_cache/ .mypy_cache/ > .git/info/exclude && ` +
  `git add -A && ` +
  `git -c user.name=sbx -c user.email=sbx@localhost commit -q --no-verify -m sbx-baseline && ` +
  `git rev-parse --short HEAD && git ls-files | wc -l`;

/** Pull is every change since the baseline, untracked (non-ignored) files included. */
export const PULL_COMMAND = `cd ${WORKSPACE} && git add -A -N . && git diff --binary HEAD`;

/** The Exec message ceiling is 16 MiB; leave room for framing. */
export const MAX_PUSH_BYTES = 12 * 1024 * 1024;

async function readBody(req: IncomingMessage, limit: number): Promise<Buffer | null> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > limit) return null;
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks);
}

function reply(res: ServerResponse, status: number, body: string | Buffer): void {
  res.writeHead(status, { 'content-type': 'text/plain; charset=utf-8' });
  res.end(body);
}

/** /mcp (stateless streamable HTTP), plus /push and /pull for the laptop scripts. */
export function createHandler(exec: ExecInPod, log: Logger) {
  return async (req: IncomingMessage, res: ServerResponse): Promise<void> => {
    const path = (req.url ?? '/').split('?')[0];
    try {
      if (path === '/mcp') {
        // Stateless: a fresh server and transport per request, so nothing is shared between clients.
        const server = createMcpServer(exec, log);
        const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined });
        res.on('close', () => {
          void transport.close();
          void server.close();
        });
        await server.connect(transport);
        await transport.handleRequest(req, res);
        return;
      }
      if (path === '/push' && req.method === 'POST') {
        const body = await readBody(req, MAX_PUSH_BYTES);
        if (!body) return reply(res, 413, `push exceeds ${MAX_PUSH_BYTES} bytes compressed\n`);
        return await transfer(res, log, 'push', () => exec(PUSH_COMMAND, { stdin: body }));
      }
      if (path === '/pull' && req.method === 'GET') {
        return await transfer(res, log, 'pull', () => exec(PULL_COMMAND));
      }
      if (path === '/healthz') return reply(res, 200, 'ok\n');
      reply(res, 404, 'not found\n');
    } catch (err) {
      if (!res.headersSent)
        reply(res, 500, `${err instanceof Error ? err.message : String(err)}\n`);
    }
  };
}

async function transfer(
  res: ServerResponse,
  log: Logger,
  op: string,
  run: () => ReturnType<ExecInPod>,
): Promise<void> {
  const started = Date.now();
  const r = await run();
  const ok = r.exitCode === 0 && !r.truncated;
  log({
    op,
    ms: Date.now() - started,
    execs: 1,
    ok,
    ...(ok ? {} : { error: `exit ${r.exitCode}` }),
  });
  if (ok) return reply(res, 200, r.stdout);
  reply(
    res,
    502,
    `${op} failed in the sandbox (exit ${r.exitCode}${r.truncated ? ', truncated' : ''})\n`,
  );
}
```

### `packages/sandbox-mcp/src/tools.ts`

```ts
import { posix } from 'node:path';
import {
  createBashTool,
  createEditTool,
  createFindTool,
  createLsTool,
  createReadTool,
  createWriteTool,
} from '@earendil-works/pi-coding-agent';
import {
  createPodBashOps,
  createPodEditOps,
  createPodFindOps,
  createPodGrepTool,
  createPodReadOps,
  type ExecInPod,
  type K8sSandboxConfig,
} from '@moca/k8s-sandbox';
import { editOps, findOps, lsOps, readOps, writeOps } from './fewer-execs.js';

/** The sandbox's working directory: the workspace every worker tier mounts (guest-agent -workdir). */
export const WORKSPACE = '/workspace';

/** The slice of a Pi AgentTool the MCP server needs. */
export interface ServedTool {
  name: string;
  description: string;
  parameters: unknown;
  execute(
    id: string,
    params: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<{ content: Array<{ type: string; text?: string; data?: string; mimeType?: string }> }>;
}

/**
 * Pi's seven tools, built exactly as k8sSandboxExtension builds them, over one exec seam. Head
 * and pod cwd are both /workspace, so path mapping is the identity and the model sees the
 * sandbox's real paths.
 */
export function buildTools(exec: ExecInPod): ServedTool[] {
  const cfg: K8sSandboxConfig = {
    pod: 'sandbox',
    namespace: '',
    context: undefined,
    podCwd: WORKSPACE,
    headCwd: WORKSPACE,
  };
  const searchExec = skipGitDir(exec);
  const podFind = findOps(createPodFindOps(searchExec, cfg));
  return [
    createReadTool(WORKSPACE, { operations: readOps(createPodReadOps(exec, cfg)) }),
    createWriteTool(WORKSPACE, { operations: writeOps(exec) }),
    createEditTool(WORKSPACE, { operations: editOps(createPodEditOps(exec, cfg)) }),
    createLsTool(WORKSPACE, { operations: lsOps(exec) }),
    createFindTool(WORKSPACE, {
      operations: {
        ...podFind,
        // Pi relativizes glob results with path.relative, which resolves a relative path against
        // the PROCESS cwd. MOCA's harness runs with process cwd == headCwd, so it never shows;
        // here the process cwd is not /workspace, so hand Pi absolute paths.
        glob: async (pattern, cwd, opts) =>
          (await podFind.glob(pattern, cwd, opts)).map((p) => posix.join(cwd, p)),
      },
    }),
    createBashTool(WORKSPACE, { operations: createPodBashOps(exec, cfg) }),
    createPodGrepTool(WORKSPACE, searchExec, cfg),
  ] as unknown as ServedTool[];
}

/**
 * The pod tools' rg runs with --hidden, which also walks .git. MOCA's pod workspaces rarely hold
 * one; this sandbox always does (sbx-push commits a baseline), so keep search out of it.
 */
function skipGitDir(exec: ExecInPod): ExecInPod {
  return (command, opts) =>
    exec(command.replace(/\brg (--files|--line-number) /, "rg $1 --glob '!.git' "), opts);
}
```

### `packages/sandbox-mcp/src/fewer-execs.ts`

```ts
import { posix } from 'node:path';
import type {
  EditOperations,
  FindOperations,
  LsOperations,
  ReadOperations,
  WriteOperations,
} from '@earendil-works/pi-coding-agent';
import type { ExecInPod } from '@moca/k8s-sandbox';

/**
 * On the microVM tier every Exec is a fresh VM (~150 ms on the rig), so the probes Pi's tools make
 * before the real work dominate. Measured on the rig, 2026-10-09: read 3 Execs, edit 3, write 2,
 * find 2, ls 3 + one per entry. These wrappers make each one Exec (edit two: read, then write).
 * The pod ops stay the source of the real work; only the probes are dropped or merged.
 */

const shQuote = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

const IMAGE_EXT: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
};

/** A failing cat already reports a missing or unreadable file, so the access probe goes. */
const noAccessProbe = async () => {};

export function readOps(pod: ReadOperations): ReadOperations {
  return {
    ...pod,
    access: noAccessProbe,
    detectImageMimeType: async (p) => IMAGE_EXT[posix.extname(p).toLowerCase()] ?? null,
  };
}

export function editOps(pod: EditOperations): EditOperations {
  return { ...pod, access: noAccessProbe };
}

/** mkdir -p folded into the write itself. */
export function writeOps(exec: ExecInPod): WriteOperations {
  return {
    mkdir: async () => {},
    writeFile: async (p, content) => {
      const b64 = Buffer.from(content).toString('base64');
      const r = await exec(`mkdir -p ${shQuote(posix.dirname(p))} && base64 -d > ${shQuote(p)}`, {
        stdin: Buffer.from(b64),
      });
      if (r.exitCode !== 0) throw new Error(`Write failed in the sandbox: ${p}`);
    },
  };
}

/** The glob's own `cd` fails on a missing path, so the exists probe goes. */
export function findOps(pod: FindOperations): FindOperations {
  return { ...pod, exists: async () => true };
}

/**
 * One listing answers all of Pi's ls calls: exists(dir), stat(dir), readdir(dir) and a stat per
 * entry. `ls -p` marks directories with a trailing slash.
 */
export function lsOps(exec: ExecInPod): LsOperations {
  const listings = new Map<
    string,
    Promise<{ kind: 'D' | 'F' | 'N'; entries: Map<string, boolean> }>
  >();
  const list = (dir: string) => {
    let got = listings.get(dir);
    if (!got) {
      const q = shQuote(dir);
      got = exec(
        `if [ -d ${q} ]; then echo D; ls -1Ap -- ${q}; elif [ -e ${q} ]; then echo F; else echo N; fi`,
      ).then((r) => {
        if (r.truncated) throw new Error(`listing exceeds the sandbox output cap: ${dir}`);
        if (r.exitCode !== 0)
          throw new Error(`ls failed in the sandbox (exit ${r.exitCode}): ${dir}`);
        const [kind, ...lines] = r.stdout
          .toString()
          .split('\n')
          .filter((l) => l.length > 0);
        const entries = new Map(lines.map((l) => [l.replace(/\/$/, ''), l.endsWith('/')]));
        return { kind: kind as 'D' | 'F' | 'N', entries };
      });
      listings.set(dir, got);
    }
    return got;
  };
  return {
    exists: async (p) => (await list(p)).kind !== 'N',
    stat: async (p) => {
      const parent = listings.get(posix.dirname(p));
      if (parent) {
        const isDir = (await parent).entries.get(posix.basename(p));
        if (isDir !== undefined) return { isDirectory: () => isDir };
      }
      const { kind } = await list(p);
      if (kind === 'N') throw new Error(`Path not found in the sandbox: ${p}`);
      return { isDirectory: () => kind === 'D' };
    },
    readdir: async (p) => [...(await list(p)).entries.keys()],
  };
}
```

### `packages/sandbox-mcp/test/server.test.ts`

```ts
import { execFile, spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { createServer, type Server as HttpServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { promisify } from 'node:util';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';
import type { ExecInPod } from '@moca/k8s-sandbox';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { createHandler, type CallRecord } from '../src/server.js';

/** A local stand-in for the relay: `bash -c` with /workspace rewritten to a temp dir. */
function localExec(root: string): ExecInPod {
  return (command, opts = {}) =>
    new Promise((resolve, reject) => {
      const p = spawn('bash', ['-c', command.replaceAll('/workspace', root)], { cwd: root });
      const out: Buffer[] = [];
      p.stdout.on('data', (b: Buffer) => {
        out.push(b);
        opts.onData?.(b);
      });
      p.stderr.on('data', (b: Buffer) => opts.onData?.(b));
      p.on('error', reject);
      p.on('close', (code) =>
        resolve({ stdout: Buffer.concat(out), exitCode: code, truncated: false }),
      );
      p.stdin.end(opts.stdin ?? Buffer.alloc(0));
    });
}

let root: string;
let http: HttpServer;
let base: string;
let client: Client;
const records: CallRecord[] = [];

beforeAll(async () => {
  root = mkdtempSync(join(tmpdir(), 'sbx-mcp-'));
  http = createServer(createHandler(localExec(root), (r) => records.push(r)));
  await new Promise<void>((r) => http.listen(0, '127.0.0.1', r));
  const addr = http.address();
  base = `http://127.0.0.1:${typeof addr === 'object' && addr ? addr.port : 0}`;
  client = new Client({ name: 'test', version: '0' });
  await client.connect(new StreamableHTTPClientTransport(new URL(`${base}/mcp`)));
});

afterAll(async () => {
  await client?.close();
  http?.close();
  rmSync(root, { recursive: true, force: true });
});

const text = (r: Awaited<ReturnType<Client['callTool']>>) =>
  (r.content as Array<{ text?: string }>).map((c) => c.text ?? '').join('');

describe('sandbox-mcp', () => {
  it('lists Pi’s seven tools with their schemas', async () => {
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual([
      'bash',
      'edit',
      'find',
      'grep',
      'ls',
      'read',
      'write',
    ]);
    expect(tools.find((t) => t.name === 'read')?.inputSchema.properties).toHaveProperty('path');
  });

  it('pushes a tree, works on it through the tools, and pulls a patch', async () => {
    const src = mkdtempSync(join(tmpdir(), 'sbx-src-'));
    await promisify(execFile)('bash', [
      '-c',
      `cd ${src} && printf 'hello world\\n' > a.txt && mkdir sub && printf 'needle\\n' > sub/b.txt`,
    ]);
    const tgz = (
      await promisify(execFile)('tar', ['-czf', '-', '-C', src, '.'], {
        encoding: 'buffer',
      })
    ).stdout as Buffer;
    const push = await fetch(`${base}/push`, { method: 'POST', body: new Uint8Array(tgz) });
    expect(push.status, await push.clone().text()).toBe(200);

    expect(text(await client.callTool({ name: 'read', arguments: { path: 'a.txt' } }))).toContain(
      'hello world',
    );
    const edit = await client.callTool({
      name: 'edit',
      arguments: { path: 'a.txt', edits: [{ oldText: 'world', newText: 'sandbox' }] },
    });
    expect(edit.isError, text(edit)).toBeFalsy();
    await client.callTool({ name: 'write', arguments: { path: 'new.txt', content: 'fresh\n' } });
    expect(
      text(await client.callTool({ name: 'grep', arguments: { pattern: 'needle' } })),
    ).toContain('sub/b.txt');
    expect(
      text(await client.callTool({ name: 'find', arguments: { pattern: '*.txt' } })),
    ).toContain('new.txt');
    expect(text(await client.callTool({ name: 'ls', arguments: {} }))).toContain('sub/');
    expect(text(await client.callTool({ name: 'bash', arguments: { command: 'pwd' } }))).toContain(
      root,
    );

    await client.callTool({
      name: 'bash',
      arguments: { command: 'mkdir -p __pycache__ && echo x > __pycache__/m.pyc' },
    });
    const patch = await (await fetch(`${base}/pull`)).text();
    expect(patch).toContain('+hello sandbox');
    expect(patch).toContain('new.txt');
    expect(patch).not.toContain('__pycache__');
    rmSync(src, { recursive: true, force: true });
  });

  it('returns a failing command as a tool error, not a transport error', async () => {
    const r = await client.callTool({ name: 'bash', arguments: { command: 'exit 3' } });
    expect(r.isError).toBe(true);
    expect(text(r)).toMatch(/code 3/);
  });

  it('spends one Exec (one VM on the microVM tier) per call, two for edit', () => {
    const execs = (op: string) => records.find((r) => r.op === op && r.ok)?.execs;
    expect({
      read: execs('read'),
      write: execs('write'),
      edit: execs('edit'),
      ls: execs('ls'),
      find: execs('find'),
      grep: execs('grep'),
      bash: execs('bash'),
    }).toEqual({ read: 1, write: 1, edit: 2, ls: 1, find: 1, grep: 1, bash: 1 });
  });

  it('writes into a directory that does not exist yet, and ls marks directories', async () => {
    const w = await client.callTool({
      name: 'write',
      arguments: { path: 'deep/er/f.txt', content: 'x\n' },
    });
    expect(w.isError, text(w)).toBeFalsy();
    expect(text(await client.callTool({ name: 'ls', arguments: { path: 'deep' } }))).toContain(
      'er/',
    );
    const missing = await client.callTool({ name: 'ls', arguments: { path: 'nope' } });
    expect(missing.isError).toBe(true);
  });

  it('reports a missing file as a tool error', async () => {
    const r = await client.callTool({ name: 'read', arguments: { path: 'nope.txt' } });
    expect(r.isError).toBe(true);
  });
});
```

### `demo/sbx-push.sh`

```sh
#!/bin/sh
# SPIKE: replace the sandbox's /workspace with this repo's working tree (tracked + untracked,
# minus .gitignore'd files and .git). The sandbox commits it as the baseline sbx-pull.sh diffs.
set -eu
SBX_URL="${SBX_URL:-http://localhost:8787}"
cd "$(git rev-parse --show-toplevel)"
git ls-files -z --cached --others --exclude-standard \
  | COPYFILE_DISABLE=1 tar `# macOS tar: no ._ AppleDouble files` \
 --null -T - -czf - \
  | curl -fsS --data-binary @- -H 'content-type: application/gzip' "$SBX_URL/push" \
  | { read -r rev; read -r files; echo "pushed $files files (sandbox baseline $rev)"; }
```

### `demo/sbx-pull.sh`

```sh
#!/bin/sh
# SPIKE: fetch every change made in the sandbox since the last push, as a git patch.
# Writes .sbx.patch; with --apply, also applies it to this working tree.
set -eu
SBX_URL="${SBX_URL:-http://localhost:8787}"
cd "$(git rev-parse --show-toplevel)"
curl -fsS "$SBX_URL/pull" > .sbx.patch
if [ ! -s .sbx.patch ]; then echo "no changes in the sandbox"; rm -f .sbx.patch; exit 0; fi
git apply --stat .sbx.patch
if [ "${1:-}" = "--apply" ]; then git apply .sbx.patch && rm .sbx.patch && echo "applied"; else echo "wrote .sbx.patch (re-run with --apply to apply it)"; fi
```

### OpenCode `opencode.json` (MCP path)

```json
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "sandbox": {
      "type": "remote",
      "url": "http://localhost:8787/mcp",
      "oauth": false,
      "enabled": true
    }
  },
  "tools": {
    "bash": false,
    "read": false,
    "edit": false,
    "write": false,
    "patch": false,
    "glob": false,
    "grep": false,
    "list": false,
    "lsp": false,
    "webfetch": false,
    "websearch": false,
    "task": false
  },
  "permission": {
    "bash": "deny",
    "read": "deny",
    "edit": "deny",
    "glob": "deny",
    "grep": "deny",
    "lsp": "deny",
    "webfetch": "deny",
    "websearch": "deny",
    "task": "deny",
    "external_directory": "deny"
  }
}
```

### Claude Code `.mcp.json` (MCP path)

```json
{
  "mcpServers": {
    "sandbox": {
      "type": "http",
      "url": "http://localhost:8787/mcp"
    }
  }
}
```

### Claude Code `.claude/settings.json` (MCP path)

```json
{
  "permissions": {
    "allow": [
      "mcp__sandbox__*"
    ],
    "deny": [
      "Bash",
      "Read",
      "Edit",
      "Write",
      "Glob",
      "Grep",
      "NotebookEdit",
      "WebFetch",
      "WebSearch",
      "Agent",
      "Task",
      "EnterWorktree",
      "ExitWorktree",
      "Workflow"
    ]
  }
}
```

### `AGENTS.md` (MCP path; `CLAUDE.md` names the tools `mcp__sandbox__*`)

```markdown
# Working in the MOCA sandbox

This project's code lives in a remote sandbox, not on this machine. Use only the `sandbox_*`
tools; the working directory is `/workspace`.

- Every tool call runs in a fresh VM. No process survives between calls: never start a server,
  watcher or background job expecting it to be there on the next call.
- Files under `/workspace` persist between calls. Nothing else does.
- The sandbox has no network access: package installs and `git push` will fail.
- One command runs at a time. Prefer one `bash` call per test run over many small ones, and keep
  long commands to what you need.
```

### `demo/compose.override.yml` (local dev loop only)

```yaml
# SPIKE, local dev only: publish the relay's SandboxExec listener on host loopback so a
# sandbox-mcp process on the host can dial it. Binding 0.0.0.0 also exposes it on moca-sandbox;
# the sandbox does not hold MOCA_RELAY_EXEC_TOKEN, and this file is never used on the rig.
services:
  sandbox-relay:
    environment:
      MOCA_RELAY_EXEC_ADDR: 0.0.0.0:9444
    ports:
      - '127.0.0.1:9444:9444'
```

## 4. Rounds 1–2 runners

### MCP path runner (`sbx-run.sh`)

```bash
#!/bin/bash
# Throwaway: one agent run against the rig sandbox. Usage: sbx-run.sh <oc|cc> <repo> <name> <prompt>
set -u
agent=$1 repo=$2 name=$3 prompt=$4
D=$MOCA/packages/sandbox-mcp/demo
L=/tmp/kagenti/tdd/moca/cmp; mkdir -p $L
RIG="ssh $AWS_SSH_OPTS -o LogLevel=ERROR $AWS_RIG"
KEY=${LITELLM_KEY:?}
BASE=${LITELLM_BASE_URL:?}
cd $repo && git checkout -q -- . && git clean -qfdx
cp $D/opencode.json $D/AGENTS.md $D/CLAUDE.md $D/.mcp.json . && mkdir -p .claude && cp $D/claude/settings.json .claude/
$D/sbx-push.sh >/dev/null
start=$($RIG 'wc -l < ~/sbx-mcp.log' 2>/dev/null)
S=$(date +%s.%N)
if [ $agent = oc ]; then
  LITELLM_KEY=$KEY OPENCODE_CONFIG=/tmp/sbx-oc-provider.json timeout 900 npx -y opencode-ai@latest run --format json "$prompt" < /dev/null > $L/$name.agent.log 2>&1
else
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT ANTHROPIC_BASE_URL=$BASE ANTHROPIC_AUTH_TOKEN=$KEY timeout 900 claude -p "$prompt" \
    --model aws/claude-sonnet-5-5 --setting-sources project --strict-mcp-config --mcp-config .mcp.json \
    --output-format stream-json --verbose < /dev/null > $L/$name.agent.log 2>&1
fi
rc=$?
E=$(date +%s.%N)
$RIG "tail -n +$((start+1)) ~/sbx-mcp.log | grep '^{'" > $L/$name.calls.jsonl 2>/dev/null
$D/sbx-pull.sh > /dev/null 2>&1; [ -f .sbx.patch ] && cp .sbx.patch $L/$name.patch || : > $L/$name.patch
printf '%s rc=%s wall=%.1fs calls=%s\n' $name $rc $(echo "$E - $S" | bc) $(wc -l < $L/$name.calls.jsonl)
```

### gRPC path runner (`sbx-grpc-run.sh`)

```bash
#!/bin/bash
# Throwaway: one agent run against the BM rig over sandbox/v1 (sbx CLI, no MCP).
# Usage: sbx-grpc-run.sh <oc|cc> <repo> <name> <prompt>
set -u
agent=$1 repo=$2 name=$3 prompt=$4
C=/tmp/sbx-grpc-cfg
L=/tmp/kagenti/tdd/moca/grpc; mkdir -p $L
KEY=${LITELLM_KEY:?}
BASE=${LITELLM_BASE_URL:?}
export PATH=/tmp/sbx-bin:$PATH SBX_ADDR=localhost:9444 SBX_SANDBOX_ID=moca_microvm_0 \
  SBX_TOKEN_FILE=/tmp/sbx-exec.token SBX_WORKSPACE_KEY=sbx-exec-$name SBX_LOG=$L/$name.calls.jsonl
rm -f $SBX_LOG
cd $repo && git checkout -q -- . && git clean -qfdx
cp $C/AGENTS.md $C/CLAUDE.md . && [ $agent = oc ] && cp $C/opencode.json .
sbx push > /dev/null || { echo "$name: push failed"; exit 1; }
S=$(date +%s.%N)
if [ $agent = oc ]; then
  LITELLM_KEY=$KEY OPENCODE_CONFIG=/tmp/sbx-oc-provider.json timeout 2400 \
    npx -y opencode-ai@latest run --format json "$prompt" < /dev/null > $L/$name.agent.log 2>&1
else
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT ANTHROPIC_BASE_URL=$BASE ANTHROPIC_AUTH_TOKEN=$KEY timeout 2400 \
    claude -p "$prompt" --model aws/claude-sonnet-5-5 --setting-sources project --strict-mcp-config \
    --allowedTools 'Bash(sbx run:*)' 'Bash(sbx put:*)' \
    --disallowedTools Read Edit Write Glob Grep NotebookEdit WebFetch WebSearch Agent Task EnterWorktree ExitWorktree Workflow \
    --output-format stream-json --verbose < /dev/null > $L/$name.agent.log 2>&1
fi
rc=$?
E=$(date +%s.%N)
sbx pull > $L/$name.patch 2> /dev/null
printf '%s rc=%s wall=%.1fs sbx-calls=%s\n' $name $rc $(echo "$E - $S" | bc) $(grep -cv '"op": "p[ul][sl]' $SBX_LOG)
```

### Round 2 prompt

```text
Add a new built-in extension to Python-Markdown: `strikethrough`, which renders `~~text~~` as `<del>text</del>`. Follow the conventions of the existing built-in extensions: the implementation in markdown/extensions/, registered like the others so that `markdown.markdown(text, extensions=['strikethrough'])` works, tests in the existing test style under tests/, and a docs page in docs/extensions/ linked from the extensions index. Handle edge cases sensibly: for example, `~~` inside a code span must not be converted, and a single `~` is left alone. Run the full test suite (python3 -m unittest discover tests) at the end. Known pre-existing failures unrelated to this task: test_apis (needs PyYAML, which is not installed) and 8 tests in test_html_blocks / test_md_in_html (Python 3.9 html.parser differences). Do not try to fix those.
```

### Round 2 test-environment shim (committed in the Markdown checkout before the baseline)

```python
"""Test-environment shim, not part of Markdown.

The MOCA sandbox runs Python 3.9 with no network, so the importlib_metadata backport that Markdown
needs below Python 3.10 cannot be installed. Entry points are read from pyproject.toml on every
call, as an editable install would expose them.
"""
import re
from importlib.metadata import EntryPoint, PackageNotFoundError, version  # noqa: F401
from pathlib import Path

_SECTION = re.compile(r"^\[project\.entry-points\.'([^']+)'\]\n(.*?)(?=^\[|\Z)", re.M | re.S)
_ENTRY = re.compile(r"^([\w-]+)\s*=\s*['\"]([^'\"]+)['\"]", re.M)


def entry_points(group=None):
    text = (Path(__file__).parent / 'pyproject.toml').read_text()
    eps = [
        EntryPoint(name=name, value=value, group=g)
        for g, body in _SECTION.findall(text)
        for name, value in _ENTRY.findall(body)
    ]
    return [e for e in eps if group is None or e.group == group]
```

### Round 2 hidden acceptance checks

````python
# Hidden acceptance checks for the strikethrough task. Prints one line per check.
import markdown
def md(s, ext=('strikethrough',)): return markdown.markdown(s, extensions=list(ext))
checks = [
    ("basic", lambda: md("~~gone~~") == "<p><del>gone</del></p>"),
    ("inline", lambda: md("a ~~b~~ c") == "<p>a <del>b</del> c</p>"),
    ("dotted name", lambda: md("~~x~~", ("markdown.extensions.strikethrough",)) == "<p><del>x</del></p>"),
    ("code span untouched", lambda: md("`~~x~~`") == "<p><code>~~x~~</code></p>"),
    ("single tilde untouched", lambda: md("a ~ b ~ c") == "<p>a ~ b ~ c</p>"),
    ("nested emphasis", lambda: md("~~a *b*~~") == "<p><del>a <em>b</em></del></p>"),
    ("not enabled by default", lambda: markdown.markdown("~~x~~") == "<p>~~x~~</p>"),
    ("two on a line", lambda: md("~~a~~ and ~~b~~") == "<p><del>a</del> and <del>b</del></p>"),
    ("unclosed left alone", lambda: md("~~open") == "<p>~~open</p>"),
    ("fenced code untouched", lambda: md("```\n~~x~~\n```", ("strikethrough", "fenced_code")) == "<pre><code>~~x~~\n</code></pre>"),
]
for name, f in checks:
    try: ok = f()
    except Exception as e: ok = f"error: {type(e).__name__}: {e}"
    print(f"{'PASS' if ok is True else 'FAIL'} {name}{'' if ok in (True, False) else ' ' + str(ok)}")
````

### Round 2 grader, MCP path

```bash
#!/bin/bash
# Throwaway: apply a run's patch to a clean copy, push it, run suite + acceptance in the sandbox.
set -u
name=$1 L=/tmp/kagenti/tdd/moca/cmp E=/tmp/sbx-markdown-eval
rm -rf $E && git clone -q /tmp/sbx-markdown $E && cd $E && git apply $L/$name.patch && cp /tmp/sbx-accept.py .sbx_accept.py
$MOCA/packages/sandbox-mcp/demo/sbx-push.sh > /dev/null
cd $MOCA/packages/sandbox-mcp && cp /tmp/sbx-eval-client.ts eval.tmp.ts && node --import tsx eval.tmp.ts > $L/$name.eval.txt 2>&1; rm -f eval.tmp.ts
echo "== $name"; cat $L/$name.eval.txt
```

### Round 2 grader, gRPC path

```bash
#!/bin/bash
# Throwaway: grade a Markdown run's patch over sandbox/v1. Usage: sbx-grpc-eval.sh <name> (or "baseline").
set -u
name=$1 L=/tmp/kagenti/tdd/moca/grpc E=/tmp/sbx-markdown-geval-$name
export PATH=/tmp/sbx-bin:$PATH SBX_ADDR=localhost:9444 SBX_SANDBOX_ID=moca_microvm_0 \
  SBX_TOKEN_FILE=/tmp/sbx-exec.token SBX_WORKSPACE_KEY=sbx-exec-eval-$name
rm -rf $E && git clone -q /tmp/sbx-markdown $E 2> /dev/null && cd $E
[ $name = baseline ] || git apply $L/$name.patch
cp /tmp/sbx-accept.py .sbx_accept.py
sbx push > /dev/null
echo "== $name"
sbx run <<'EOF'
python3 -m unittest discover tests 2>&1 | grep -E "^(FAIL|ERROR):|^Ran|^FAILED|^OK" | grep -vE "test_apis|test_raw_missing_close_bracket|test_raw_unclosed_tag_in_code_span|test_unclosed_comment_"
[ -f markdown/extensions/strikethrough.py ] && python3 .sbx_accept.py
true
EOF
rm -rf $E
```

### Call-log summary, MCP path

```python
import json, sys, collections, datetime as dt
L = '/tmp/kagenti/tdd/moca/cmp'
def iso(s): return dt.datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()
print(f"{'run':8} {'calls':>5} {'VMs':>4} {'sbx s':>6} {'max par':>7} {'errs':>4}  tools")
for name in sys.argv[1:]:
    recs = [json.loads(l) for l in open(f'{L}/{name}.calls.jsonl') if l.strip()]
    recs = [r for r in recs if r['op'] not in ('push', 'pull')]
    iv = sorted((iso(r['t']) - r['ms'] / 1000, iso(r['t'])) for r in recs)
    ev = sorted([(s, 1) for s, _ in iv] + [(e, -1) for _, e in iv], key=lambda x: (x[0], x[1]))
    cur = mx = 0
    for _, d in ev: cur += d; mx = max(mx, cur)
    ops = collections.Counter(r['op'] for r in recs)
    print(f"{name:8} {len(recs):>5} {sum(r['execs'] for r in recs):>4} {sum(r['ms'] for r in recs)/1000:>6.1f} {mx:>7} {sum(not r['ok'] for r in recs):>4}  " + ' '.join(f'{k}={v}' for k, v in sorted(ops.items())))
```

### Call-log summary, gRPC path

```python
# Throwaway: summarize gRPC-path runs. Usage: python3 sbx-grpc-compare.py <run>...
import json, sys
L = '/tmp/kagenti/tdd/moca/grpc'
print(f"{'run':10} {'agent calls':>11} {'sbx calls':>9} {'sbx s':>6} {'denied':>6} {'model s':>7} {'in tok':>8} {'out tok':>7} {'cost':>6}")
for n in sys.argv[1:]:
    calls = [json.loads(l) for l in open(f'{L}/{n}.calls.jsonl') if l.strip()]
    calls = [c for c in calls if c['op'] not in ('push', 'pull')]
    tools = denied = tin = tout = 0
    cost = api = None
    for l in open(f'{L}/{n}.agent.log'):
        try: e = json.loads(l)
        except Exception: continue
        if e.get('type') == 'assistant':
            tools += sum(1 for c in e['message']['content'] if c['type'] == 'tool_use')
        if e.get('type') == 'user':
            denied += sum(1 for c in e['message']['content'] if isinstance(c, dict) and c.get('type') == 'tool_result'
                          and c.get('is_error') and 'permission' in str(c.get('content')).lower())
        if e.get('type') == 'result':
            u = e['usage']; tin = u['input_tokens'] + u.get('cache_read_input_tokens', 0) + u.get('cache_creation_input_tokens', 0)
            tout = u['output_tokens']; cost = e.get('total_cost_usd'); api = e.get('duration_api_ms', 0) / 1000
        if e.get('type') == 'tool_use':
            tools += 1
            st = e['part'].get('state', {})
            denied += st.get('status') == 'error' and 'permission' in str(st.get('error')).lower()
        if e.get('type') == 'step_finish':
            t = e['part']['tokens']; tin += t['input'] + t['cache']['read'] + t['cache']['write']; tout += t['output']
    sbx_s = sum(c['ms'] for c in calls) / 1000
    print(f"{n:10} {tools:>11} {len(calls):>9} {sbx_s:>6.1f} {denied:>6} {api if api else '-':>7} {tin:>8,} {tout:>7,} {('$%.2f' % cost) if cost else '-':>6}")
```

## 5. Round 3: SWE-bench harness

Run from `/tmp/swe/` in this order: `select_instances.py`, `prep.py`, `verify.py`, then `batch.sh` (which calls `run.sh`), then `report.py`.

### `select_instances.py`

```python
# Pick the SWE-bench Verified candidates: sympy 1.5-1.12 and django 3.2-4.2 (Python 3.9), per project
# 2 "<15 min fix" + 3 "15 min - 1 hour" in seeded order, plus 2 spares per group. Writes candidates.jsonl.
import json, re
import pandas as pd

d = pd.read_parquet('/tmp/swe/verified.parquet')
vt = lambda v: tuple(int(x) for x in v.split('.'))
files = lambda p: sorted(set(re.findall(r'^diff --git a/(\S+)', p, re.M)))
sel = []
for repo, lo, hi in [('sympy/sympy', (1, 5), (1, 12)), ('django/django', (3, 2), (4, 2))]:
    s = d[(d.repo == repo) & d.version.map(lambda v: lo <= vt(v) <= hi)]
    for diff, k in [('<15 min fix', 2), ('15 min - 1 hour', 3)]:
        c = s[s.difficulty == diff].sample(frac=1, random_state=7)
        sel += [r for _, r in c.head(k + 2).iterrows()]
for r in sel:
    print(f"{r.instance_id:28} v{r.version:5} {r.difficulty:16} src={files(r.patch)}")
d[d.instance_id.isin([r.instance_id for r in sel])].to_json('/tmp/swe/candidates.jsonl', orient='records', lines=True)
```

### `prep.py`

```python
# Throwaway: one clean tree per candidate at its base commit, no history, committed as a baseline.
# Also writes each instance's prompt, gold patch, test patch and grading metadata.
import json, os, re, shutil, subprocess, sys

ROOT = '/tmp/swe'
for line in open(f'{ROOT}/candidates.jsonl'):
    r = json.loads(line)
    iid, repo = r['instance_id'], r['repo'].split('/')[1]
    d = f'{ROOT}/inst/{iid}'
    if os.path.exists(f'{d}/tree/.git'):
        continue
    os.makedirs(d, exist_ok=True)
    git = f'{ROOT}/{repo}.git'
    subprocess.run(['git', '-C', git, 'fetch', '-q', '--filter=blob:none', 'origin', r['base_commit']], check=True)
    shutil.rmtree(f'{d}/tree', ignore_errors=True)
    os.makedirs(f'{d}/tree')
    archive = subprocess.run(['git', '-C', git, 'archive', r['base_commit']], check=True, capture_output=True).stdout
    subprocess.run(['tar', '-x', '-C', f'{d}/tree'], input=archive, check=True)
    for cmd in (['git', 'init', '-q'], ['git', 'add', '-A'],
                ['git', '-c', 'user.name=swe', '-c', 'user.email=swe@localhost', 'commit', '-q', '-m', 'base']):
        subprocess.run(cmd, cwd=f'{d}/tree', check=True)
    open(f'{d}/gold.patch', 'w').write(r['patch'])
    open(f'{d}/test.patch', 'w').write(r['test_patch'])
    open(f'{d}/issue.md', 'w').write(r['problem_statement'])
    tests = sorted(set(re.findall(r'^diff --git a/(\S+)', r['test_patch'], re.M)))
    json.dump({'id': iid, 'repo': repo, 'version': r['version'], 'difficulty': r['difficulty'],
               'test_files': tests, 'f2p': json.loads(r['FAIL_TO_PASS']), 'p2p': json.loads(r['PASS_TO_PASS'])},
              open(f'{d}/meta.json', 'w'), indent=1)
    tgz = subprocess.run(f'git -C {d}/tree ls-files -z | tar --null -T - -C {d}/tree -czf - | wc -c',
                         shell=True, capture_output=True, text=True, env={**os.environ, 'COPYFILE_DISABLE': '1'}).stdout.strip()
    print(f'{iid}: {len(os.listdir(d + "/tree"))} top-level entries, push size {int(tgz) / 1e6:.1f} MB', flush=True)
```

### `grade.py`

```python
# Throwaway: grade one patch for one instance in a fresh sbx sandbox workspace.
# Usage: grade.py <instance_id> <patch file | -> <label>     ("-" = no patch: the base, for sanity)
import json, os, re, subprocess, sys

ROOT = '/tmp/swe'
ENV = {**os.environ, 'PATH': f"/tmp/sbx-bin:{os.environ['PATH']}", 'SBX_ADDR': 'localhost:9444',
       'SBX_SANDBOX_ID': 'moca_microvm_0', 'SBX_TOKEN_FILE': '/tmp/sbx-exec.token', 'SBX_TIMEOUT': '1800'}


def sbx(args, key, stdin=b'', cwd=None):
    return subprocess.run(['sbx', *args], input=stdin, capture_output=True, cwd=cwd,
                          env={**ENV, 'SBX_WORKSPACE_KEY': key})


def test_command(meta):
    files = meta['test_files']
    if meta['repo'] == 'sympy':  # SWE-bench's sympy spec
        return "PYTHONWARNINGS='ignore::UserWarning,ignore::SyntaxWarning' python3 bin/test -C --verbose " + ' '.join(files)
    labels = [re.sub(r'\.py$', '', f[len('tests/'):]).replace('/', '.') for f in files if f.startswith('tests/')]
    return 'python3 tests/runtests.py --verbosity 2 --settings=test_sqlite --parallel 1 ' + ' '.join(labels)


def parse_sympy(log):  # after SWE-bench's parse_log_sympy
    st = {}
    for line in log.splitlines():
        line = line.strip()
        if line.startswith('test_'):
            name = line.split()[0]
            if line.endswith(' ok'): st[name] = 'PASSED'
            elif line.endswith(' E'): st[name] = 'ERROR'
            elif line.endswith(' F'): st[name] = 'FAILED'
    for m in re.finditer(r'^_+ (?:.+?\.py:)?(test_\w+) _+$', log, re.M):  # failure/error blocks
        st.setdefault(m.group(1), 'FAILED')
    return st


def parse_django(log):  # after SWE-bench's parse_log_django
    st, prev = {}, None
    for line in log.splitlines():
        s = line.strip()
        if ' ... ' in s:
            name, _, res = s.rpartition(' ... ')
            res = res.strip()
            status = ('PASSED' if res.lower() == 'ok' or res.startswith('expected failure') else
                      'SKIPPED' if res.startswith('skipped') else
                      'FAILED' if res == 'FAIL' else 'ERROR' if res == 'ERROR' else None)
            if status:
                st[name] = status
                if prev and not name.startswith('test'):  # docstring line: also credit the test line above
                    st.setdefault(prev, status)
        elif s.startswith(('FAIL:', 'ERROR:')):
            st[s.split(':', 1)[1].strip()] = 'FAILED'
        elif s.strip() in ('ok', 'OK') and prev:
            st[prev] = 'PASSED'
        prev = s.split(' ... ')[0] if s else prev
    return st


def grade(iid, patch, label):
    d = f'{ROOT}/inst/{iid}'
    meta = json.load(open(f'{d}/meta.json'))
    key = f'sbx-exec-g-{label}-{iid.split("__")[1]}'
    r = sbx(['push'], key, cwd=f'{d}/tree')
    if r.returncode:
        return {'id': iid, 'label': label, 'resolved': False, 'error': 'push: ' + r.stderr.decode()[-300:]}
    if patch != '-':
        sbx(['put', '.sbx/model.patch'], key, stdin=open(patch, 'rb').read())
    sbx(['put', '.sbx/test.patch'], key, stdin=open(f'{d}/test.patch', 'rb').read())
    existing = ' '.join(meta['test_files'])
    script = f"""cd /workspace
if [ -s .sbx/model.patch ]; then
  git apply --whitespace=nowarn .sbx/model.patch 2>&1 || {{ echo SBX_PATCH_FAILED; exit 0; }}
fi
for f in {existing}; do git cat-file -e HEAD:"$f" 2>/dev/null && git checkout -q HEAD -- "$f"; done
git apply --whitespace=nowarn .sbx/test.patch 2>&1 || {{ echo SBX_TESTPATCH_FAILED; exit 0; }}
{test_command(meta)} 2>&1
true"""
    r = sbx(['run'], key, stdin=script.encode())
    log = r.stdout.decode(errors='replace') + r.stderr.decode(errors='replace')
    os.makedirs(f'{d}/grades', exist_ok=True)
    open(f'{d}/grades/{label}.log', 'w').write(log)
    if 'SBX_PATCH_FAILED' in log or 'SBX_TESTPATCH_FAILED' in log:
        return {'id': iid, 'label': label, 'resolved': False, 'error': 'patch did not apply'}
    st = (parse_sympy if meta['repo'] == 'sympy' else parse_django)(log)
    f2p = [t for t in meta['f2p'] if st.get(t) != 'PASSED']
    p2p = [t for t in meta['p2p'] if st.get(t) != 'PASSED']
    return {'id': iid, 'label': label, 'resolved': not f2p and not p2p, 'f2p_failed': len(f2p),
            'f2p': len(meta['f2p']), 'p2p_failed': len(p2p), 'p2p': len(meta['p2p']), 'parsed': len(st),
            'missing_examples': (f2p + p2p)[:3]}


if __name__ == '__main__':
    print(json.dumps(grade(*sys.argv[1:4])))
```

### `verify.py`

```python
# Throwaway: gold must resolve and the bare base must not, for every candidate. 4 at a time.
import json, os, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, '/tmp/swe')
from grade import grade

ids = sorted(os.listdir('/tmp/swe/inst'))
jobs = [(i, f'/tmp/swe/inst/{i}/gold.patch', 'gold') for i in ids] + [(i, '-', 'base') for i in ids]
with ThreadPoolExecutor(4) as ex:
    res = list(ex.map(lambda j: grade(*j), jobs))
by = {(r['id'], r['label']): r for r in res}
for i in ids:
    g, b = by[(i, 'gold')], by[(i, 'base')]
    ok = g['resolved'] and not b['resolved'] and b.get('f2p_failed') == b.get('f2p')
    print(f"{'OK ' if ok else 'BAD'} {i:28} gold={g['resolved']} (f2p fail {g.get('f2p_failed')}/{g.get('f2p')}, p2p fail {g.get('p2p_failed')}/{g.get('p2p')}) "
          f"base f2p fail {b.get('f2p_failed')}/{b.get('f2p')} {g.get('error', '')} {g.get('missing_examples') if not g['resolved'] else ''}")
json.dump(res, open('/tmp/swe/verify.json', 'w'), indent=1)
```

### `run.sh`

```bash
#!/bin/bash
# Throwaway: one SWE-bench agent run. Usage: run.sh <instance_id> <cc|oc> <stock|sbx>
set -u
iid=$1 agent=$2 mode=$3
I=/tmp/swe/inst/$iid
run=$agent-$mode-${iid#*__}
R=/tmp/swe/runs/$run
rm -rf $R && mkdir -p $R && cp -a $I/tree $R/repo
repo=$(python3 -c "import json;print(json.load(open('$I/meta.json'))['repo'])")
KEY=${LITELLM_KEY:?}
BASE=${LITELLM_BASE_URL:?}
tests_hint=$([ $repo = sympy ] && echo 'python3 bin/test sympy/path/to/test_file.py' || echo 'python3 tests/runtests.py <app_label or dotted test module>')
where=$([ $mode = sbx ] && echo 'in the sandbox at /workspace' || echo 'in the current directory')
prompt="$(cat $I/issue.md)

---
The $repo repository is checked out $where. Resolve the issue above by changing the source code.
- Make the minimal change to non-test files that fixes the issue. Do not modify existing tests: hidden tests will check your fix.
- python3 is Python 3.9 with the project's dependencies, and the project is importable. There is no network access.
- To run tests: $tests_hint"

cd $R/repo
printf '%s\n' AGENTS.md CLAUDE.md opencode.json .claude/ __pycache__/ '*.pyc' >> .git/info/exclude
if [ $mode = sbx ]; then
  cp /tmp/sbx-grpc-cfg/AGENTS.md /tmp/sbx-grpc-cfg/CLAUDE.md .
  [ $agent = oc ] && python3 -c "
import json; c=json.load(open('/tmp/sbx-grpc-cfg/opencode.json')); c['tools'].pop('task'); c['permission'].pop('task'); json.dump(c, open('opencode.json','w'), indent=1)"
  export PATH=/tmp/sbx-bin:$PATH SBX_ADDR=localhost:9444 SBX_SANDBOX_ID=moca_microvm_0 \
    SBX_TOKEN_FILE=/tmp/sbx-exec.token SBX_WORKSPACE_KEY=sbx-exec-r-$run SBX_LOG=$R/calls.jsonl SBX_TIMEOUT=1800
  sbx push > /dev/null || { echo "$run: push failed"; exit 1; }
  CC_TOOLS=(--allowedTools 'Bash(sbx run:*)' 'Bash(sbx put:*)' --disallowedTools Read Edit Write Glob Grep NotebookEdit WebFetch WebSearch EnterWorktree ExitWorktree Workflow)
else
  [ $agent = oc ] && echo '{"$schema":"https://opencode.ai/config.json","permission":{"*":"allow","webfetch":"deny","websearch":"deny"}}' > opencode.json
  export PATH=/tmp/swe/venv/bin:$PATH PYTHONPATH=$R/repo
  CC_TOOLS=(--permission-mode bypassPermissions --disallowedTools WebFetch WebSearch)
fi
S=$(date +%s.%N)
if [ $agent = oc ]; then
  LITELLM_KEY=$KEY OPENCODE_CONFIG=/tmp/sbx-oc-provider.json timeout 2400 \
    npx -y opencode-ai@latest run --format json "$prompt" < /dev/null > $R/agent.log 2>&1
else
  env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT ANTHROPIC_BASE_URL=$BASE ANTHROPIC_AUTH_TOKEN=$KEY timeout 2400 \
    claude -p "$prompt" --model aws/claude-sonnet-5-5 --setting-sources project --strict-mcp-config "${CC_TOOLS[@]}" \
    --output-format stream-json --verbose < /dev/null > $R/agent.log 2>&1
fi
rc=$?
E=$(date +%s.%N)
if [ $mode = sbx ]; then sbx pull > $R/patch 2> /dev/null; else git add -A -N . && git diff --binary HEAD > $R/patch; fi
printf '{"run":"%s","rc":%s,"wall":%.1f}\n' $run $rc $(echo "$E - $S" | bc) > $R/result.json
cat $R/result.json
```

### `batch.sh`

```bash
#!/bin/bash
# Throwaway: every instance's four variants concurrently, instances one after another. Waits out a
# gateway or tunnel outage before each instance, and reruns (once) any run an outage invalidated.
TOK=${LITELLM_KEY:?}
BASE=${LITELLM_BASE_URL:?}

healthy() {
  [ "$(curl -s -m 15 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOK" "${BASE%/}/v1/models")" = 200 ] || return 1
  pgrep -f "L 9444:localhost:9544" > /dev/null ||
    ssh -f -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR \
      -J $JUMP -L 9444:localhost:9544 $RIG
  PATH=/tmp/sbx-bin:$PATH SBX_ADDR=localhost:9444 SBX_SANDBOX_ID=moca_microvm_0 SBX_TOKEN_FILE=/tmp/sbx-exec.token \
    SBX_WORKSPACE_KEY=sbx-exec-probe sbx run true > /dev/null 2>&1
}

invalid() { # an outage touched this run: a sandbox call that never reached the sandbox, or exhausted retries
  grep -q '"exit": 125' "$1/calls.jsonl" 2> /dev/null && return 0
  grep -q '"attempt":10' "$1/agent.log" 2> /dev/null && return 0
  return 1
}

for iid in $(cat /tmp/swe/final.txt); do
  for attempt in 1 2; do
    until healthy; do echo "$(date +%T) waiting: gateway or sandbox unavailable"; sleep 60; done
    for v in "cc sbx" "cc stock" "oc sbx" "oc stock"; do
      set -- $v
      [ -f /tmp/swe/runs/$1-$2-${iid#*__}/result.json ] || /tmp/swe/run.sh $iid $1 $2 &
    done
    wait
    bad=0
    for d in /tmp/swe/runs/*-${iid#*__}; do
      if invalid $d; then echo "$(date +%T) invalid (outage): $(basename $d)"; mv $d /tmp/swe/runs-invalid/$(basename $d).$attempt; bad=1; fi
    done
    [ $bad = 0 ] && break
  done
  echo "$(date +%T) done $iid"
done
```

### `report.py`

```python
# Throwaway: grade every finished run (4 at a time, cached) and summarize per agent and mode.
import json, os, sys
from concurrent.futures import ThreadPoolExecutor
sys.path.insert(0, '/tmp/swe')
from grade import grade

RUNS = '/tmp/swe/runs'
ids = open('/tmp/swe/final.txt').read().split()


def agent_stats(run):
    tools = tin = tout = 0; cost = api = None; prev = None; gaps = []
    for l in open(f'{RUNS}/{run}/agent.log'):
        try: e = json.loads(l)
        except Exception: continue
        if e.get('type') == 'assistant':
            tools += sum(1 for c in e['message']['content'] if c['type'] == 'tool_use')
        if e.get('type') == 'result':
            u = e['usage']; tin = u['input_tokens'] + u.get('cache_read_input_tokens', 0) + u.get('cache_creation_input_tokens', 0)
            tout = u['output_tokens']; cost = e.get('total_cost_usd'); api = e.get('duration_api_ms', 0) / 1000
        if e.get('type') == 'tool_use': tools += 1
        if e.get('type') == 'step_finish':
            t = e['part']['tokens']; tin += t['input'] + t['cache']['read'] + t['cache']['write']; tout += t['output']
        ts = e.get('timestamp')
        if ts is not None:
            if e.get('type') == 'step_start' and prev is not None: gaps.append((ts - prev) / 1000)
            prev = ts
    return dict(tools=tools, tin=tin, tout=tout, cost=cost, model=api if api is not None else sum(gaps))


def one(run, iid):
    g = f'{RUNS}/{run}/grade.json'
    if not os.path.exists(g):
        json.dump(grade(iid, f'{RUNS}/{run}/patch', run), open(g, 'w'))
    res = json.load(open(g)); meta = json.load(open(f'{RUNS}/{run}/result.json'))
    calls = [json.loads(l) for l in open(f'{RUNS}/{run}/calls.jsonl')] if os.path.exists(f'{RUNS}/{run}/calls.jsonl') else []
    calls = [c for c in calls if c['op'] not in ('push', 'pull')]
    return dict(run=run, iid=iid, resolved=res['resolved'], wall=meta['wall'], rc=meta['rc'],
                sbx_calls=len(calls), sbx_s=sum(c['ms'] for c in calls) / 1000, **agent_stats(run))


jobs = [(f'{a}-{m}-{i.split("__")[1]}', i) for i in ids for a in ('cc', 'oc') for m in ('stock', 'sbx')
        if os.path.exists(f'{RUNS}/{a}-{m}-{i.split("__")[1]}/result.json')]
with ThreadPoolExecutor(4) as ex:
    rows = list(ex.map(lambda j: one(*j), jobs))
json.dump(rows, open('/tmp/swe/report.json', 'w'), indent=1)

print(f"{'instance':16} " + ' '.join(f'{v:>9}' for v in ('cc-stock', 'cc-sbx', 'oc-stock', 'oc-sbx')))
for i in ids:
    cells = []
    for v in ('cc-stock', 'cc-sbx', 'oc-stock', 'oc-sbx'):
        r = next((r for r in rows if r['run'] == f'{v}-{i.split("__")[1]}'), None)
        cells.append('-' if not r else ('PASS' if r['resolved'] else 'fail') + ('*' if r['rc'] else ''))
    print(f"{i.split('__')[1]:16} " + ' '.join(f'{c:>9}' for c in cells))
print('\n* = agent exited non-zero (timeout 124)\n')
print(f"{'variant':9} {'resolved':>8} {'tool calls':>10} {'sbx calls':>9} {'sbx s':>6} {'model s':>8} {'wall s':>7} {'in tok':>9} {'out tok':>8} {'cost':>7}")
for v in ('cc-stock', 'cc-sbx', 'oc-stock', 'oc-sbx'):
    rs = [r for r in rows if r['run'].startswith(v + '-')]
    if not rs: continue
    n = len(rs); s = lambda k: sum(r[k] or 0 for r in rs)
    cost = f"${s('cost'):.2f}" if any(r['cost'] for r in rs) else '-'
    print(f"{v:9} {sum(r['resolved'] for r in rs):>4}/{n:<3} {s('tools')/n:>10.1f} {s('sbx_calls')/n:>9.1f} {s('sbx_s')/n:>6.1f} "
          f"{s('model')/n:>8.0f} {s('wall')/n:>7.0f} {s('tin')/n:>9,.0f} {s('tout')/n:>8,.0f} {cost:>7}")
print('(per-run means, except resolved and total cost)')
```

### `final.txt`

```text
sympy__sympy-19637
sympy__sympy-18189
sympy__sympy-18211
sympy__sympy-20438
sympy__sympy-17318
django__django-14534
django__django-14765
django__django-13012
django__django-14034
django__django-15098
```
