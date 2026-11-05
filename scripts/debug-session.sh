#!/usr/bin/env bash
# scripts/debug-session.sh — part of buildhub-debug-ssh (called by action.yml)
#
# 1. Allows the GitHub SSH keys of the job's user into the runner's debug sshd
#    (started by warmup/warmup-debug-sshd.sh on 127.0.0.1:$DEBUG_SSHD_PORT).
# 2. Opens a reverse tunnel: public port on the relay -> that debug sshd.
# 3. Prints the connect command in the job log and job summary.
# 4. Keeps the job alive until the developer runs ~/debug-done or time runs out.
#    ~/debug-extend adds time, ~/debug-status shows time left.

set -uo pipefail

: "${DEBUG_SSHD_PORT:=10022}"
: "${DEBUG_START_MINUTES:=30}"
: "${DEBUG_EXTEND_MINUTES:=15}"
: "${DEBUG_MAX_MINUTES:=120}"
: "${GITHUB_USERS:=}"
: "${ACTOR:=${GITHUB_ACTOR:-}}"
SERVER_URL=${GITHUB_SERVER_URL:-https://github.com}

fail() { echo "::error::$*"; exit 1; }

# ---------- 0. checks ----------
[ -n "${RELAY_HOST:-}" ]        || fail "relay-host is empty. Set the RELAY_HOST variable (Settings → Secrets and variables → Actions) and pass it to the action."
[ -n "${RELAY_KNOWN_HOSTS:-}" ] || fail "relay-known-hosts is empty. Set the RELAY_KNOWN_HOSTS variable and pass it to the action."
[ -n "${RELAY_TUNNEL_KEY:-}" ]  || fail "tunnel-key is empty. Set the RELAY_TUNNEL_KEY secret (and give this repo access if it's an org secret)."
nc -z 127.0.0.1 "$DEBUG_SSHD_PORT" 2>/dev/null \
  || fail "Debug sshd is not running on this runner (port $DEBUG_SSHD_PORT). Add warmup/warmup-debug-sshd.sh to the pool's warm-up script."

# ---------- 1. who may log in ----------
USERS=${GITHUB_USERS:-$ACTOR}
[ -n "$USERS" ] || fail "No GitHub user to authorise (github-users input empty and no triggering actor)."
mkdir -p ~/.ssh && chmod 700 ~/.ssh
AUTH_KEYS=~/.ssh/debug_authorized_keys
RAW=$(mktemp)
for u in $(echo "$USERS" | tr ',' ' '); do
  if curl -fsSL "$SERVER_URL/$u.keys" >> "$RAW"; then echo >> "$RAW"
  else echo "::warning::Could not fetch SSH keys for $u"; fi
done
grep -E '^(ssh-|ecdsa-|sk-)' "$RAW" > "$AUTH_KEYS" || true
rm -f "$RAW"
chmod 600 "$AUTH_KEYS"
[ -s "$AUTH_KEYS" ] || fail "No SSH keys found for: $USERS. Add one at $SERVER_URL/settings/keys"
echo "Authorised GitHub users: $USERS ($(wc -l < "$AUTH_KEYS" | tr -d ' ') keys)"

# ---------- 2. reverse tunnel ----------
WORK=$(mktemp -d)
( umask 077
  printf '%s\n' "$RELAY_TUNNEL_KEY"  > "$WORK/key"
  printf '%s\n' "$RELAY_KNOWN_HOSTS" > "$WORK/known_hosts" )

ssh -i "$WORK/key" -o UserKnownHostsFile="$WORK/known_hosts" -o StrictHostKeyChecking=yes \
    -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
    -N -R "0.0.0.0:0:127.0.0.1:$DEBUG_SSHD_PORT" "tunnel@$RELAY_HOST" 2>"$WORK/ssh.log" &
SSH_PID=$!

cleanup() {
  kill "$SSH_PID" 2>/dev/null || true
  rm -rf "$WORK"
  rm -f "$AUTH_KEYS" ~/.debug-status ~/.debug-extend ~/debug-extend ~/debug-status ~/debug-done
}
trap cleanup EXIT

PORT=""
for i in $(seq 1 15); do
  PORT=$(grep -oE 'Allocated port [0-9]+' "$WORK/ssh.log" | awk '{print $3}' || true)
  [ -n "$PORT" ] && break
  kill -0 "$SSH_PID" 2>/dev/null || break
  sleep 2
done
if [ -z "$PORT" ]; then
  echo "Tunnel to $RELAY_HOST failed:"; cat "$WORK/ssh.log"
  fail "Could not open the tunnel (check relay-host, relay-known-hosts and tunnel-key)."
fi

# ---------- 3. tell the developer ----------
ALIAS="buildhub-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-1}"
CMD="ssh -o HostKeyAlias=$ALIAS -p $PORT $(whoami)@$RELAY_HOST"
FP=$(ssh-keygen -lf /opt/debug-sshd/ssh_host_ed25519_key.pub 2>/dev/null | awk '{print $2}' || true)
echo "::notice title=Debug SSH (for ${USERS})::$CMD"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Debug SSH (only ${USERS} can log in)"
    echo '```'
    echo "$CMD"
    echo '```'
    [ -n "$FP" ] && echo "Runner host key fingerprint: \`$FP\`"
    echo
    echo "Session: ${DEBUG_START_MINUTES} min, extendable to ${DEBUG_MAX_MINUTES} min. Inside the session:"
    echo '- `~/debug-status` time left'
    echo "- \`~/debug-extend\` add ${DEBUG_EXTEND_MINUTES} min"
    echo '- `~/debug-done` finish now'
  } >> "$GITHUB_STEP_SUMMARY"
