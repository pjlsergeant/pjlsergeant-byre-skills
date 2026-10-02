#!/bin/sh
# mimo-login -- log the box's mimo in to Xiaomi MiMo (platform or Token Plan).
#
# A thin wrapper over `mimo auth login -p xiaomi` (the codex-login precedent:
# the working incantation as a command name). That login is a paste-code
# flow, the Claude Code shape (MiMo-Code cli/cmd/providers.ts mimoLogin,
# plugin/mimo.ts): mimo mints a keypair, prints a
# https://platform.xiaomimimo.com/authorize?... URL, and the code you paste
# back is ciphertext only THIS process can decrypt -- so there is no key to
# copy from elsewhere, and no way around running it here. Its xdg-open
# attempt fails in a box with a harmless warning.
#
# It needs a terminal: run it from `byre shell`, not from an agent's tool
# call (the paste prompt would just hang). Extra args pass through.
set -u

if ! command -v mimo >/dev/null 2>&1; then
  echo "mimo-login: mimo not found on PATH (add the pjlsergeant/mimo skill and rebuild)." >&2
  exit 127
fi
if [ ! -t 0 ] || [ ! -t 1 ]; then
  echo "mimo-login: needs a terminal -- run this from \`byre shell\`, not from an agent." >&2
  exit 1
fi

# The login writes auth.json IN PLACE (filesystem.ts:80), i.e. THROUGH a
# symlink, and `byre shell` is a plain `docker exec` that never re-runs the
# firstrun hooks (byre internal/commands/shell.go) -- so a link planted after
# launch would be written through. Same trust rule as the login hook
# (mimo-login.sh; this mirrors it -- keep the two in step): only
# mimo-shared-auth's own link counts (canonical parent exactly
# /home/dev/.byre-identity/mimo, basename auth.json, target absent or a
# regular non-symlink file); any other link is removed. A regular file or
# nothing is fine; anything else (a FIFO, a directory) is refused.
data_root="${XDG_DATA_HOME:-/home/dev/.local/share}"
cred="$data_root/mimocode/auth.json"
tfile=/home/dev/.byre-identity/mimo/auth.json
shared_auth=""
if [ -L "$cred" ]; then
  # Sentinel read: $(readlink) strips trailing newlines; a target holding
  # a newline is never trusted (removed below), as in the hook.
  target=$(readlink -n -- "$cred" && printf x); target=${target%x}
  nl='
'
  tdir=""
  case "$target" in
    *"$nl"*) ;;
    *) tdir="$(cd "$data_root/mimocode" 2>/dev/null && cd "$(dirname -- "$target")" 2>/dev/null && pwd -P)" || tdir="" ;;
  esac
  if [ "$tdir" = /home/dev/.byre-identity/mimo ] && [ "$(basename -- "$target")" = auth.json ] \
    && [ ! -L "$tfile" ] && { [ ! -e "$tfile" ] || [ -f "$tfile" ]; }; then
    shared_auth=1
  else
    # A failed removal would leave the rejected link for the login to write
    # through: stop instead.
    if ! rm -f -- "$cred"; then
      echo "mimo-login: could not remove the foreign symlink at $cred; not logging in -- remove it first." >&2
      exit 1
    fi
    echo "mimo-login: removed a foreign symlink at $cred; the login will store a regular file."
  fi
fi
# Not a regular file (a FIFO, socket, directory): not mimo's. Don't let the
# login open it (a FIFO blocks) and never delete it -- say so and stop.
if [ -e "$cred" ] && [ ! -L "$cred" ] && [ ! -f "$cred" ]; then
  echo "mimo-login: $cred is not a regular file; not logging in -- inspect it and remove it if it is not yours." >&2
  exit 1
fi

echo "Open the URL below in a browser on your HOST, sign in, authorize, and paste"
echo "the code back here. (The free MiMo channel has ended: the account needs a"
echo "balance or a Token Plan.)"
if [ -n "$shared_auth" ]; then
  echo "mimo-shared-auth is on: this login is machine-wide (every project that uses it)."
else
  echo "Stored for this project only (it survives rebuilds)."
fi
echo ""

# Not exec'd: whoami follows so the result is visible -- mimoLogin reports a
# failed decrypt as a log line and still exits 0, so its status alone says
# little. whoami reads auth.get("xiaomi") only.
mimo auth login -p xiaomi "$@"
status=$?
mimo auth whoami
exit "$status"
