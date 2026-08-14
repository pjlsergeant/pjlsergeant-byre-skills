#!/bin/bash
# One Z.AI API key shared by every byre box that enables zai-shared-auth.
# Never block a non-interactive launch; an explicit per-box ZAI_API_KEY needs
# no shared key and takes precedence in env.sh.
identity_dir=${BYRE_IDENTITY_BASE:-/home/dev/.byre-identity}/zai
key_file=$identity_dir/api-key

# Never follow a shared-volume symlink into this box's workspace or another
# writable path. A valid stored credential is a non-symlink regular file.
if [ -f "$key_file" ] && [ ! -L "$key_file" ] && [ -s "$key_file" ]; then
    exit 0
fi
[ -n "${ZAI_API_KEY:-}" ] && exit 0
[ -t 0 ] || exit 0

echo ""
echo "=== byre: zai-shared-auth — one Z.AI key for all your projects ==="
echo "Paste a Z.AI API key to save it in byre's machine-scoped identity volume."
echo "Press Enter to skip; this box can still receive ZAI_API_KEY directly."
printf "API key: "
IFS= read -rs key || key=
echo ""

# Trim whitespace without echoing the credential. Z.AI does not publish a
# stable prefix that is safe to validate here.
key=$(printf '%s' "$key" | tr -d '[:space:]')
[ -n "$key" ] || {
    echo "byre: skipped — no shared Z.AI key saved."
    exit 0
}

[ ! -L "$identity_dir" ] || {
    echo "byre: refusing shared Z.AI key directory symlink: $identity_dir" >&2
    exit 1
}
mkdir -p "$identity_dir"
[ -d "$identity_dir" ] && [ ! -L "$identity_dir" ] || {
    echo "byre: shared Z.AI key path is not a directory: $identity_dir" >&2
    exit 1
}
umask 077
tmp_key=$(mktemp "$identity_dir/.api-key.XXXXXX") || {
    echo "byre: could not stage shared Z.AI key" >&2
    exit 1
}
trap 'if [ -n "$tmp_key" ]; then rm -f -- "$tmp_key"; fi' EXIT HUP INT TERM
printf '%s\n' "$key" > "$tmp_key"
chmod 0600 "$tmp_key"
# rename(2) replaces a hostile api-key symlink itself; unlike shell
# redirection, it never follows that symlink to its target.
mv -f -- "$tmp_key" "$key_file"
tmp_key=
trap - EXIT HUP INT TERM
echo "byre: saved. This launch will use it; other running boxes pick it up when relaunched."
