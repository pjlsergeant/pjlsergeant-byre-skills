# prok (byre skill)

`frpc` (frp v0.71.0) is installed and on `PATH`. prok is a self-hosted
ngrok: an frps relay runs behind Cloudflare, and a client holding the
shared token can claim `https://<name>.$PROK_RELAY` for exactly as long as
its frpc process stays connected. No DNS, cert, or cleanup per name.

## The whole command

```sh
frpc http -s "$PROK_RELAY" -P 443 -p wss -t "$PROK_AUTHTOKEN" \
     -n <name> --sd <name> -l <port>
```

It runs in the foreground; the name lives while the process does. Both env
vars are required (`PROK_AUTHTOKEN` is the shared secret, `PROK_RELAY` the
relay's base hostname) — if either is missing, tell the user to set it in
the project config and relaunch; there is no interactive login flow.

## Rules

- `<name>` is ONE lowercase DNS label, no dots; it becomes
  `https://<name>.$PROK_RELAY`.
- `-n` must be unique across all clients of the relay; always pass the same
  value as `--sd`. A `--sd` already claimed by another client fails with
  `start error: router config conflict`; reusing another client's `-n`
  fails with `start error: proxy [<name>] already exists`. Either way: pick
  another name.
- A conflict does NOT kill the process — frpc logs the error as a `[W]`
  warning and stays connected with the name dead. The only success signal
  is the `start proxy success` log line: check the log for it (or curl the
  URL) before handing the URL to anyone.
- Names are PUBLIC the moment the proxy starts — scanners find new
  hostnames within minutes. Only expose throwaway, sacrificial services:
  nothing holding credentials, private data, or state you can't afford to
  lose.
- HTTP only (websockets fine); raw TCP/UDP is not available.
- Kill the frpc process to take the name down; it is released for reuse
  immediately.

## Network

The control channel is a WebSocket to `$PROK_RELAY` on 443 — nothing on
7000. The relay hostname is deployment-specific, so this skill cannot
declare the egress itself: with a network-posture skill enabled, the
project config must open the door (`egress = ["<relay>"]`, and
`<name>.<relay>` too if you want to curl your own tunnel from inside the
box).
