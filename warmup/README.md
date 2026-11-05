# Warm-up

## Setup

Copy the contents of [`warmup-debug-sshd.sh`](warmup-debug-sshd.sh) and paste it at the end of your Build Hub runner pool's warm-up script.

That's it. New runner VMs will show this line in their warm-up log:

```
debug-sshd: listening on 127.0.0.1:10022 for user vagrant
```

## Good to know

- It adds a small SSH server on each runner that's only reachable through the debug tunnel. Bitrise's own SSH is not touched.
- It never fails the warm-up. If something goes wrong, the VM starts normally and debug SSH is just unavailable on it.
