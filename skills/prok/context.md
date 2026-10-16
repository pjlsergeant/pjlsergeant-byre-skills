# prok (byre skill)

prok is a self-hosted ngrok. A client holding the shared token claims a
hostname on the relay for exactly as long as its tunnel process lives —
no DNS, cert, or cleanup per name. A bare name comes up at
`https://<name>.$PROK_RELAY`; a full hostname on another domain the relay
serves is claimed as given.

Use the `prok` command (on `PATH`; run it bare for the full docs):

```sh
prok up <name> <port> [user:pass]       # foreground; prints https://<name>.$PROK_RELAY
prok up <hostname> <port> [user:pass]   # same, for a full hostname the relay serves
prok status [<name|hostname>]           # each tunnel: hostname, URL, state
prok down [<name|hostname>]             # kill the process = release the hostname
```

`up` fails fast — non-zero exit, frpc killed — when the hostname is taken
anywhere on the relay. That is the wrapper's reason to exist: raw frpc
treats a taken name as a mere log warning, sits alive retrying every
~30s, and silently seizes the name (exposing your port under it) the
moment its holder disconnects. Don't drive `frpc` by hand unless prok
itself is broken; if you must, start from the config in `prok`'s source —
it pins `transport.tls.trustedCaFile`, without which frpc skips server
certificate verification entirely — and kill the process yourself on any
`start error` log line.

## Rules

- `<name>` is ONE lowercase DNS label ([a-z0-9-], max 63 chars) and lands
  under `$PROK_RELAY`. A `<hostname>` is lowercase labels joined by dots,
  claimed exactly as given. Hostnames are unique across ALL clients of
  the relay.
- Which domains the relay serves, and who can reach each of them, is the
  relay operator's decision — look for it in your project guidance. A
  hostname on a domain the relay does not route is accepted and shows
  `running`, but nothing answers it; set `PROK_KNOWN_DOMAINS` and prok
  warns about such a hostname before claiming it.
- Unless your project guidance says a domain is restricted, assume anyone
  can reach it: scanners find new hostnames within minutes. Only expose
  throwaway, sacrificial services there; add a random suffix, and gate
  anything sensitive with `[user:pass]` — HTTP basic auth the relay
  enforces (401 without credentials), no setup needed.
- HTTP only (websockets fine); no raw TCP/UDP.

## Environment

`PROK_AUTHTOKEN` and `PROK_RELAY` are required; if missing, tell the user
to set them and relaunch — the token via `byre credentials set
PROK_AUTHTOKEN` or `env_from_host`, never a baked `[env]` literal;
`PROK_RELAY` (the relay base hostname) is not a secret and any form is
fine. `PROK_KNOWN_DOMAINS` is optional: a comma-separated list of the
other domains the relay serves, not a secret, `[env]` is fine. There is
no interactive login flow.

## Network

Egress is `$PROK_RELAY` on 443 (the control channel is a WebSocket to it;
nothing on 7000). The relay is deployment-specific, so the project config
opens the door itself: `egress = ["<relay>"]`, plus each `<hostname>` the
box should be able to curl itself. Whether the box can reach a hostname
at all depends on that domain's setup, not only on egress.
