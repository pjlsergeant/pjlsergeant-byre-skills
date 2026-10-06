#!/bin/bash
# One Mistral API key shared by every byre box that enables vibe-shared-auth.
# Never block a non-interactive launch; an explicit per-box MISTRAL_API_KEY
# needs no shared key and takes precedence in env.sh.
# Runs as 00-: before pjlsergeant/vibe's own login hook (firstrun.d/
# vibe-login), which then sees the saved file and stands down.
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
# Before the prompt: a key typed into a hook that then refuses is wasted.
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
[ -t 0 ] || exit 0

echo ""
echo "=== byre: vibe-shared-auth — one Mistral API key for all your projects ==="
echo "Paste a Mistral API key (console.mistral.ai) to save it in byre's machine-scoped identity volume."
echo "Press Enter to skip; this box can still receive MISTRAL_API_KEY directly, or log in with vibe-login."
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
# pre-prompt check may have seen only an ancestor, and the prompt is a
# window in which a link can be planted.
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
[ ! -d "$key_file" ] || {
    echo "byre: refusing: shared Mistral key path is a directory (or a link to one): $key_file -- key not saved. Inspect it in byre shell." >&2
    exit 1
}
mv -f -- "$tmp_key" "$key_file"
tmp_key=
[ -f "$key_file" ] && [ ! -L "$key_file" ] || {
    echo "byre: shared Mistral key was NOT saved: $key_file is not a regular file after the move. Inspect it in byre shell." >&2
    exit 1
}
trap - EXIT HUP INT TERM
echo "byre: saved. This launch will use it; other running boxes pick it up when relaunched."
