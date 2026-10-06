#!/bin/sh
# Pure environment hook: an explicit per-box key wins; otherwise export the
# machine-scoped shared key. Do not print, prompt, or mutate files here.
# The key must be a regular, non-symlink, non-empty file in a dir whose
# physical path is its spelling: the -L test sees only the leaf, and a
# symlinked ANCESTOR (~/.byre-identity or its zai/ dir pointing elsewhere)
# would export a key from outside the identity volume (firstrun.sh's check;
# a BYRE_IDENTITY_BASE seam value must itself be a physical path). On any
# doubt, export nothing -- silently, since this hook never prints.
_byre_zai_key_dir=${BYRE_IDENTITY_BASE:-/home/dev/.byre-identity}/zai
_byre_zai_key_file=$_byre_zai_key_dir/api-key
if [ -z "${ZAI_API_KEY:-}" ] && [ -f "$_byre_zai_key_file" ] && [ ! -L "$_byre_zai_key_file" ] && [ -s "$_byre_zai_key_file" ] \
    && [ "$(cd "$_byre_zai_key_dir" 2>/dev/null && pwd -P)" = "$_byre_zai_key_dir" ]; then
    ZAI_API_KEY=$(tr -d '[:space:]' < "$_byre_zai_key_file" 2>/dev/null)
    if [ -n "$ZAI_API_KEY" ]; then
        export ZAI_API_KEY
    else
        unset ZAI_API_KEY
    fi
fi
unset _byre_zai_key_dir _byre_zai_key_file
