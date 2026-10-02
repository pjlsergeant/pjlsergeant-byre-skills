#!/bin/bash
# mimo-shared-auth firstrun hook -- idempotently asserts, EVERY launch, that
# mimo's data-dir auth.json is a symlink into the machine-wide identity
# volume. A port of byre's opencode-shared-auth hook (mimo is an opencode
# fork with the same auth store). A dangling link is fine: it is the
# expected first-login state, and the first `mimo-login` (or `mimo auth
# login -p xiaomi`) anywhere writes THROUGH it into the shared volume --
# mimo writes auth.json in place (Auth.set/remove -> writeJson =
# writeFileString + chmod 0600, no temp+rename: MiMo-Code
# packages/cli/src/auth/index.ts:97,106, packages/shared/src/filesystem.ts:80).
# Runs before pjlsergeant/mimo's login hook (00- prefix sorts first), so that
# hook sees either a valid shared credential or the expected dangling link,
# which it trusts (its hardcoded-dir exemption).
#
# Never prompts, never blocks: there is nothing to ask. 1.0 prompted for an
# "API key", but mimo's Xiaomi login never hands the user a raw key -- the
# pasted code is ciphertext only the process that printed the authorize URL
# can decrypt -- so a prompt here could only store garbage.
#
# No `set -e`, as in the opencode hook: every step that can fail is
# best-effort or checked by hand, and the launch proceeds regardless. The
# base overrides are test seams (the launcher's gate-file precedent);
# XDG_DATA_HOME is mimo's own data-dir relocation, so honoring it here stays
# faithful to the CLI's resolution (`mimo debug paths`).
IDENTITY_DIR="${BYRE_IDENTITY_BASE:-/home/dev/.byre-identity}/mimo"
SHARED="$IDENTITY_DIR/auth.json"
DATA_DIR="${XDG_DATA_HOME:-/home/dev/.local/share}/mimocode"
cred="$DATA_DIR/auth.json"

# A symlinked identity DIR is not ours: linking auth.json through it would
# send every login on this machine wherever the planted link points. Refuse
# (kept from 1.0's hygiene), and leave any per-project login untouched.
if [ -L "$IDENTITY_DIR" ]; then
  echo "byre mimo-shared-auth: refusing a symlinked identity dir ($IDENTITY_DIR) -- shared auth not asserted this launch." >&2
  exit 0
fi

# Failing to create either dir means shared auth cannot be asserted this
# launch; say so before degrading (best-effort, never block the launch) --
# otherwise the fallback to a per-project login is silent and the user
# believes the machine-wide credential is in play.
if ! mkdir -p "$IDENTITY_DIR" "$DATA_DIR" 2>/dev/null; then
  echo "byre mimo-shared-auth: cannot create $IDENTITY_DIR or $DATA_DIR -- shared auth not asserted this launch (falling back to a per-project login)." >&2
  exit 0
fi

# The -L test above sees only the LEAF: a symlinked ANCESTOR would carry the
# shared credential off the same way. Compare the dir's physical path with
# its spelling (no lexical prefix check) and refuse on any difference. byre
# rejects BYRE_* names in a project [env] (and env_from_host:
# internal/config/config.go, the reserved BYRE_ vocabulary), so
# BYRE_IDENTITY_BASE is a test seam, not a user footgun; a seam value must
# itself be a physical path.
if [ "$(cd "$IDENTITY_DIR" 2>/dev/null && pwd -P)" != "$IDENTITY_DIR" ]; then
  echo "byre mimo-shared-auth: refusing: the identity dir ($IDENTITY_DIR) resolves through a symlink -- shared auth not asserted this launch." >&2
  exit 0
fi

# Version skew: a pjlsergeant/mimo < 1.2.0 login hook removes EVERY
# symlinked auth.json, this link included -- with it, this hook would thrash
# (link asserted, removed by that hook, a local login made, then discarded
# here next launch). byre packages have no dependency field, so gate here:
# the 1.2.0+ hook names its trusted target,
# /home/dev/.byre-identity/mimo/auth.json, and the 1.1.0 hook has no such
# string. Absent or older: say so and touch nothing. BYRE_MIMO_LOGIN_HOOK is
# a test seam (BYRE_* is reserved, as above).
hook="${BYRE_MIMO_LOGIN_HOOK:-/etc/byre/firstrun.d/mimo-login}"
if ! [ -f "$hook" ] || ! grep -qF 'byre-identity/mimo/auth.json' "$hook" 2>/dev/null; then
  echo "byre mimo-shared-auth: pjlsergeant/mimo 1.2.0+ is required (its login hook must trust the shared link); shared auth not asserted this launch -- upgrade the mimo skill and rebuild." >&2
  exit 0
