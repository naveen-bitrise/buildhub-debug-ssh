// Entry point for the action (JavaScript action, so the log streams live).
// Runs scripts/debug-session.sh with the action inputs mapped to env vars.
// No dependencies.

const { spawn } = require("child_process");
const path = require("path");

const input = (name) => process.env[`INPUT_${name.toUpperCase()}`] || "";

const env = {
  ...process.env,
  RELAY_HOST: input("relay-host"),
  RELAY_KNOWN_HOSTS: input("relay-known-hosts"),
  RELAY_TUNNEL_KEY: input("tunnel-key"),
  GITHUB_USERS: input("github-users"),
  ACTOR: process.env.GITHUB_TRIGGERING_ACTOR || process.env.GITHUB_ACTOR || "",
  DEBUG_START_MINUTES: input("start-minutes") || "30",
  DEBUG_EXTEND_MINUTES: input("extend-minutes") || "15",
  DEBUG_MAX_MINUTES: input("max-minutes") || "120",
  DEBUG_SSHD_PORT: input("sshd-port") || "10022",
};

const script = path.join(__dirname, "scripts", "debug-session.sh");
const child = spawn("bash", [script], { env, stdio: "inherit" });

// Forward cancellation to the script so it cleans up (closes the tunnel, removes keys)
for (const sig of ["SIGINT", "SIGTERM"]) {
  process.on(sig, () => child.kill(sig));
}

child.on("exit", (code, signal) => {
  process.exit(code ?? (signal ? 1 : 0));
});
child.on("error", (err) => {
  console.log(`::error::Could not start debug session: ${err.message}`);
  process.exit(1);
});
