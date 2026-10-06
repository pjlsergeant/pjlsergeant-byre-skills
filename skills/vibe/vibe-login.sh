#!/bin/sh
# vibe first-run auth hook (a port of pjlsergeant/mimo's mimo-login hook,
# simplified) -- runs as the dev user, before the agent launches, on EVERY
# launch (firstrun.d hooks are not one-shot; the guards below make it
# idempotent: any credential in sight and it stands down). If none is, run
# `vibe --setup` so the agent works out of the box.
#
# `vibe --setup` is Vibe's own interactive onboarding, a Textual TUI that
# needs a terminal (vibe/cli/cli.py:470-477 -> vibe/setup/onboarding): a
# welcome and a theme screen, then "Choose your sign in method": "Launch
# browser" (Mistral AI Studio sign-in, screens/browser_sign_in.py -- it
# DISPLAYS the sign-in URL to open on the host and POLLS for completion,
# setup/auth/browser_sign_in.py:122-135, no localhost callback, so it works
# from a box) or "Use an API key" (paste; screens/api_key.py links
# chat.mistral.ai/code/extensions for a Vibe key, :48-53). Either way the
# credential is a Mistral API key, stored by persist_api_key
# (setup/auth/api_key_persistence.py:217-245): the OS keyring first, else
# MISTRAL_API_KEY='...' in $VIBE_HOME/.env (0600). With no D-Bus session
# bus there is no keyring backend, so the key lands in .env, inside the
# .vibe state volume -- once per project, surviving rebuilds. (Driven live
# in a pty in the authoring box, 2026-10-06, paste path with a dummy key:
# .env written 0600 as MISTRAL_API_KEY='<key>', plus a config.toml with
# the theme; this hook then stands down on it.) Best-effort:
# skip with Ctrl-C (or on failure/timeout) and the box still launches --
# log in later with `vibe-login` (this skill's wrapper of `vibe --setup`)
# from `byre shell`, or supply MISTRAL_API_KEY instead.
command -v vibe >/dev/null 2>&1 || exit 0

# A static key in the environment wins over .env (load_dotenv_values skips
# a key the process env already holds non-empty, vibe/core/config/
# vibe_schema.py:99-114), so the login is unnecessary. This sees env_from_host values and, on byre 1.12+,
# `byre credentials` values too -- the launcher exports delivered
# credentials BEFORE the firstrun hooks (byre internal/gen/launcher.sh:
# byre_credentials_apply runs above the firstrun loop). On byre <= 1.11 that
# export came only after every firstrun hook, so such a box is still offered
# the login; Ctrl-C skips it.
[ -n "${MISTRAL_API_KEY:-}" ] && exit 0

# pjlsergeant/vibe-shared-auth's machine-wide key. Its env.d hook exports
# it as MISTRAL_API_KEY, but env.d runs AFTER the firstrun hooks, so the
# variable is not set yet here -- look at the FILE, with the same test the
# companion's env.sh applies (a regular, non-symlink, non-empty file, in a
# dir whose physical path is its spelling: the -L test sees only the leaf,
# and a file reached through a symlinked ANCESTOR, ~/.byre-identity or its
# vibe/ dir pointing elsewhere, is not the identity volume's -- env.sh
# would not export it, so this must not stand down on it). The
# path is HARDCODED, deliberately: the companion's test seam
# (BYRE_IDENTITY_BASE) is env-derived, and anything that reaches the
# container env (byre rejects BYRE_* in a project [env], but run_args or a
# skill runtime env still can) could then point this check at a file it
# planted and silence the login. Worst case of the hardcode: a test box
# with a relocated identity base is offered a login it could skip.
shared_dir=/home/dev/.byre-identity/vibe
shared_key=$shared_dir/api-key
if [ -f "$shared_key" ] && [ ! -L "$shared_key" ] && [ -s "$shared_key" ] \
  && [ "$(cd "$shared_dir" 2>/dev/null && pwd -P)" = "$shared_dir" ]; then
  exit 0
fi

# Vibe's own credential file. VIBE_HOME is honored to stay faithful to
# vibe's resolution (vibe/utils/vibe_home.py:10-13; also the test seam),
# but byre's .vibe volume only covers the default -- unsupported in [env].
# No symlink is ever legitimate here (the companion shares an env var, not
# this file), and a write would go THROUGH one: persist_api_key's
# `touch(exist_ok=True)` follows a link and creates a dangling target
# (api_key_persistence.py:25-33). Anything else that is not a regular file
# (a FIFO, a directory) is not something vibe --setup wrote: grep would
# block on a FIFO, and this runs before the tty guard, so a plant would
# hang a headless launch. (Vibe itself READS a FIFO .env -- 1Password's
# local env files, vibe_schema.py:103-105 -- and still does: standing down
# here leaves that setup working, it just isn't offered the login.)
# Never delete an unknown object -- say so and stop, touching nothing.
envfile="${VIBE_HOME:-/home/dev/.vibe}/.env"
if [ -L "$envfile" ] || { [ -e "$envfile" ] && [ ! -f "$envfile" ]; }; then
  echo "byre: $envfile is a symlink or not a regular file; not reading it and not offering the vibe login -- inspect it in byre shell" >&2
  exit 0
fi
# A stored key: a MISTRAL_API_KEY line with a non-empty value. python-
# dotenv's set_key writes `MISTRAL_API_KEY='...'` (quoted); a hand-written
# file may be bare or `export`-prefixed. Empty or whitespace-only values
# ('', "", '  ') don't count: a quoted value needs a non-space character
# inside the quotes, a bare one starts with one.
# Not caught: a revoked key -- that surfaces at use time ("Invalid API key").
if [ -f "$envfile" ] && grep -Eq "^[[:space:]]*(export[[:space:]]+)?MISTRAL_API_KEY[[:space:]]*=[[:space:]]*([^[:space:]'\"#]|'[^']*[^[:space:]']|\"[^\"]*[^[:space:]\"])" "$envfile" 2>/dev/null; then
  exit 0
fi

# Interactive only: the TUI needs a terminal, and a non-interactive launch
# must not sit blocked until the timeout.
[ -t 0 ] || exit 0

# Clean skip on Ctrl-C: exit 0 so no signal-death propagates toward the
# launcher -- the box proceeds to the agent regardless.
trap 'echo; echo "byre: vibe login skipped. To do it later, open another terminal and run '\''byre shell'\'', then '\''vibe-login'\'' (it wraps '\''vibe --setup'\'')."; exit 0' INT

echo ""
echo "=== byre: first-run Mistral Vibe login ==="
echo "Choose 'Launch browser' and open the sign-in URL it shows in a browser on your host"
echo "(the URL appears after a few seconds; press 'c' to copy it),"
echo "or 'Use an API key' and paste a Mistral API key (console.mistral.ai)."
echo "Stored per-project, survives rebuilds. Ctrl-C to skip (or set MISTRAL_API_KEY instead,"
echo "or enable pjlsergeant/vibe-shared-auth to share one key across projects)."
echo "Later, or again: 'vibe-login' in 'byre shell' (it wraps 'vibe --setup')."
echo ""
# No browser in a box: without this, Vibe's sign-in aborts before it ever
# polls. Rationale and source refs: skill.toml [runtime], BROWSER=true.
export BROWSER=true
# Bound the wait; --foreground keeps vibe in the terminal's foreground
# process group so Ctrl-C reaches it immediately.
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout --foreground 600"
$TO vibe --setup \
  || echo "byre: vibe login didn't complete. To do it later, open another terminal and run 'byre shell', then 'vibe-login' (it wraps 'vibe --setup')." >&2
exit 0
