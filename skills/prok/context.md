# prok (byre skill)

`frpc` (frp v0.71.0) is on `PATH`. prok is a self-hosted ngrok: an frps
relay behind Cloudflare. A client holding the shared token claims
`https://<name>.$PROK_RELAY` for exactly as long as its frpc process stays
connected — no DNS, cert, or cleanup per name. `PROK_AUTHTOKEN` and
`PROK_RELAY` are required in the environment; if either is missing, tell
the user to set it in the project config and relaunch.

## Running a tunnel

Write a config, run it in the foreground; the name lives while the process
does:

```sh
cat > /tmp/frpc-<name>.toml <<'EOF'
serverAddr = '{{ .Envs.PROK_RELAY }}'
serverPort = 443
transport.protocol = "wss"
transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"
auth.token = '{{ .Envs.PROK_AUTHTOKEN }}'

[[proxies]]
name = "<name>"
type = "http"
subdomain = "<name>"
localPort = <port>
EOF
frpc -c /tmp/frpc-<name>.toml
```

The `{{ .Envs... }}` templates are expanded by frpc itself, so the token
never lands in the file. Always use this form — the bare `frpc http ...`
one-liner cannot set `trustedCaFile`, and without it frpc skips
certificate verification entirely, letting anyone on the network path
impersonate the relay and capture the token.

## Rules

- `<name>` is ONE lowercase DNS label, no dots; use the same value for
  `name` and `subdomain`.
- A taken name fails with `start error: router config conflict` (the
  subdomain) or `proxy [...] already exists` (the proxy name) — as a `[W]`
  log line, not an exit. frpc stays up and retries every ~30s, and would
  silently grab the name (exposing your port under it) the moment its
  owner disconnects: kill the process, then retry with a different name.
- The only success signal is `start proxy success` in YOUR process's log.
  A successful curl proves nothing during a collision — the current owner
  answers, not you.
- Names are PUBLIC the moment the proxy starts; scanners find them within
  minutes. Only expose throwaway, sacrificial services.
- HTTP only (websockets fine); no raw TCP/UDP.
- Kill the process to release the name; it is reusable immediately.

## Network

Egress is `$PROK_RELAY` on 443 only (the control channel is a WebSocket
through Cloudflare; nothing on 7000). The relay is deployment-specific, so
the project config opens the door itself: `egress = ["<relay>"]`, plus
`<name>.<relay>` if the box should curl its own tunnels.
