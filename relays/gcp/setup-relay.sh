#!/usr/bin/env bash
# relays/gcp/setup-relay.sh — part of buildhub-debug-ssh
#
# Turns an existing Google Compute Engine VM into a debug relay
# (needs only the Editor role on the project; no IAM changes):
#
#   Runner --(ssh -R, tunnel key)--> relay VM :20000-29999 <--(ssh -p PORT)-- Developer
#
# - No developer accounts on the relay. Developers authenticate to the RUNNER,
#   whose debug sshd only accepts the GitHub SSH keys of the user who ran the job.
# - The relay has one "tunnel" account that can ONLY open reverse tunnels
#   (no shell, no TTY).
# - Tunnel ports come from 20000-29999.
#
# Local state (tunnel key, known_hosts, your answers) is kept OUTSIDE any repo:
#   ${BUILDHUB_DEBUG_SSH_HOME:-~/.buildhub-debug-ssh}/<vm-name>/
#
# Values can be given as env vars to skip prompts: VM, PROJECT, ZONE, ALLOWED_SOURCES.
# Safe to re-run.

set -euo pipefail

STATE_BASE=${BUILDHUB_DEBUG_SSH_HOME:-$HOME/.buildhub-debug-ssh}

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '  • %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
ask() {
  local var=$1 prompt=$2 def=${3:-} val
  if [ -n "${!var:-}" ]; then return; fi
  if [ -n "$def" ]; then read -r -p "$prompt [$def]: " val; val=${val:-$def}
  else read -r -p "$prompt: " val; fi
  [ -n "$val" ] || { echo "Value required for $var" >&2; exit 1; }
  printf -v "$var" '%s' "$val"
}
confirm() { local a; read -r -p "$1 [y/N]: " a; [[ $a =~ ^[Yy]$ ]]; }

command -v gcloud >/dev/null || { echo "gcloud not found" >&2; exit 1; }
command -v ssh-keygen >/dev/null || { echo "ssh-keygen not found" >&2; exit 1; }

PORT_MIN=20000
PORT_MAX=29999

# ---------- inputs ----------
bold "Inputs"
ask VM "Relay VM name"
STATE_DIR="$STATE_BASE/$VM"
CONFIG="$STATE_DIR/config.env"
# Re-runs: reuse saved answers (env vars still win)
if [ -f "$CONFIG" ]; then
  while IFS='=' read -r k v; do
    case "$k" in PROJECT|ZONE|ALLOWED_SOURCES) [ -z "${!k:-}" ] && printf -v "$k" '%s' "$v" ;; esac
  done < "$CONFIG"
fi
ask PROJECT "GCP project ID" "$(gcloud config get-value project 2>/dev/null || true)"
ask ZONE "Relay VM zone (e.g. us-central1-b)"
ALLOWED_SOURCES=${ALLOWED_SOURCES:-}   # optional CIDR restriction
KEY_DIR="$STATE_DIR"
TUNNEL_KEY="$KEY_DIR/tunnel_ed25519"

info "Project: $PROJECT | Zone: $ZONE | VM: $VM"
info "Reachable from: ${ALLOWED_SOURCES:-any IP (key-only login)}"
info "Tunnel ports: $PORT_MIN-$PORT_MAX"
info "Local state: $STATE_DIR"
confirm "Continue?" || exit 0

mkdir -p "$STATE_DIR" && chmod 700 "$STATE_DIR"
printf 'PROJECT=%s\nZONE=%s\nALLOWED_SOURCES=%s\n' "$PROJECT" "$ZONE" "$ALLOWED_SOURCES" > "$CONFIG"

gcloud config set project "$PROJECT" >/dev/null
gcloud compute instances describe "$VM" --zone "$ZONE" >/dev/null 2>&1 \
  || { echo "VM '$VM' not found in $ZONE" >&2; exit 1; }

# ---------- 1. tunnel key ----------
bold "1/6 Tunnel key (used only by runners to open reverse tunnels)"
if [ -f "$TUNNEL_KEY" ]; then
  info "exists: $TUNNEL_KEY"
else
  ssh-keygen -q -t ed25519 -N "" -C "tunnel" -f "$TUNNEL_KEY"
  info "created: $TUNNEL_KEY  (private key -> GitHub secret; never commit it)"
fi

