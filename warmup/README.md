# Warm-up: debug sshd on the runner

`warmup-debug-sshd.sh` starts a **separate, locked-down SSH server** on each Build Hub runner VM. Debug sessions use it; Bitrise's own SSH (port 22, used by Bitrise remote access) is not touched.

| Setting | Value |
|---|---|
| Listens on | `127.0.0.1:10022` only (reachable only through the debug tunnel) |
| Login | Public key only. No passwords, no root |
| Allowed user | The runner user (e.g. `vagrant`) |
| Allowed keys | `~/.ssh/debug_authorized_keys`, filled per job by the action with the GitHub keys of the user who ran the job |
| Supported | macOS and Linux (installs `openssh-server` on Linux if missing) |

It is safe to add anywhere in an existing warm-up script: it runs as a separate process, doesn't change shell options, and never fails the warm-up. If something goes wrong it prints `debug-sshd: setup failed …` and the VM starts normally (debug SSH is just unavailable on that VM).

## Add it to your pool

**Option A: paste.** Copy everything between `BEGIN debug-sshd` and `END debug-sshd` and append it to the end of the pool's existing warm-up script (or use it as the whole script if the pool has none).

**Option B: download a pinned version** (keeps every pool on the same release):

```bash
DEBUG_SSHD_URL=https://raw.githubusercontent.com/naveen-bitrise/buildhub-debug-ssh/v1/warmup/warmup-debug-sshd.sh
curl -fsSL "$DEBUG_SSHD_URL" -o /tmp/warmup-debug-sshd.sh \
  && bash /tmp/warmup-debug-sshd.sh \
  || echo "debug-sshd: download failed (debug SSH unavailable on this runner)"
```

For the strictest setups, pin to a commit SHA instead of `v1`.

A successful warm-up log shows:

```
debug-sshd: listening on 127.0.0.1:10022 for user vagrant
```

## Options

Set before the snippet, if needed:

| Variable | Default | When to change |
|---|---|---|
| `DEBUG_SSHD_PORT` | `10022` | Port clash with something on the VM. Also set the action's `sshd-port` input to the same value. |
| `RUNNER_USER` | current user | The warm-up runs as root and jobs run as another user. |

## Notes

- Port `2222` caused the Build Hub agent to fail to start in testing, so don't use it.
- The runner user typically has passwordless `sudo` (it's in `admin`). A debug session therefore has the same power as any job step on that runner. Nothing more.
