# Google Cloud relay

`setup-relay.sh` turns an **existing** Compute Engine VM into a relay. It needs only the **Editor** role on the project (no IAM changes).

## Prerequisites

- A small VM (e.g. `e2-micro`, Debian or Ubuntu image) in your project
- [`gcloud`](https://cloud.google.com/sdk/docs/install) on your machine, logged in (`gcloud auth login`)
- The Editor role on the project

## Run

```bash
./relays/gcp/setup-relay.sh
```

It asks for the VM name, project and zone (or set `VM`, `PROJECT`, `ZONE` as env vars) and confirms before changing anything. Answers are saved, so re-runs don't ask again.

## What it does

| Step | Change |
|---|---|
| 1. Tunnel key | Creates `~/.buildhub-debug-ssh/<vm>/tunnel_ed25519` on **your machine** (outside any repo) |
| 2. External IP | Adds one if missing; offers to make it static |
| 3. Firewall | Rule `debug-relay-allow`: `tcp:22,20000-29999` to VMs tagged `debug-relay` |
| 4. Tunnel user | Adds the tunnel public key to the VM's `ssh-keys` metadata (keeps existing keys) |
| 5. Lockdown | Startup script: tunnel user can only open reverse tunnels; tunnel port range 20000-29999. Turns OS Login off for this VM so metadata keys work |
| 6. Tests | Tunnel opens on a port in range, that port is reachable, tunnel user has no shell |

At the end it prints the GitHub secret and variables to set, with ready-to-run `gh` commands.

## Options

| Env var | Effect |
|---|---|
| `ALLOWED_SOURCES=1.2.3.0/24,5.6.7.8/32` | Only these IPs can reach the relay (default: any IP, key-only login) |
| `BUILDHUB_DEBUG_SSH_HOME=/path` | Where local state is kept (default `~/.buildhub-debug-ssh`) |

## If the IP changes

The external IP only changes if the VM is **stopped and started** (not on reboot) and the IP isn't static. Re-run the script and update the `RELAY_HOST` and `RELAY_KNOWN_HOSTS` variables with the values it prints.

## Remove

```bash
gcloud compute firewall-rules delete debug-relay-allow debug-relay-deny --quiet
gcloud compute instances delete <vm> --zone <zone>
rm -rf ~/.buildhub-debug-ssh/<vm>
```

Then delete the `RELAY_*` secret and variables in GitHub.

## Known limits

- If an organization policy forces OS Login or blocks external IPs, the script's tests fail. Use the (planned) IAP option instead.
- Port 22 and the tunnel ports are reachable from the internet unless `ALLOWED_SOURCES` is set. All logins are key-only, and the tunnel user has no shell.
