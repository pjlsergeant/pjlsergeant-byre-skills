#!/bin/sh
# Pure environment hook: an explicit per-box value wins; otherwise export the
# machine-scoped shared key and model. Do not print, prompt, or mutate files
# here. The key stands alone: a project that sets only MIMO_MODEL still gets
# the shared key. The model does NOT: it was detected against the SHARED key
# (a Token Plan key's region), so it is exported only when this hook also
# exported the shared key. A project that brings its own XIAOMI_API_KEY
# (possibly another region) gets detection, or its own MIMO_MODEL --
# inheriting the shared model would hand byre-mimo-model a wrong-region
# override it honours instead of probing (2026-10-02 codex review).
_byre_mimo_dir=${BYRE_IDENTITY_BASE:-/home/dev/.byre-identity}/mimo
_byre_mimo_key_file=$_byre_mimo_dir/api-key
_byre_mimo_shared_key=
# A symlinked identity DIR counts as nothing stored, for both files: the
# per-file -L tests alone would accept regular files reached THROUGH a
# planted dir link (2026-10-02 codex review). zai-shared-auth's env.sh has
# the same gap and is NOT fixed here (out of scope for this change).
if [ -z "${XIAOMI_API_KEY:-}" ] && [ ! -L "$_byre_mimo_dir" ] && [ -f "$_byre_mimo_key_file" ] && [ ! -L "$_byre_mimo_key_file" ] && [ -s "$_byre_mimo_key_file" ]; then
    XIAOMI_API_KEY=$(tr -d '[:space:]' < "$_byre_mimo_key_file" 2>/dev/null)
    if [ -n "$XIAOMI_API_KEY" ]; then
        export XIAOMI_API_KEY
        _byre_mimo_shared_key=1
    else
        unset XIAOMI_API_KEY
    fi
fi
# The model is not a secret, but it gets the key's hygiene anyway: a planted
# symlink must not pick the model (and with it the provider the key is sent
# to) any more than it may pick the key. Gated on _byre_mimo_shared_key: the
# shared model rides the shared key only (see top).
_byre_mimo_model_file=$_byre_mimo_dir/model
if [ -n "$_byre_mimo_shared_key" ] && [ -z "${MIMO_MODEL:-}" ] && [ ! -L "$_byre_mimo_dir" ] && [ -f "$_byre_mimo_model_file" ] && [ ! -L "$_byre_mimo_model_file" ] && [ -s "$_byre_mimo_model_file" ]; then
    MIMO_MODEL=$(tr -d '[:space:]' < "$_byre_mimo_model_file" 2>/dev/null)
    if [ -n "$MIMO_MODEL" ]; then
        export MIMO_MODEL
    else
        unset MIMO_MODEL
    fi
fi
unset _byre_mimo_dir _byre_mimo_key_file _byre_mimo_model_file _byre_mimo_shared_key
