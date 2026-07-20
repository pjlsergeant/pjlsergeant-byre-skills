#!/bin/sh
# ngrok authtoken firstrun hook -- runs as the dev user, each launch, before
# the agent starts. If NGROK_AUTHTOKEN is set, apply it via `ngrok config
# add-authtoken`. That command is idempotent and cheap (it just rewrites the
# config file's authtoken field), so running it every launch keeps the
# config in sync with the declared env var with no state to track. The
# config itself lives in the "ngrok" state volume (see skill.toml), so a
# token applied once survives rebuilds even without this hook re-running --
# this just keeps the env var authoritative if the user changes it.
#
# Unlike codex/grok's device-auth firstrun hooks, there is no interactive
# flow here: a missing token is a silent no-op, never a launch-blocking
# prompt (ngrok's own SKILL.md tells the agent what to do about a missing
# token when it actually tries to use ngrok).
command -v ngrok >/dev/null 2>&1 || exit 0
[ -n "$NGROK_AUTHTOKEN" ] || exit 0
ngrok config add-authtoken "$NGROK_AUTHTOKEN" >/dev/null 2>&1 || true