fi

# ---------- 4. helper commands ----------
cat > ~/debug-extend <<'EOF'
#!/bin/bash
touch ~/.debug-extend
sleep 11
cat ~/.debug-status 2>/dev/null
EOF
cat > ~/debug-status <<'EOF'
#!/bin/bash
cat ~/.debug-status 2>/dev/null || echo "No active debug session"
EOF
cat > ~/debug-done <<'EOF'
#!/bin/bash
touch ~/continue
echo "Finishing: the job continues within ~10 seconds and this session will close."
EOF
chmod +x ~/debug-extend ~/debug-status ~/debug-done
rm -f ~/continue ~/.debug-extend

# ---------- 5. wait ----------
fmt() { date -u -r "$1" +%H:%M 2>/dev/null || date -u -d "@$1" +%H:%M; }
START=$(date +%s)
DEADLINE=$((START + DEBUG_START_MINUTES * 60))
CAP=$((START + DEBUG_MAX_MINUTES * 60))
WARNED=""
while [ ! -f ~/continue ]; do
  NOW=$(date +%s)
  if [ -f ~/.debug-extend ]; then
    rm -f ~/.debug-extend
    DEADLINE=$((DEADLINE + DEBUG_EXTEND_MINUTES * 60))
    [ "$DEADLINE" -gt "$CAP" ] && DEADLINE=$CAP
    WARNED=""
    echo "Extended: session now ends at $(fmt "$DEADLINE") UTC"
  fi
  if [ "$DEADLINE" -le "$NOW" ]; then
    echo "Debug time is up."
    echo "Debug session time is up; ending." | wall 2>/dev/null || true
    break
  fi
  LEFT=$(( (DEADLINE - NOW + 59) / 60 ))
  MAXNOTE=""; [ "$DEADLINE" -ge "$CAP" ] && MAXNOTE=" (maximum reached; can't extend further)"
  printf 'Debug session: %s min left (ends %s UTC)%s\nExtend: ~/debug-extend (+%s min)   Finish: ~/debug-done\n' \
    "$LEFT" "$(fmt "$DEADLINE")" "$MAXNOTE" "$DEBUG_EXTEND_MINUTES" > ~/.debug-status
  if [ "$LEFT" -le 5 ] && [ -z "$WARNED" ]; then
    WARNED=1
    echo "Debug session ends in about 5 min. Run ~/debug-extend to add time." | wall 2>/dev/null || true
  fi
  if ! kill -0 "$SSH_PID" 2>/dev/null; then
    echo "::warning::Tunnel to the relay dropped; ending the debug session."
    break
  fi
  sleep 10
done
rm -f ~/continue
echo "Debug session finished."
