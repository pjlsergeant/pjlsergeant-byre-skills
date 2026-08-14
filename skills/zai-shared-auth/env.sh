#!/bin/sh
# Pure environment hook: an explicit per-box key wins; otherwise export the
# machine-scoped shared key. Do not print, prompt, or mutate files here.
_byre_zai_key_file=${BYRE_IDENTITY_BASE:-/home/dev/.byre-identity}/zai/api-key
if [ -z "${ZAI_API_KEY:-}" ] && [ -f "$_byre_zai_key_file" ] && [ ! -L "$_byre_zai_key_file" ] && [ -s "$_byre_zai_key_file" ]; then
    ZAI_API_KEY=$(tr -d '[:space:]' < "$_byre_zai_key_file" 2>/dev/null)
    if [ -n "$ZAI_API_KEY" ]; then
        export ZAI_API_KEY
    else
        unset ZAI_API_KEY
    fi
fi
unset _byre_zai_key_file
