#!/bin/bash
# One Mistral API key shared by every byre box that enables vibe-shared-auth.
# Never block a non-interactive launch; an explicit per-box MISTRAL_API_KEY
# needs no shared key and takes precedence in env.sh.
# Runs as 00-: before pjlsergeant/vibe's own login hook (firstrun.d/
# vibe-login), which then sees the saved file and stands down.
#
# Order: a per-box MISTRAL_API_KEY wins; refuse a symlinked identity path;
# a valid shared key is left alone; else PROMOTE this project's existing
# Vibe login (the key vibe-login's browser sign-in wrote to ~/.vibe/.env,
# which the user never sees) into the shared store -- the
# pjlsergeant/mimo-shared-auth precedent, but by VALUE: the key is copied
# into ~/.byre-identity/vibe/api-key and env.sh exports it. .env itself is
# never linked into the identity volume: python-dotenv's set_key rewrites
# it via temp+rename, which would replace a link. Promotion runs before the
# TTY guard, so a headless launch promotes too. Only with nothing to
# promote is an interactive launch offered the paste prompt.
identity_dir=${BYRE_IDENTITY_BASE:-/home/dev/.byre-identity}/vibe
key_file=$identity_dir/api-key

[ -n "${MISTRAL_API_KEY:-}" ] && exit 0