fi

# 1.0 leftovers (a pasted "key" and a model, exported by a now-deleted env.d
# hook). Nothing reads them any more; say so once per launch and leave them
# -- deleting a user's files is not this hook's call.
if [ -e "$IDENTITY_DIR/api-key" ] || [ -e "$IDENTITY_DIR/model" ]; then
  echo "byre mimo-shared-auth: ~/.byre-identity/mimo/api-key and model are from mimo-shared-auth 1.0 (a pasted key) and unused now; run 'rm ~/.byre-identity/mimo/api-key ~/.byre-identity/mimo/model' in 'byre shell' to silence this." >&2
fi

# The shared credential itself must be a regular file (or absent): a symlink
# planted AT $SHARED would chain the data-dir link to a file of the planter's
# choosing, and mimo's in-place write (filesystem.ts:80) follows the chain.
# Refuse BEFORE the promote/assert steps, leaving the data-dir auth.json
# untouched (whatever it is, it is no worse than before this launch). Test -L
# first: -e/-f follow links. byre's opencode-shared-auth hook
# (~/byre/internal/builtins/skills/opencode-shared-auth/firstrun.sh) has the
# same gap; not fixed here.
if [ -L "$SHARED" ] || { [ -e "$SHARED" ] && [ ! -f "$SHARED" ]; }; then
  echo "byre mimo-shared-auth: refusing: the shared credential path ($SHARED) is a symlink/not a regular file; shared auth not asserted this launch; remove it in byre shell." >&2
  exit 0
fi

# Adopt an existing per-project login rather than clobbering it: if this box
# already has a real auth.json and the shared copy doesn't exist yet, COPY
# the file into the identity volume (it becomes the machine-wide credential).
# Two boxes launching with $SHARED absent can both pass the -e test, so the
# claim is an exclusive create, not a mv (mv across volumes is copy+unlink,
# and the second would silently replace the first box's login): copy into a
# temp file in the identity dir, then hard-link it to $SHARED -- same
# filesystem, and ln fails with EEXIST if another box won. -T: never link
# INTO a directory that appeared there. A failed claim (read-only or full
# volume) must NOT fall through to the assert below: that would discard the
# only login and link to nothing. Keep the local file, say so, stop.
#
# Win or lose, the local file is NOT removed here: the assert below renames
# the link over it in one step, so a failed assert leaves this box its local
# login (and its "keeps its local credential" message true) instead of no
# credential at all. Messages print only once the outcome is known -- a
# "promoting" line before the ln would be false for the box that loses.
promoted=""
lost=""
if [ -f "$cred" ] && [ ! -L "$cred" ] && [ ! -e "$SHARED" ]; then
  tmp=$(mktemp "$IDENTITY_DIR/.auth.json.XXXXXX" 2>/dev/null) || tmp=""
  if [ -z "$tmp" ] || ! cp -- "$cred" "$tmp" 2>/dev/null || ! chmod 600 "$tmp" 2>/dev/null; then
    [ -n "$tmp" ] && rm -f -- "$tmp"
    echo "byre mimo-shared-auth: could not promote this box's login into the identity volume; keeping the per-project login, shared auth not asserted this launch." >&2
    exit 0
  fi
  if ln -T -- "$tmp" "$SHARED" 2>/dev/null; then
    rm -f -- "$tmp"
    promoted=1
    # Say it out loud: this box's login is now THE machine credential.
    echo "byre mimo-shared-auth: promoted this box's existing MiMo Code login to the machine-wide shared credential" >&2
  elif [ -e "$SHARED" ] || [ -L "$SHARED" ]; then
    # Lost the race: shared wins, as the heal policy below says. Re-check
    # the winner's object (the refusal above ran before it existed). The
    # "replaced" message waits until the assert has actually replaced it.
    rm -f -- "$tmp"
    if [ -L "$SHARED" ] || [ ! -f "$SHARED" ]; then
      echo "byre mimo-shared-auth: refusing: the shared credential path ($SHARED) is a symlink/not a regular file; shared auth not asserted this launch; remove it in byre shell." >&2
      exit 0
    fi
    lost=1
  else
    rm -f -- "$tmp"
    echo "byre mimo-shared-auth: could not promote this box's login into the identity volume; keeping the per-project login, shared auth not asserted this launch." >&2
    exit 0
  fi
fi

