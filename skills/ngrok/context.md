# ngrok (byre skill)

The `ngrok` CLI is installed and on `PATH`. It exposes a local port through a
secure tunnel to a public URL — useful for testing webhooks, sharing a
running dev server, or letting someone else hit a service that's only
listening on this box.

## Auth

Set `NGROK_AUTHTOKEN` (get one at https://dashboard.ngrok.com/get-started/your-authtoken)
and it's applied automatically at every launch — nothing to run by hand. If
it's missing when you try to use ngrok, `ngrok config check` will say so;
tell the user to set the env var and relaunch, or run
`ngrok config add-authtoken <TOKEN>` yourself for the rest of this session.

ngrok's config (the authtoken, plus anything else `ngrok config` writes)
lives in a per-project state volume, so it survives rebuilds independent of
the env var being set again.

## Using it well

Don't just run `ngrok http <port>` and stop there. This box ships the
`expose-localhost` Claude Skill (from ngrok's own `ngrok/agent-skills`
collection, MIT-licensed) with the actual workflow: detecting the right
port from `package.json`/`.env`/`docker-compose.yml`, asking about a custom
domain and access control *before* starting anything, and wiring up OAuth,
rate-limiting, or OWASP protection via Traffic Policy when asked. Prefer it
over improvising.

## Network

If a firewall skill is enabled, ngrok needs outbound access to
`connect.ngrok-agent.com` (tunnel establishment), `api.ngrok.com` (auth,
domains, cloud endpoints), and `update.equinox.io` (self-update checks) —
declared as this skill's `egress`, so a firewall skill should pick them up
automatically.
