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

# Args are appended AFTER --device-auth, so this wraps the zero-arg recovery
# flow rather than fronting all of `codex login`. Subcommands survive the
# ordering -- `codex-login status` runs status fine (clap takes the flag before
# the subcommand, verified) -- but an alternate login MODE does not:
# --with-api-key lands on top of device auth instead of replacing it, so you
# get the device flow either way. Use `codex login --with-api-key` directly for
# that. Pass-through is kept so compatible extras (a -c config override) stay
# reachable.
exec codex login --device-auth "$@"
