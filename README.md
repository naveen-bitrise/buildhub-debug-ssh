# buildhub-debug-ssh

SSH into the **Bitrise Build Hub** runner that is running your GitHub Actions job, to debug a failure live. No Bitrise admin rights, no third-party relay, no passwords.

- A developer who triggered (or re-ran) a job can SSH into **that job's runner** with the SSH key on their GitHub profile.
- Sessions start on failure or on demand, last 30 minutes by default, and can be extended from inside the session.
- Traffic goes through a small **relay VM you own**. One relay serves all runners and developers.

> This is a field tool, not an official Bitrise product feature.

## How it works

```
                 ┌──────────── your relay VM ────────────┐
Runner VM ──────▶│ :22  tunnel user (reverse tunnels only)│
(debug sshd      │ :20000-29999  one port per session     │◀────── Developer
 127.0.0.1:10022)└────────────────────────────────────────┘        ssh -p PORT … (GitHub SSH key)
```

1. **Warm-up** (once per VM): the pool's warm-up script starts a separate, locked-down SSH server on the runner at `127.0.0.1:10022` (key-only, no root). Bitrise's own SSH is untouched.
2. **Job** (when a step fails, or on demand): the action
   - downloads the GitHub SSH keys of the user who ran the job,
   - opens a reverse tunnel from a public port on the relay to the runner's debug SSH server,
   - prints the connect command in the job log and job summary,
   - keeps the job alive until the developer finishes or time runs out.
3. **Developer** runs the command from the job summary. Only their GitHub keys work. The SSH session is end to end between the developer and the runner; the relay only forwards bytes.

## Setup (one-time)

### 1. Relay

Pick one (see [relays/](relays/README.md)):

| Relay | Setup |
|---|---|
| Google Cloud VM | [`relays/gcp/`](relays/gcp/README.md): `./relays/gcp/setup-relay.sh` |
| Any Linux VM | [`relays/generic/`](relays/generic/README.md): manual steps |

### 2. Runner pool warm-up

Add [`warmup/warmup-debug-sshd.sh`](warmup/README.md) to the Build Hub runner pool's warm-up script.

### 3. GitHub secret and variables

In the repo (or org) that runs the jobs, **Settings → Secrets and variables → Actions**. The relay setup prints the values:

| Type | Name | Value |
|---|---|---|
| Secret | `RELAY_TUNNEL_KEY` | Tunnel private key (`~/.buildhub-debug-ssh/<relay>/tunnel_ed25519`) |
| Variable | `RELAY_HOST` | Relay IP |
| Variable | `RELAY_KNOWN_HOSTS` | Relay host key line, e.g. `1.2.3.4 ssh-ed25519 AAAA…` |

For org-level values, give the repos access under **Repository access**.

### 4. Workflow

```yaml
on:
  push:
  workflow_dispatch:
    inputs:
      debug_enabled:
        type: boolean
        default: false

jobs:
  build:
    runs-on: <your-bitrise-runner-label>
    steps:
      # ... your steps ...
      - name: Debug SSH
        if: ${{ failure() || inputs.debug_enabled }}
        uses: naveen-bitrise/buildhub-debug-ssh@v1
        with:
          relay-host: ${{ vars.RELAY_HOST }}
          relay-known-hosts: ${{ vars.RELAY_KNOWN_HOSTS }}
          tunnel-key: ${{ secrets.RELAY_TUNNEL_KEY }}
```

Full example: [`examples/workflow.yml`](examples/workflow.yml).

#### Inputs

| Input | Default | |
|---|---|---|
| `relay-host` | required | Relay IP or hostname |
| `relay-known-hosts` | required | Relay host key line |
| `tunnel-key` | required | Tunnel private key (secret) |
| `github-users` | user who ran the job | Comma-separated GitHub users allowed in |
| `start-minutes` | `30` | Initial session length |
| `extend-minutes` | `15` | Added by each `~/debug-extend` |
| `max-minutes` | `120` | Total cap, extensions included |
| `sshd-port` | `10022` | Must match the warm-up's `DEBUG_SSHD_PORT` |

## Using a session

1. Make sure your SSH public key is on your GitHub profile (`github.com/settings/keys`).
2. Run the workflow with **debug_enabled**, or wait for a step to fail.
3. Copy the command from the job summary, e.g.
   ```bash
   ssh -o HostKeyAlias=buildhub-123-1 -p 23456 vagrant@1.2.3.4
   ```
   Check the runner host key fingerprint against the one in the summary on first connect.
4. Inside the session:

| Command | |
|---|---|
| `~/debug-status` | Time left |
| `~/debug-extend` | Add 15 min (up to the cap) |
| `~/debug-done` | Finish now; the job continues |

The job's workspace is under `~/actions-runner/_work/`.

## Security

- **Who can get in:** only the GitHub users in `github-users` (default: whoever ran the job), with the keys on their GitHub profile. Keys are removed when the session ends.
- **On the runner:** the debug SSH server listens only on `127.0.0.1`, accepts keys only, and refuses root. The session runs as the runner user, which can typically `sudo`. That is the same power every step of the job already has.
- **On the relay:** the `tunnel` account can only open reverse tunnels (no shell). The relay never sees developer keys or session contents.
- **Secrets:** the tunnel private key is the only secret. It can open tunnels on the relay and nothing else. Never put it in a variable or commit it; the relay setup keeps it in `~/.buildhub-debug-ssh/`, outside any repo.
- **Don't run it for untrusted code:** avoid `pull_request_target` and pull requests from forks.
- **Pin versions:** use `@v1`, or a commit SHA for the strictest setups.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `tunnel-key is empty` | `RELAY_TUNNEL_KEY` secret missing, or the repo has no access to the org secret |
| `Debug sshd is not running on this runner` | Warm-up snippet missing or failed; check the warm-up log for `debug-sshd:` lines |
| Runner VMs fail to start after adding the warm-up | Port clash. Don't use `2222`; keep the default `10022` |
| `Tunnel … failed` / `Host key verification failed` | `RELAY_KNOWN_HOSTS` doesn't match the relay (e.g. its IP changed); re-run the relay setup and update the variables |
| `Permission denied (publickey)` when connecting | Your key isn't on your GitHub profile, or you aren't the user who ran the job (use `github-users`) |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Use the full command from the summary (it includes `HostKeyAlias`) |

## Repository layout

```
action.yml                 the action (works with any relay)
scripts/debug-session.sh   session logic used by the action
warmup/                    warm-up snippet for Build Hub runner pools
relays/                    relay setup: gcp/, generic/ (aws/ planned)
examples/                  example workflow
```
