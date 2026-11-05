# buildhub-debug-ssh

SSH into the **Bitrise Build Hub** runner that is running your GitHub Actions job, to debug a failure live. No Bitrise admin rights, no third-party relay, no passwords.

- A developer who triggered (or re-ran) a job can SSH into **that job's runner** with the SSH key on their GitHub profile.
- Sessions start on demand, last 30 minutes by default, and can be extended from inside the session.
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
   - prints the connect command in the job log (and as a run annotation),
   - keeps the job alive until the developer finishes or time runs out.
3. **Developer** runs the command printed in the job log (the job is paused at the Debug SSH step). Only their GitHub keys work. The SSH session is end to end between the developer and the runner; the relay only forwards bytes.

## Setup (one-time)

### 1. Relay

Pick one (see [relays/](relays/README.md)):

| Relay | Setup |
|---|---|
| Google Cloud VM | [`relays/gcp/`](relays/gcp/README.md): `./relays/gcp/setup-relay.sh` |
| Any Linux VM | [`relays/generic/`](relays/generic/README.md): manual steps |

**What you get:** when the relay setup finishes, it prints three values. You store them in GitHub (step 3), and the workflow passes them to the **Debug SSH** action as its three required inputs:

| Printed by the relay setup | Store in GitHub as | Action input |
|---|---|---|
| Relay IP | Variable `RELAY_HOST` | `relay-host` |
| Relay host key line (`1.2.3.4 ssh-ed25519 AAAA…`) | Variable `RELAY_KNOWN_HOSTS` | `relay-known-hosts` |
| Path to the tunnel private key (`~/.buildhub-debug-ssh/<relay>/tunnel_ed25519`) | Secret `RELAY_TUNNEL_KEY` (the file's contents) | `tunnel-key` |

### 2. Runner pool warm-up

Add [`warmup/warmup-debug-sshd.sh`](warmup/README.md) to the Build Hub runner pool's warm-up script: append it to the end of an existing warm-up script, or use it as the whole script if the pool has none. It never fails the warm-up.

### 3. GitHub secret and variables

In the repo (or org) that runs the jobs, go to **Settings → Secrets and variables → Actions** and add the three values from step 1:

| Type | Name | Value |
|---|---|---|
| Secret | `RELAY_TUNNEL_KEY` | Contents of the tunnel private key file, including the `BEGIN`/`END` lines |
| Variable | `RELAY_HOST` | Relay IP |
| Variable | `RELAY_KNOWN_HOSTS` | Relay host key line |

The relay setup also prints ready-to-run `gh secret set` / `gh variable set` commands. For org-level values, give the repos access under **Repository access**.

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
        if: ${{ !cancelled() && (inputs.debug_enabled || (failure() && runner.debug == '1')) }}
        uses: naveen-bitrise/buildhub-debug-ssh@v1
        with:
          relay-host: ${{ vars.RELAY_HOST }}
          relay-known-hosts: ${{ vars.RELAY_KNOWN_HOSTS }}
          tunnel-key: ${{ secrets.RELAY_TUNNEL_KEY }}
```

Full example: [`examples/workflow.yml`](examples/workflow.yml).

**When does a session open?** Only when someone asks for it:

- **Run workflow** manually with **debug_enabled** ticked, or
- **Re-run** a failed job with **Enable debug logging** ticked; the session opens if it fails again.

It deliberately doesn't open on every failure: each session holds the runner until it ends, even if nobody connects. To debug every failure anyway, use `if: ${{ failure() }}` with a short `start-minutes`.

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

### Prerequisite: your SSH key on GitHub

The runner only lets in the SSH keys on your GitHub profile. Do this once per computer.

1. Check for an existing key:
   ```bash
   ls ~/.ssh/*.pub
   ```
2. If there's none, create one:
   ```bash
   ssh-keygen -t ed25519 -C "you@example.com"
   ```
3. Add the **public** key (`.pub`) to GitHub, either at **GitHub → Settings → SSH and GPG keys → New SSH key**, or with the CLI:
   ```bash
   gh ssh-key add ~/.ssh/id_ed25519.pub --title "Work laptop"
   ```
4. Check it's the key GitHub has: compare the fingerprint from `ssh-keygen -lf ~/.ssh/id_ed25519.pub` with the one shown on the GitHub SSH keys page, or run `ssh -T git@github.com`.

### Connect

1. Start a session: **Run workflow** with **debug_enabled**, or **Re-run** a failed job with **Enable debug logging**.
2. Open the running job and expand the **Debug SSH** step. The job stays paused at this step and the log shows:
   ```
   ================================================================
    DEBUG SSH SESSION: job paused at this step
   ================================================================
    Connect (only your-github-user, with the SSH key on their GitHub profile):

      ssh -o HostKeyAlias=buildhub-123-1 -p 23456 vagrant@1.2.3.4

    Runner host key fingerprint: SHA256:…
   ```
   The same command also appears as an annotation at the top of the run's summary page.
3. Run that command. On first connect, check that the host key fingerprint matches the one in the log.
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
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | Use the full command from the job log (it includes `HostKeyAlias`) |
| Debug SSH step skipped | The `if:` didn't match: start with **debug_enabled**, or re-run with **Enable debug logging** |

## Repository layout

```
action.yml                 the action (works with any relay)
scripts/debug-session.sh   session logic used by the action
warmup/                    warm-up snippet for Build Hub runner pools
relays/                    relay setup: gcp/, generic/ (aws/ planned)
examples/                  example workflow
```
