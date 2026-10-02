#!/bin/sh
# mimo first-run auth hook (a port of byre's opencode-login hook) -- runs as
# the dev user, before the agent launches, on a fresh box. If no MiMo
# credential is stored, run `mimo auth login -p xiaomi` so the agent works
# out of the box.
#
# That login is a paste-code flow (verified live, mimo 0.1.15): it prints a
# https://platform.xiaomimimo.com/authorize?... URL and waits at "Paste code
# here if prompted >" -- no in-box browser needed (its xdg-open attempt fails
# with a harmless warning). The credential lands in auth.json in the
# .mimocode state volume, so this runs once per project and survives
# rebuilds -- or, with pjlsergeant/mimo-shared-auth, through its symlink
# into the machine-wide identity volume, so once per machine. Best-effort:
# skip with Ctrl-C (or on failure/timeout) and the box still launches -- log
# in later with `mimo-login` (this skill's wrapper of `mimo auth login -p
# xiaomi`) from `byre shell`.
command -v mimo >/dev/null 2>&1 || exit 0
# mimo's data dir is the XDG data home (verified, `mimo debug paths`);
# honoring XDG_DATA_HOME keeps the hook faithful to the CLI's own resolution
# (and is the test seam). MIMOCODE_HOME would relocate it too, but the
# state volume would not follow -- unsupported, like XDG_DATA_HOME in [env].
data_root="${XDG_DATA_HOME:-/home/dev/.local/share}"
cred="$data_root/mimocode/auth.json"
# A symlinked credential must never count -- drop it so a clean re-login
# writes a fresh regular file a planted link can't redirect (mimo writes
# auth.json IN PLACE, chmod 0600, no temp+rename --
# packages/shared/src/filesystem.ts:80 -- so a login would write THROUGH a
# link). ONE exception, as in byre's opencode-login hook:
# pjlsergeant/mimo-shared-auth's own link into ITS identity dir is
# legitimate, and a DANGLING one is its expected first-login state (the
# login writes through it into the shared volume). The trusted dir is
# HARDCODED and compared by EQUALITY, deliberately: an env-derived base
# (BYRE_IDENTITY_BASE, the companion's test seam) would let anything
# that reaches the container env (byre rejects BYRE_* in a project [env],
# config.go, but run_args or a skill runtime env still can) redefine the
# trusted namespace, and a broader .byre-identity/* match would
# trust links into SIBLING agents' identity dirs -- through which a login
# here would overwrite that agent's machine-wide credential. Canonicalize
# the target's PARENT dir (the final auth.json may be absent); a lexical
# prefix check would accept planted ..-traversals and reject legitimate
# relative links. Relative targets resolve from the link's own directory.
# And the resolved target itself must be absent (dangling: first login) or
# a regular non-symlink file: a link planted AT the identity dir's auth.json
# would chain the login's write onward, and the companion hook refuses that
# case without touching this link -- so it is dropped here instead, and the
# login writes a safe local regular file. mimo-login (mimo-login-cmd.sh)
# mirrors this check, since `byre shell` never re-runs this hook.
shared_auth=""
if [ -L "$cred" ]; then
  # Read the target with a sentinel: $(readlink) strips trailing newlines,
  # so "<trusted path><newline>" -- a different file -- would compare
  # equal. A target holding a newline is never trusted (tdir stays empty,
  # so it takes the removal path below).
  target=$(readlink -n -- "$cred" && printf x); target=${target%x}
  nl='
'
  tdir=""
  case "$target" in
    *"$nl"*) ;;
    *) tdir="$(cd "$data_root/mimocode" 2>/dev/null && cd "$(dirname -- "$target")" 2>/dev/null && pwd -P)" || tdir="" ;;
  esac
  tfile="/home/dev/.byre-identity/mimo/auth.json"
  # Full-path equality: the OWN identity dir AND the auth.json basename
  # (mimo-shared-auth links exactly that file) -- a dir-only match would
  # trust a link to any OTHER name inside the dir. -L is tested first:
  # -e/-f follow links.
  if [ "$tdir" = "/home/dev/.byre-identity/mimo" ] && [ "$(basename -- "$target")" = "auth.json" ] \
    && [ ! -L "$tfile" ] && { [ ! -e "$tfile" ] || [ -f "$tfile" ]; }; then
    shared_auth=1
  else
    # A failed removal (an unwritable data dir) must not fall through: the
    # rejected link would still be there, and a login whose target is
    # writable would write THROUGH it. Stop without offering the login.
    if ! rm -f -- "$cred"; then
      echo "byre: could not remove the symlinked mimo credential $cred; not offering the login -- remove it in byre shell" >&2
      exit 0
    fi
    echo "byre: removed a symlinked mimo credential ($cred); log in again (mimo-login) to store a regular file." >&2
  fi
