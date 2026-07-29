#!/bin/sh
# codex-login — sign the box's codex CLI in, headlessly.
#
# Shipped by the codereview skill because codex is its default reviewer, and a
# byre box has no browser: plain `codex login` starts a browser-redirect flow
# that cannot complete here, and the failure is opaque enough that people retry
# it. This wrapper exists so the working incantation is a command name rather
# than a flag someone has to remember (or rediscover from a debug log).
#
# --device-auth prints a URL + code to authenticate on another device. It needs
# a terminal: run this from `byre shell`, not from an agent's tool call.
set -eu

if ! command -v codex >/dev/null 2>&1; then
  echo "codex-login: codex not found on PATH." >&2
  echo "  Add the codex skill to this box's config and rebuild." >&2
  exit 127
fi

# Args are appended AFTER --device-auth, so this is a wrapper for the zero-arg
# recovery flow, not a general front-end for `codex login`. The other login
# modes do NOT work through it -- `codex-login status` becomes
# `codex login --device-auth status`, and --with-api-key is a separate mode
# that would be stacked on top of device auth rather than replacing it. For
# those, call `codex login` directly. Pass-through is kept only so compatible
# extras (a -c config override) remain reachable.
exec codex login --device-auth "$@"