# ---------- 2. external IP ----------
bold "2/6 External IP"
EXT_IP=$(gcloud compute instances describe "$VM" --zone "$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
if [ -z "$EXT_IP" ]; then
  warn "VM has no external IP. Adding one."
  gcloud compute instances add-access-config "$VM" --zone "$ZONE" --access-config-name="External NAT"
  EXT_IP=$(gcloud compute instances describe "$VM" --zone "$ZONE" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
fi
info "external IP: $EXT_IP"
REGION=${ZONE%-*}
if gcloud compute addresses list --filter="address=$EXT_IP" --format='value(name)' | grep -q .; then
  info "IP is already static"
elif confirm "Make $EXT_IP static so it survives stop/start? (small monthly cost when VM is stopped)"; then
  gcloud compute addresses create "${VM}-ip" --addresses "$EXT_IP" --region "$REGION"
  info "IP reserved as ${VM}-ip"
fi

# ---------- 3. firewall ----------
bold "3/6 Firewall (tcp:22 for runners, tcp:$PORT_MIN-$PORT_MAX for developers)"
NETWORK=$(gcloud compute instances describe "$VM" --zone "$ZONE" \
  --format='value(networkInterfaces[0].network.basename())')
gcloud compute instances add-tags "$VM" --zone "$ZONE" --tags debug-relay >/dev/null
SOURCES=${ALLOWED_SOURCES:-0.0.0.0/0}
RULES="tcp:22,tcp:$PORT_MIN-$PORT_MAX"
if gcloud compute firewall-rules describe debug-relay-allow >/dev/null 2>&1; then
  gcloud compute firewall-rules update debug-relay-allow --rules "$RULES" --source-ranges "$SOURCES" >/dev/null
else
  gcloud compute firewall-rules create debug-relay-allow --network "$NETWORK" \
    --direction INGRESS --action allow --rules "$RULES" --source-ranges "$SOURCES" \
    --target-tags debug-relay --priority 900 >/dev/null
fi
if [ -n "$ALLOWED_SOURCES" ]; then
  # Deny everyone else on these ports (beats default-allow-ssh at 65534)
  if ! gcloud compute firewall-rules describe debug-relay-deny >/dev/null 2>&1; then
    gcloud compute firewall-rules create debug-relay-deny --network "$NETWORK" \
      --direction INGRESS --action deny --rules "$RULES" --source-ranges 0.0.0.0/0 \
      --target-tags debug-relay --priority 1000 >/dev/null
  fi
fi
info "allowed from: $SOURCES"

# ---------- 4. tunnel key in VM metadata (merge, don't clobber) ----------
bold "4/6 Tunnel account on the relay"
KEYS_FILE=$(mktemp)
gcloud compute instances describe "$VM" --zone "$ZONE" \
  --flatten="metadata.items[]" --filter="metadata.items.key=ssh-keys" \
  --format="value(metadata.items.value)" 2>/dev/null \
  | grep -v -E "^tunnel:" | sed '/^$/d' > "$KEYS_FILE" || true
echo "tunnel:$(cat "$TUNNEL_KEY.pub")" >> "$KEYS_FILE"
info "user 'tunnel' authorised with $TUNNEL_KEY.pub"

# ---------- 5. sshd lockdown + port range via startup script ----------
STARTUP=$(mktemp)
cat >"$STARTUP" <<EOS
#!/bin/bash
# Managed by setup-debug-relay.sh
# Reverse-tunnel ports are allocated from this range:
sysctl -w net.ipv4.ip_local_port_range="$PORT_MIN $PORT_MAX"
echo 'net.ipv4.ip_local_port_range = $PORT_MIN $PORT_MAX' > /etc/sysctl.d/90-debug-relay.conf

BLOCK='# BEGIN debug-relay
Match User tunnel
  AllowTcpForwarding remote
  GatewayPorts clientspecified
  PermitListen any
  PermitTTY no
  X11Forwarding no
  AllowAgentForwarding no
  ForceCommand /bin/false
# END debug-relay'
CONF=/etc/ssh/sshd_config
sed -i '/# BEGIN debug-relay/,/# END debug-relay/d' "\$CONF"
printf '\n%s\n' "\$BLOCK" >> "\$CONF"
if sshd -t; then
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
else
  echo "debug-relay: sshd config test failed; reverting" >&2
  sed -i '/# BEGIN debug-relay/,/# END debug-relay/d' "\$CONF"
fi
EOS

bold "5/6 Apply metadata"
gcloud compute instances add-metadata "$VM" --zone "$ZONE" \
  --metadata enable-oslogin=FALSE,enable-guest-attributes=TRUE \
  --metadata-from-file ssh-keys="$KEYS_FILE",startup-script="$STARTUP" >/dev/null
rm -f "$KEYS_FILE" "$STARTUP"
info "done"
if confirm "Restart '$VM' now to apply? (~1 min)"; then
  gcloud compute instances reset "$VM" --zone "$ZONE" >/dev/null
  info "restarted; waiting 60s for boot"
  sleep 60
else
  warn "Not restarted: changes apply on next boot."
fi

# ---------- 6. host key + tests ----------
bold "6/6 Host key and tests"
KNOWN_HOSTS=""
for i in $(seq 1 15); do
  HK=$(gcloud compute instances get-guest-attributes "$VM" --zone "$ZONE" \
    --query-path=hostkeys/ssh-ed25519 --format='value(value)' 2>/dev/null || true)
  if [ -n "$HK" ]; then
    [[ $HK == ssh-* ]] || HK="ssh-ed25519 $HK"
    KNOWN_HOSTS="$EXT_IP $HK"; info "relay host key from GCE guest attributes"; break
  fi
  KS=$(ssh-keyscan -T 5 -t ed25519 "$EXT_IP" 2>/dev/null | grep -v '^#' | grep 'ssh-ed25519' | head -1 || true)
  if [ -n "$KS" ]; then
    KNOWN_HOSTS="$KS"; warn "host key via ssh-keyscan (check the fingerprint below)"; break
  fi
  printf '  … waiting for the relay to answer on port 22 (%s/15)\n' "$i"
  sleep 10
done
if [ -z "$KNOWN_HOSTS" ]; then
  warn "Relay $EXT_IP did not answer on port 22 after ~2.5 min."
  warn "Check: VM is RUNNING in the console; 'nc -vz $EXT_IP 22' from your Mac;"
  warn "       firewall rule debug-relay-allow exists; then re-run this script."
  exit 1
fi
KH_FILE="$KEY_DIR/known_hosts"
echo "$KNOWN_HOSTS" > "$KH_FILE"
if ! ssh-keygen -lf "$KH_FILE" | sed 's/^/  fingerprint: /'; then
  warn "Could not parse host key line: $KNOWN_HOSTS"; exit 1
fi

SSH_OPTS=(-o UserKnownHostsFile="$KH_FILE" -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=10)

# a) tunnel opens on a public port in range, reachable from here
LOG=$(mktemp)
ssh "${SSH_OPTS[@]}" -i "$TUNNEL_KEY" -N -o ExitOnForwardFailure=yes \
  -R 0.0.0.0:0:localhost:9 "tunnel@$EXT_IP" 2>"$LOG" &
PID=$!; sleep 6
PORT=$(grep -oE 'Allocated port [0-9]+' "$LOG" | awk '{print $3}' || true)
if [ -n "$PORT" ]; then
  if [ "$PORT" -ge "$PORT_MIN" ] && [ "$PORT" -le "$PORT_MAX" ]; then
    info "PASS: tunnel opened on port $PORT (in range)"
  else
    warn "tunnel opened on port $PORT, OUTSIDE $PORT_MIN-$PORT_MAX (restart VM to apply port range)"
  fi
  if nc -z -w 5 "$EXT_IP" "$PORT" 2>/dev/null; then
    info "PASS: port $PORT reachable from this machine"
  else
    warn "FAIL: port $PORT not reachable (firewall or GatewayPorts not applied yet)"
  fi
else
  warn "FAIL: tunnel test. Output:"; sed 's/^/    /' "$LOG" >&2
fi
kill $PID 2>/dev/null || true; rm -f "$LOG"

# b) tunnel user must not get a shell
if ssh "${SSH_OPTS[@]}" -i "$TUNNEL_KEY" "tunnel@$EXT_IP" id 2>/dev/null | grep -q uid; then
  warn "FAIL: tunnel user got a shell. Lockdown not active yet (restart the VM)."
else
  info "PASS: tunnel user has no shell"
fi

# ---------- summary ----------
bold "Done. Next steps"
cat <<EOF

1) GitHub: add to the repo (or org) that runs the jobs
   Settings → Secrets and variables → Actions

     Secret    RELAY_TUNNEL_KEY   = contents of $TUNNEL_KEY
     Variable  RELAY_HOST         = $EXT_IP
     Variable  RELAY_KNOWN_HOSTS  = $KNOWN_HOSTS

   Or with the GitHub CLI (replace OWNER/REPO, or use --org ORG):
     gh secret   set RELAY_TUNNEL_KEY  --repo OWNER/REPO < "$TUNNEL_KEY"
     gh variable set RELAY_HOST        --repo OWNER/REPO --body "$EXT_IP"
     gh variable set RELAY_KNOWN_HOSTS --repo OWNER/REPO --body "$KNOWN_HOSTS"

2) Bitrise runner pool warm-up: add warmup/warmup-debug-sshd.sh (see warmup/README.md)

3) Workflows: add the action step (see examples/workflow.yml)

Developers only need an SSH key on their GitHub profile.
Keep $STATE_DIR private: it holds the tunnel private key.
EOF
