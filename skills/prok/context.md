# prok (byre skill)

prok is a self-hosted ngrok: an frps relay behind Cloudflare. A client
holding the shared token claims `https://<name>.$PROK_RELAY` for exactly
as long as its tunnel process lives — no DNS, cert, or cleanup per name.

Use the `prok` command (on `PATH`; run it bare for the full docs):

```sh
prok up <name> <port> [user:pass]   # foreground; prints the URL
prok status [<name>]                # each tunnel: name, URL, state
prok down [<name>]                  # kill the process = release the name
```

`up` fails fast — non-zero exit, frpc killed — when the name is taken
anywhere on the relay. That is the wrapper's reason to exist: raw frpc
treats a taken name as a mere log warning, sits alive retrying every
~30s, and silently seizes the name (exposing your port under it) the
moment its holder disconnects. Don't drive `frpc` by hand unless prok
itself is broken; if you must, start from the config in `prok`'s source —
it pins `transport.tls.trustedCaFile`, without which frpc skips server
certificate verification entirely — and kill the process yourself on any
`start error` log line.

## Rules

- `<name>` is ONE lowercase DNS label, no dots, unique across ALL
  clients of the relay.
- Names are PUBLIC and guessable the moment the proxy starts; scanners
  find new hostnames within minutes. Only expose throwaway, sacrificial
  services; add a random suffix, and gate anything sensitive with
  `[user:pass]` — HTTP basic auth the relay enforces (401 without
  credentials), no setup needed.
- HTTP only (websockets fine); no raw TCP/UDP.

## Environment

Both required; if missing, tell the user to set them and relaunch — the
token via `byre credentials set PROK_AUTHTOKEN` or `env_from_host`,
never a baked `[env]` literal; `PROK_RELAY` (the relay base hostname) is
not a secret and any form is fine. There is no interactive login flow.

## Network

Egress is `$PROK_RELAY` on 443 only (the control channel is a WebSocket
through Cloudflare; nothing on 7000). The relay is deployment-specific,
so the project config opens the door itself: `egress = ["<relay>"]`,
plus `<name>.<relay>` if the box should curl its own tunnels.