fi
# Anything else that is not a regular file (a FIFO, socket, directory) is
# not a credential mimo wrote. Stop BEFORE jq/tail/mimo open it: opening a
# FIFO blocks, and this runs before the tty guard below, so a planted FIFO
# would hang a headless launch. Never delete an unknown object -- say so.
if [ -e "$cred" ] && [ ! -L "$cred" ] && [ ! -f "$cred" ]; then
  echo "byre: mimo credential path $cred is not a regular file; not reading it and not offering the login -- inspect it in byre shell" >&2
  exit 0
fi
# A static key in the environment makes the file login unnecessary: the
# models.dev catalog's env name for provider `xiaomi` and the Token Plan
# providers alike (verified live). This sees only what the container env
# already holds -- env_from_host / [env] values. A `byre credentials` value
# is exported by the launcher only AFTER every firstrun hook (byre's
# launcher.sh: the firstrun loop, then env.d, then the credential export),
# so a box whose XIAOMI_API_KEY comes from `byre credentials` is still
# offered the login here; Ctrl-C skips it.
[ -n "${XIAOMI_API_KEY:-}" ] && exit 0
# A MIMO_MODEL on another provider (the part before the first "/") is a
# deliberate choice of that provider: the Xiaomi login is not what it needs.
# xiaomi and the Token Plan providers (xiaomi-token-plan-{cn,ams,sgp},
# models.dev) still want it. A malformed value (no provider/model shape) is
# ignored, as byre-mimo-model ignores it, so it changes nothing here either.
case "${MIMO_MODEL:-}" in
  xiaomi/*|xiaomi-token-plan-*/*) ;;
  ?*/?*) exit 0 ;;
esac
# Already authenticated? There is no `login status` probe that a hook can
# trust cheaply, so the guard reads the store: stand down iff auth.json
# parses and holds a `xiaomi` entry of type "api" with a string key -- what
# mimoLogin writes (put("xiaomi", {type: "api", key, ...})) and what mimo's
# Auth schema accepts (Auth.all schema-decodes and drops invalid entries,
# auth/index.ts:75-89, so a malformed entry is no login to mimo either).
# `mimo auth whoami` and the default model read that entry only -- a shared
# store with, say, only an anthropic entry is NOT a xiaomi login. A truncated/corrupt file (an interrupted
# in-place write) fails jq, so the login is offered, and mimo's Auth.set
# reads the store as {} (readJson |> orElseSucceed({}), auth/index.ts) and
# rewrites it whole -- that is the recovery. Not caught: a revoked key or an
# empty balance -- those surface at use time. jq follows the trusted
# shared-auth link, so a machine-wide login counts; a dangling one fails and
# the login below writes through it. jq is in this skill's apt list; should
# it be missing, fall back to the old shape sniff (a "xiaomi" string, any
# "type" member and a trailing "}") -- weaker: provider-aware only in that
# the name appears somewhere, blind to the entry's type and key.
if command -v jq >/dev/null 2>&1; then
  jq -e '.xiaomi? | type == "object" and .type == "api" and (.key | type == "string")' "$cred" >/dev/null 2>&1 && exit 0
elif [ -s "$cred" ] && grep -q '"xiaomi"' "$cred" 2>/dev/null && grep -q '"type"' "$cred" 2>/dev/null \
  && [ "$(tail -c 1 "$cred" 2>/dev/null)" = "}" ]; then
  exit 0
fi

# Interactive only: the paste flow needs a terminal, and a non-interactive
# launch must not sit blocked on stdin until the timeout. Placed after the
# symlink sweep so a planted link is dropped even on a headless launch.
[ -t 0 ] || exit 0

# Clean skip on Ctrl-C: exit 0 so no signal-death propagates toward the
# launcher -- the box proceeds to the agent regardless.
trap 'echo; echo "byre: mimo login skipped. To do it later, open another terminal and run '\''byre shell'\'', then '\''mimo-login'\'' (it wraps '\''mimo auth login -p xiaomi'\'')."; exit 0' INT

echo ""
echo "=== byre: first-run MiMo Code login ==="
echo "Open the URL below in a browser on your host, sign in to the Xiaomi MiMo platform,"
echo "authorize, and paste the code back here."
if [ -n "$shared_auth" ]; then
  echo "Stored machine-wide (mimo-shared-auth: all your byre projects). Ctrl-C to skip."
else
  echo "Stored per-project, survives rebuilds. Ctrl-C to skip (or set XIAOMI_API_KEY instead,"
  echo "or enable pjlsergeant/mimo-shared-auth to share one login across projects)."
fi
echo "Later, or again: 'mimo-login' in 'byre shell' (it wraps 'mimo auth login -p xiaomi')."
echo "Note: the free MiMo channel has ended; the account needs a balance (otherwise requests answer 402)."
echo ""
# Bound the wait; --foreground keeps mimo in the terminal's foreground
# process group so Ctrl-C reaches it immediately.
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout --foreground 600"
$TO mimo auth login -p xiaomi \
  || echo "byre: mimo login didn't complete. To do it later, open another terminal and run 'byre shell', then 'mimo-login' (it wraps 'mimo auth login -p xiaomi')." >&2
exit 0