# Assert the symlink. This also heals a fork: a box that lost the link (a
# pjlsergeant/mimo < 1.2 login hook removed EVERY symlinked auth.json) logs
# in to a local file, silently forking off the shared credential. When both a local file
# AND a shared credential exist, the shared one wins (the local copy is a
# fork; discarding it is the healing).
#
# Read the link target with a sentinel: $(readlink) strips trailing
# newlines, so a target of "$SHARED<newline>" -- a different file -- would
# compare equal. Any target holding a newline is not ours: re-assert.
nl='
'
linked=""
if [ -L "$cred" ]; then
  target=$(readlink -n -- "$cred" && printf x); target=${target%x}
  case "$target" in
    *"$nl"*) ;;
    *) [ "$target" = "$SHARED" ] && linked=1 ;;
  esac
fi
if [ -z "$linked" ]; then
  # Not a regular file (a FIFO, socket, directory): not a login this hook
  # made or may discard -- rm -f cannot remove a directory anyway, and the
  # ln below would then fail silently. Say so and leave it.
  if [ -e "$cred" ] && [ ! -L "$cred" ] && [ ! -f "$cred" ]; then
    echo "byre mimo-shared-auth: refusing: $cred is not a regular file -- shared auth not asserted this launch; inspect it in byre shell." >&2
    exit 0
  fi
  # A just-promoted local file is the shared credential's own copy:
  # replacing it discards nothing, so no "discarded" message for it.
  discard=""
  [ -z "$promoted" ] && [ -f "$cred" ] && [ ! -L "$cred" ] && [ -e "$SHARED" ] && discard=1
  # Build the link under a temp name, then rename it over $cred: an atomic
  # replace of a regular file or an old link (-T: never INTO a directory,
  # refused above anyway). Each step is checked; on any failure $cred is
  # left exactly as it was -- an unchecked rm+ln would leave no credential
  # at all and a lying "discarded" message. Just before the rename, re-check
  # $SHARED: it was vetted before the promote, and could have been swapped
  # for a symlink since.
  t=$(mktemp "$DATA_DIR/.auth.json.XXXXXX" 2>/dev/null) || t=""
  ok=""
  if [ -n "$t" ] && rm -f -- "$t" && ln -s -- "$SHARED" "$t" 2>/dev/null; then
    if [ -L "$SHARED" ] || { [ -e "$SHARED" ] && [ ! -f "$SHARED" ]; }; then
      rm -f -- "$t"
      echo "byre mimo-shared-auth: refusing: the shared credential path ($SHARED) is a symlink/not a regular file; shared auth not asserted this launch; remove it in byre shell." >&2
      exit 0
    fi
    mv -fT -- "$t" "$cred" 2>/dev/null && ok=1
  fi
  if [ -z "$ok" ]; then
    [ -n "$t" ] && rm -f -- "$t"
    echo "byre mimo-shared-auth: could not assert the shared-auth link; this box keeps its local credential -- shared auth not asserted this launch." >&2
    exit 0
  fi
  # Say it out loud when a local login was replaced (lost race, or a fork
  # discarded for the shared login); a won promotion already said its piece.
  if [ -n "$lost" ]; then
    echo "byre mimo-shared-auth: another box promoted its login first; this box's local login was replaced by the shared one" >&2
  elif [ -n "$discard" ]; then
    echo "byre mimo-shared-auth: replaced this box's local MiMo Code login with the machine-wide shared credential (the shared one wins; the local copy is discarded)" >&2
  fi
fi
[ -f "$SHARED" ] && [ ! -L "$SHARED" ] && chmod 600 "$SHARED" 2>/dev/null || true

# The file is shared whole; API-key-shaped entries are the only ones that
# share safely. The Xiaomi paste-code login stores a `"type": "api"` entry
# (auth/index.ts Api class; providers.ts mimoLogin -> put("xiaomi", {type:
# "api", ...})), as does every plain key prompt -- static. An OAuth entry
# (e.g. ChatGPT through mimo's generic login) is shared too, and rotates a
# single-use refresh token that concurrent boxes race on and
# cascade-logout. If the shared store holds one, say so -- friendly, and
# NEVER touch it: it's a live working credential. auth.json is written with
# JSON.stringify(..., 2) (filesystem.ts:81), so entries read `"type":
# "oauth"`; tolerate spacing.
if [ -f "$SHARED" ] && grep -Eq '"type"[[:space:]]*:[[:space:]]*"oauth"' "$SHARED" 2>/dev/null; then
  echo "byre mimo-shared-auth: the shared auth.json is shared whole; API-key-style entries (the Xiaomi login is one) are the only ones that share safely -- an OAuth entry in it is shared too and will race across boxes; log that provider in with an API key instead." >&2
fi
exit 0
