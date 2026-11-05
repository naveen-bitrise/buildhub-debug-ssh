# Generic relay (any Linux VM)

Manual setup for any Debian/Ubuntu VM with a public IP, on any cloud or on-prem. Run as root on the relay unless noted.

## 1. Create the tunnel key (on your machine, not the relay)

```bash
mkdir -p ~/.buildhub-debug-ssh/my-relay && chmod 700 ~/.buildhub-debug-ssh/my-relay
ssh-keygen -t ed25519 -N "" -C tunnel -f ~/.buildhub-debug-ssh/my-relay/tunnel_ed25519
```

Keep this folder private: the private key becomes the `RELAY_TUNNEL_KEY` GitHub secret.

## 2. Tunnel user (on the relay)

```bash
useradd -m -s /bin/bash tunnel
install -d -m 700 -o tunnel -g tunnel /home/tunnel/.ssh
echo "<contents of tunnel_ed25519.pub>" > /home/tunnel/.ssh/authorized_keys
chown tunnel:tunnel /home/tunnel/.ssh/authorized_keys && chmod 600 /home/tunnel/.ssh/authorized_keys
```

## 3. Lock the tunnel user down

```bash
cat >> /etc/ssh/sshd_config <<'EOF'

# BEGIN debug-relay
Match User tunnel
  AllowTcpForwarding remote
  GatewayPorts clientspecified
  PermitListen any
  PermitTTY no
  X11Forwarding no
  AllowAgentForwarding no
  ForceCommand /bin/false
# END debug-relay
EOF
sshd -t && systemctl restart ssh
```

## 4. Tunnel port range

```bash
echo 'net.ipv4.ip_local_port_range = 20000 29999' > /etc/sysctl.d/90-debug-relay.conf
sysctl --system
```

## 5. Firewall

Allow inbound `tcp:22` and `tcp:20000-29999` (cloud security group / `ufw` / `nftables`). Optionally restrict sources to your runners' egress IPs and your developers' IPs.

## 6. Host key line (on your machine)

```bash
ssh-keyscan -t ed25519 <relay-ip> 2>/dev/null | grep -v '^#'
```

Compare its fingerprint (`ssh-keygen -lf <file>`) with the relay's own (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the relay).

## 7. Check

```bash
# Opens a public tunnel port (prints "Allocated port N"); Ctrl-C to stop
ssh -i ~/.buildhub-debug-ssh/my-relay/tunnel_ed25519 -N -R 0.0.0.0:0:localhost:9 tunnel@<relay-ip>
# Must NOT give a shell
ssh -i ~/.buildhub-debug-ssh/my-relay/tunnel_ed25519 tunnel@<relay-ip> id
```

Then set the GitHub secret and variables as in the [main README](../../README.md#3-github-secret-and-variables).
