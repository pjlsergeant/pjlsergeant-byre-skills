#!/bin/sh
# vibe-login -- log the box's vibe in to Mistral (store a Mistral API key).
#
# A thin wrapper over `vibe --setup` (the codex-login / mimo-login
# precedent: the working incantation as a command name). That is Vibe's
# own interactive onboarding TUI (vibe/cli/cli.py:470-477): "Launch
# browser" (Mistral AI Studio sign-in: it shows a URL to open on the HOST
# and polls until you finish there, vibe/setup/auth/browser_sign_in.py:
# 122-135) or "Use an API key" (paste one). The key lands in
# $VIBE_HOME/.env (~/.vibe/.env, the per-project .vibe state volume) --
# there is no keyring in a box (setup/auth/api_key_persistence.py:217-245).
#
# It needs a terminal: run it from `byre shell`, not from an agent's tool
# call (the TUI would just hang). Extra args pass through.
set -u

if ! command -v vibe >/dev/null 2>&1; then
  echo "vibe-login: vibe not found on PATH (add the pjlsergeant/vibe skill and rebuild)." >&2
  exit 127
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "vibe-login: needs a terminal -- run this from \`byre shell\`, not from an agent." >&2
  exit 1
fi

# The setup writes .env with a `touch` that FOLLOWS a symlink
# (api_key_persistence.py:25-33), and `byre shell` is a plain `docker exec`
# that never re-runs the firstrun hooks -- so a link planted after launch
# would be written through. Same rule as the login hook (vibe-login.sh; keep
# the two in step): no symlink is legitimate at .env, and nothing that is
# not a regular file is vibe's. Refuse and touch nothing.
envfile="${VIBE_HOME:-/home/dev/.vibe}/.env"
if [ -L "$envfile" ] || { [ -e "$envfile" ] && [ ! -f "$envfile" ]; }; then
  echo "vibe-login: $envfile is a symlink or not a regular file; not logging in -- inspect it and remove it if it is not yours." >&2
  exit 1
fi

echo "Choose 'Launch browser' and open the sign-in URL it shows in a browser on your HOST"
echo "(the URL appears after a few seconds; press 'c' to copy it),"
echo "or 'Use an API key' and paste a Mistral API key (console.mistral.ai)."
echo "Stored for this project only (~/.vibe/.env; it survives rebuilds)."
if [ -n "${MISTRAL_API_KEY:-}" ]; then
  echo "Note: MISTRAL_API_KEY is set in this environment and wins over the stored key."
fi
echo ""

# No browser in a box: without this, Vibe's sign-in aborts before it ever
# polls. Rationale and source refs: skill.toml [runtime], BROWSER=true.
export BROWSER=true
exec vibe --setup "$@"
