# ---- BEGIN debug-sshd (buildhub-debug-ssh: add to the Bitrise runner pool WARM-UP script) ----
# Starts a SEPARATE, locked-down sshd used only for debug sessions:
#   - listens on 127.0.0.1:10022 only (reachable only through the debug tunnel)
#   - public-key only (no passwords), no root, only the runner user
#   - keys come from ~/.ssh/debug_authorized_keys, filled per job by the workflow
#     step with the GitHub keys of whoever triggered the job
# Bitrise's own sshd (port 22, used by Bitrise remote access) is NOT touched.
#
# Safe to paste inline: runs as a separate bash process (no `exit`, no shell
# options leak), sshd is detached from the warm-up's output, and any failure
# is logged and ignored.
# Optional env: RUNNER_USER (default: current user / $SUDO_USER), DEBUG_SSHD_PORT (default 10022)

DEBUG_SSHD_SCRIPT=$(cat <<'DEBUG_SSHD'
set -euo pipefail
RUNNER_USER=${RUNNER_USER:-${SUDO_USER:-$(id -un)}}
PORT=${DEBUG_SSHD_PORT:-10022}
DIR=/opt/debug-sshd
SUDO=""; [ "$(id -u)" -eq 0 ] || SUDO="sudo -n"

[ "$RUNNER_USER" != "root" ] || { echo "set RUNNER_USER to the user that runs jobs"; exit 1; }

# Never take a port another service already uses
if nc -z 127.0.0.1 "$PORT" 2>/dev/null && ! [ -f /opt/debug-sshd/sshd.pid ]; then
  echo "port $PORT already in use by another service; skipping"; exit 1
fi

if [ ! -x /usr/sbin/sshd ]; then
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -qq </dev/null
    $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server </dev/null
  else
    echo "/usr/sbin/sshd not found"; exit 1
  fi
fi

$SUDO mkdir -p "$DIR"
$SUDO chmod 755 "$DIR"
[ -f "$DIR/ssh_host_ed25519_key" ] || \
  $SUDO ssh-keygen -q -t ed25519 -N "" -f "$DIR/ssh_host_ed25519_key" </dev/null

$SUDO tee "$DIR/sshd_config" >/dev/null <<EOF
# Debug-only sshd (managed by warm-up)
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/ssh_host_ed25519_key
PidFile $DIR/sshd.pid
AuthorizedKeysFile .ssh/debug_authorized_keys
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
PermitRootLogin no
PermitEmptyPasswords no
AllowUsers $RUNNER_USER
MaxAuthTries 3
LoginGraceTime 20
MaxStartups 3:50:10
X11Forwarding no
AllowAgentForwarding no
PermitTunnel no
AllowTcpForwarding local
PrintMotd no
Subsystem sftp internal-sftp
EOF

if [ "$(uname)" = "Linux" ]; then $SUDO mkdir -p /run/sshd; fi

$SUDO /usr/sbin/sshd -t -f "$DIR/sshd_config"

if [ -f "$DIR/sshd.pid" ]; then
  $SUDO kill "$($SUDO cat "$DIR/sshd.pid")" 2>/dev/null || true
  sleep 1
fi
# Fully detached so it doesn't hold the warm-up's output open
$SUDO /usr/sbin/sshd -f "$DIR/sshd_config" -E /tmp/debug-sshd.log </dev/null >/dev/null 2>&1

HOME_DIR=$(eval echo "~$RUNNER_USER")
$SUDO mkdir -p "$HOME_DIR/.ssh"
$SUDO touch "$HOME_DIR/.ssh/debug_authorized_keys"
$SUDO chown "$RUNNER_USER" "$HOME_DIR/.ssh" "$HOME_DIR/.ssh/debug_authorized_keys"
$SUDO chmod 700 "$HOME_DIR/.ssh"
$SUDO chmod 600 "$HOME_DIR/.ssh/debug_authorized_keys"

# Confirm it is actually listening
for i in 1 2 3 4 5; do
  if nc -z 127.0.0.1 "$PORT" 2>/dev/null; then
    echo "listening on 127.0.0.1:$PORT for user $RUNNER_USER"; exit 0
  fi
  sleep 1
done
echo "sshd started but not listening on $PORT (see /tmp/debug-sshd.log)"; exit 1
DEBUG_SSHD
)
if DEBUG_SSHD_OUT=$(RUNNER_USER="${RUNNER_USER:-}" DEBUG_SSHD_PORT="${DEBUG_SSHD_PORT:-}" \
     bash -c "$DEBUG_SSHD_SCRIPT" </dev/null 2>&1); then
  printf '%s\n' "$DEBUG_SSHD_OUT" | sed 's/^/debug-sshd: /'
else
  printf '%s\n' "$DEBUG_SSHD_OUT" | tail -5 | sed 's/^/debug-sshd: /'
  echo "debug-sshd: setup failed (debug SSH unavailable on this runner; build unaffected)"
fi
unset DEBUG_SSHD_SCRIPT DEBUG_SSHD_OUT
# ---- END debug-sshd ----
