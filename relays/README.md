# Relays

Build Hub runners can't accept incoming connections, so a **relay** sits in the middle:

```
  Your laptop  ───ssh───▶  Relay VM  ◀───tunnel───  Runner VM
```

The runner opens a tunnel to the relay; you connect to the relay, and it passes you through to the runner.

The relay is just a small Linux VM with a public IP that **you** own. It can run anywhere: **Google Cloud, AWS, Azure, or your own servers**. It only forwards the connection; it can't see your keys or what you type. One relay serves all runners and developers.

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
