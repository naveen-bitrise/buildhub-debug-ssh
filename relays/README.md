# Relays

Build Hub runners can't accept incoming connections, so a **relay** sits in the middle: the runner opens a reverse SSH tunnel to it, and the developer connects to the relay's port for that tunnel.

```
Runner VM ──(ssh -R, tunnel key)──▶ Relay :20000-29999 ◀──(ssh -p PORT)── Developer
   debug sshd 127.0.0.1:10022            only forwards bytes        GitHub SSH key
```

The relay is yours. It never sees developer keys or session contents (the SSH session is end to end between the developer and the runner). It only needs a few things.

## What any relay needs

1. **A Linux VM with a public IP** (a small instance is enough; one relay serves every runner and developer).
2. **A `tunnel` user** whose `authorized_keys` holds the tunnel public key, and that can **only** open reverse tunnels:
   ```
   Match User tunnel
     AllowTcpForwarding remote
     GatewayPorts clientspecified
     PermitListen any
     PermitTTY no
     X11Forwarding no
     AllowAgentForwarding no
     ForceCommand /bin/false
   ```
3. **Tunnel ports in a known range**, so the firewall can allow them:
   `sysctl net.ipv4.ip_local_port_range="20000 29999"` (made persistent).
4. **Firewall:** inbound `tcp:22` (runners) and `tcp:20000-29999` (developers). Optionally restricted to known source IPs.
5. **Its host key line** (`<ip> ssh-ed25519 AAAA…`) to give the action as `relay-known-hosts`.

## Options

| Relay | Status | Setup |
|---|---|---|
| Google Cloud VM | ✅ Tested | [`gcp/`](gcp/README.md): script, needs only the Editor role |
| Any Linux VM | ✅ | [`generic/`](generic/README.md): manual steps |
| Google Cloud + IAP (no public SSH, Google sign-in) | Planned | |
| AWS EC2 | Planned | Same as generic, using a security group |
| AWS + SSM Session Manager | Planned | |
