#!/bin/sh
# grok-login — sign the box's grok CLI in, headlessly.
#
# Companion to codex-login; same reasoning (see that file). grok is one of the
# reviewers byre-codereview can drive, and its plain `grok login` is likewise a
# browser flow the box cannot complete.
#
# --device-auth prints a URL + code to authenticate on another device. It needs
# a terminal: run this from `byre shell`, not from an agent's tool call. grok
# accepts --device-code as an alias for the same flag and suggests THAT name in
# its own "Not signed in" error; --device-auth is used here to match codex.
set -eu

if ! command -v grok >/dev/null 2>&1; then
  echo "grok-login: grok not found on PATH." >&2
  echo "  Add the grok skill to this box's config and rebuild." >&2
  exit 127
fi

# Same shape as codex-login: args land after --device-auth, so this wraps the
# zero-arg recovery flow rather than fronting all of `grok login`.
exec grok login --device-auth "$@"