# Never follow a shared-volume symlink into this box's workspace or another
# writable path. The -L tests below see only the LEAF: a symlinked ANCESTOR
# (~/.byre-identity itself, or its vibe/ dir, pointing into the repo) would
# carry the machine-wide key off the same way, so compare the physical path
# of the nearest existing ancestor-or-self of the identity dir with its
# spelling (no lexical prefix check; pjlsergeant/mimo-shared-auth's
# firstrun.sh check) and refuse on any difference -- a dangling link or a
# non-directory there fails the cd and is refused too. byre rejects BYRE_*
# names in a project [env] (and env_from_host), so BYRE_IDENTITY_BASE is a
# test seam, not a user footgun; a seam value must itself be a physical path.
# Before the .env read and the prompt: a key typed into a hook that then
# refuses is wasted, and a refused path must not be written by promotion.
# Exit 0 here, never blocking the launch (the box can still log in with
# vibe-login or receive MISTRAL_API_KEY directly).
probe=$identity_dir
while [ ! -e "$probe" ] && [ ! -L "$probe" ]; do
    probe=${probe%/*}
    [ -n "$probe" ] || probe=/
done
if [ "$(cd "$probe" 2>/dev/null && pwd -P)" != "$probe" ]; then
    echo "byre vibe-shared-auth: refusing: $probe resolves through a symlink (or is not a directory) -- the shared Mistral key is not read or saved this launch. Inspect it in byre shell." >&2
    exit 0
fi

# A valid stored credential is a non-symlink regular file in that physical
# dir.
if [ -f "$key_file" ] && [ ! -L "$key_file" ] && [ -s "$key_file" ]; then
    exit 0
fi

# Save $2 as the shared key, 0600, or print why not and exit 1. $1 is the
# mode: "replace" (the paste path: a typed key is a deliberate replacement,
# so rename(2) it over whatever is at api-key) or "claim" (promotion: only
# ever CREATE api-key, never replace one -- see below). The identity dir is
# (re)checked here, right before the key is staged in it.
save_key() {
    mode=$1 key=$2
    [ ! -L "$identity_dir" ] || {
        echo "byre: refusing shared Mistral key directory symlink: $identity_dir" >&2
        exit 1
    }
    mkdir -p "$identity_dir"
    [ -d "$identity_dir" ] && [ ! -L "$identity_dir" ] || {
        echo "byre: shared Mistral key path is not a directory: $identity_dir" >&2
        exit 1
    }
    # Again, now that the dir exists, right before the key is staged in it: the
    # early check may have seen only an ancestor, and the .env read or the
    # prompt is a window in which a link can be planted.
    [ "$(cd "$identity_dir" 2>/dev/null && pwd -P)" = "$identity_dir" ] || {
        echo "byre: refusing: shared Mistral key directory resolves through a symlink: $identity_dir" >&2
        exit 1
    }
    umask 077
    tmp_key=$(mktemp "$identity_dir/.api-key.XXXXXX") || {
        echo "byre: could not stage shared Mistral key" >&2
        exit 1
    }
    trap 'if [ -n "$tmp_key" ]; then rm -f -- "$tmp_key"; fi' EXIT HUP INT TERM
    printf '%s\n' "$key" > "$tmp_key"
    chmod 0600 "$tmp_key"
    if [ "$mode" = claim ]; then
        claim_key
        return
    fi
    # rename(2) replaces a hostile api-key symlink itself; unlike shell
    # redirection, it never follows that symlink to its target. A planted
    # DIRECTORY would swallow the mv instead -- POSIX mv moves the file INTO
    # it, and reports SUCCESS -- so probe with -d first (BSD mv has no -T;
    # -d follows symlinks, covering the symlink-to-directory arm), and re-check
    # AFTER the mv that api-key is a regular non-symlink file. A directory
    # landing between probe and mv still wins that race: one copy of the key is
    # left inside the planted directory (as .api-key.XXXXXX; through a link,
    # that may be outside the identity volume), protected only by its own 0600
    # mode, and this hook reports it NOT saved rather than "saved".
    # A failed mv exits before tmp_key is cleared, so the EXIT trap removes
    # the staged file.
    [ ! -d "$key_file" ] || {
        echo "byre: refusing: shared Mistral key path is a directory (or a link to one): $key_file -- key not saved. Inspect it in byre shell." >&2
        exit 1
    }
    mv -f -- "$tmp_key" "$key_file" || {
        echo "byre: shared Mistral key was NOT saved: could not move it into place" >&2
        exit 1
    }
    tmp_key=
    [ -f "$key_file" ] && [ ! -L "$key_file" ] || {
        echo "byre: shared Mistral key was NOT saved: $key_file is not a regular file after the move. Inspect it in byre shell." >&2
        exit 1
    }
    trap - EXIT HUP INT TERM
}

# Promotion's exclusive claim of api-key for the key staged in $tmp_key (the
# pjlsergeant/mimo-shared-auth pattern). Two boxes launching at once can both
# see no shared key above; with a replacing mv the second would silently
# overwrite the key the first had already exported. So claim the name with a
# HARD LINK, not mv: link(2) never replaces -- it fails with EEXIST if
# ANYTHING is at api-key (a regular file another box just claimed, a
# directory, a planted symlink, even a dangling one), and it never follows a
# link at the new name, so nothing is replaced or written through. -T
# (GNU, as in mimo): without it, ln given an existing directory -- or a
# symlink to one -- at api-key would create the link INSIDE it instead of
# failing. Same directory, so same filesystem. The staged name is
# removed either way; the link is verified (-ef: api-key is our very inode)
# BEFORE that rm. A lost claim leaves the winner's key in place: if it is a
# valid shared key, that box's login wins and this project's local login is
# shadowed by it (as in mimo); anything else is reported, not touched.
claim_key() {
    if ln -T -- "$tmp_key" "$key_file" 2>/dev/null; then
        if [ "$tmp_key" -ef "$key_file" ] && [ ! -L "$key_file" ]; then
            rm -f -- "$tmp_key"
            tmp_key=
            trap - EXIT HUP INT TERM
            echo "byre: promoted this project's Mistral login (~/.vibe/.env) to the shared store; every opted-in box now uses it." >&2
            exit 0
        fi
        echo "byre: shared Mistral key was NOT saved: $key_file is not the staged key after the link. Inspect it in byre shell." >&2
        exit 1
    fi
    rm -f -- "$tmp_key"
    tmp_key=
    trap - EXIT HUP INT TERM
    if [ -f "$key_file" ] && [ ! -L "$key_file" ] && [ -s "$key_file" ]; then
        echo "byre vibe-shared-auth: another box shared its Mistral login first; using that one" >&2
        exit 0
    fi
    echo "byre: shared Mistral key was NOT saved: something other than a shared key is at $key_file (or it could not be created). Inspect it in byre shell." >&2
    exit 1
}

# Promote this project's existing Vibe login. VIBE_HOME is honoured for
# this read only, to stay faithful to vibe's resolution (and as the test
# seam); byre's .vibe volume only covers the default /home/dev/.vibe.
# The vibe login hook's rule: only a regular, non-symlink file is read; a
# symlink or any other non-file (a FIFO would block this headless-capable
# read) is refused with a message and NOT read -- the prompt is still
# offered below.
envfile="${VIBE_HOME:-/home/dev/.vibe}/.env"
found=
if [ -L "$envfile" ] || { [ -e "$envfile" ] && [ ! -f "$envfile" ]; }; then
    echo "byre vibe-shared-auth: $envfile is a symlink or not a regular file; not reading it, nothing promoted -- inspect it in byre shell." >&2
elif [ -f "$envfile" ]; then
    # The effective value is the LAST MISTRAL_API_KEY assignment, as
    # python-dotenv reads it; an empty last assignment means no login.
    # python-dotenv's set_key writes MISTRAL_API_KEY='...'; a hand-written
    # file may be bare, double-quoted or `export`-prefixed. `#` comment lines
    # never match the pattern; an empty or whitespace-only value counts as
    # empty, and so does a bare value whose first non-space character is `#`
    # (`MISTRAL_API_KEY= # no key`: the pattern eats the spaces, so the value
    # starts at the comment). Nothing is echoed: the value is the credential.
    re='^[[:space:]]*(export[[:space:]]+)?MISTRAL_API_KEY[[:space:]]*=[[:space:]]*(.*)$'
    while IFS= read -r line || [ -n "$line" ]; do
        [[ $line =~ $re ]] || continue
        v=${BASH_REMATCH[2]}
        case $v in
            \'*) v=${v#\'}; v=${v%%\'*} ;;
            \"*) v=${v#\"}; v=${v%%\"*} ;;
            \#*) v= ;;                    # only a comment, no value
            *) v=${v%%[[:space:]]#*} ;;   # a bare value's inline comment
        esac
        v=${v#"${v%%[![:space:]]*}"}
        v=${v%"${v##*[![:space:]]}"}
        found=$v
    done 2>/dev/null < "$envfile"
    unset line v re
fi
if [ -n "$found" ]; then
    save_key claim "$found"    # exits: claim_key reports the outcome
fi

[ -t 0 ] || exit 0

echo ""
echo "=== byre: vibe-shared-auth — one Mistral API key for all your projects ==="
echo "Paste a Mistral API key (console.mistral.ai) to save it in byre's machine-scoped identity volume."
echo "Or press Enter, sign in with vibe-login, and the next launch shares that login."
echo "(Enter skips; this box can still receive MISTRAL_API_KEY directly.)"
printf "API key: "
IFS= read -rs key || key=
echo ""

# Trim whitespace without echoing the credential. Mistral does not publish a
# stable key prefix that is safe to validate here.
key=$(printf '%s' "$key" | tr -d '[:space:]')
[ -n "$key" ] || {
    echo "byre: skipped — no shared Mistral key saved."
    exit 0
}

save_key replace "$key"
echo "byre: saved. This launch will use it; other running boxes pick it up when relaunched."
