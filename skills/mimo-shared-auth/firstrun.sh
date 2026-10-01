#!/bin/bash
# One Xiaomi MiMo API key, plus an optional default model, shared by every
# byre box that enables mimo-shared-auth. Never block a non-interactive
# launch; an explicit per-box XIAOMI_API_KEY needs no shared key and takes
# precedence in env.sh (as does a per-box MIMO_MODEL over the shared model).
# Runs before pjlsergeant/mimo's mimo-login hook (00- prefix), which stands
# down once api-key exists -- so a key pasted here suppresses the paste-code
# login in this same launch. A Token Plan (tp-) key's model is detected
# (detect_model, below) and offered as the Enter default, so the usual
# answer to the model prompt is just Enter.
#
# No `set -e`, deliberately (zai-shared-auth's shape): every step that can
# fail is checked by hand, so the failure path is explicit and an expected
# non-zero test (a missing file, an Enter at a prompt) never kills the hook.
identity_dir=${BYRE_IDENTITY_BASE:-/home/dev/.byre-identity}/mimo
key_file=$identity_dir/api-key
model_file=$identity_dir/model

[ -n "${XIAOMI_API_KEY:-}" ] && exit 0
[ -t 0 ] || exit 0

# --- shared helpers: detection, the model prompt, the tp- advice, the save ---

# Token Plan region detection. A tp- key works only on ONE regional provider
# xiaomi-token-plan-{cn,ams,sgp} (verified live 2026-10-01); byre-mimo-model
# (pjlsergeant/mimo's resolver, /usr/local/bin) finds which by probing the
# three hosts' /v1/models with the key (200 on its region, 401 elsewhere --
# verified live 2026-10-01, sgp) and prints xiaomi-token-plan-<region>/<model>.
# Run here, at paste time, so the answer is STORED in the model file and
# env.sh exports it as MIMO_MODEL: companion boxes then never need the
# per-launch probe. --no-cache: the resolver's cache lives in THIS project's
# mimo data dir, while what we store here serves every project on the
# machine -- so ask the network, not one project's memory. MIMO_MODEL is
# blanked for the call, or a project override would be echoed back as
# "detected". Ordering: this 00- hook runs before mimo-login and env.d runs
# after all firstrun hooks, so nothing has exported the key yet -- it is
# passed in the resolver's environment only (never argv). The resolver comes
# from the mimo skill; the companion enabled alone just skips detection.
# Its own stderr line (why detection failed) is left visible on purpose.
# Sets $detected ("" when none). $1 is the key.
detect_model() {
    detected=
    case "$1" in tp-*) ;; *) return 0 ;; esac
    command -v byre-mimo-model >/dev/null 2>&1 || return 0
    echo "Detecting the Token Plan region (token-plan-{cn,ams,sgp}.xiaomimimo.com)..."
    detected=$(XIAOMI_API_KEY="$1" MIMO_MODEL= byre-mimo-model --no-cache) || detected=
}

# The model is not secret, so this prompt echoes. $1 is the Enter default
# ("" for none); a non-empty $2 means the key is known to be tp-, so the
# platform-key Enter hint would mislead and is dropped; $3 = detected means
# $1 came from detect_model and Enter ACCEPTS it (returned in $model), while
# otherwise $1 is the stored model and Enter keeps that file untouched
# ($model stays empty). Sets $model.
prompt_model() {
    echo ""
    echo "Default model for mimo (exported as MIMO_MODEL), as provider/model."
    if [ "${3:-}" = detected ]; then
        echo "Detected: $1 — Enter to accept"
    else
        echo "A Token Plan key (tp-...) needs its region's provider:"
        echo "  xiaomi-token-plan-{cn,ams,sgp}/<model>, e.g. xiaomi-token-plan-sgp/mimo-v2.6-pro"
        if [ -n "$1" ]; then
            echo "Press Enter to keep the stored one: $1"
        elif [ -z "${2:-}" ]; then
            echo "A plain platform key can press Enter for mimo's own default."
        fi
    fi
    printf "Model: "
    IFS= read -r model || model=
    model=$(printf '%s' "$model" | tr -d '[:space:]')
    if [ -z "$model" ] && [ "${3:-}" = detected ]; then
        model=$1
    fi
}

# Advice only, still saved as given: a tp- key 401s "Invalid API Key" on any
# provider but its regional xiaomi-token-plan-* one (verified live
# 2026-10-01), so without that model the key looks broken. $1 is the key's
# prefix (callers pass at most the first 3 chars), $2 the effective model.
warn_tp_model() {
    case "$1" in
        tp-*)
            case "$2" in
                xiaomi-token-plan-*) ;;
                *) echo "byre: warning — a Token Plan (tp-) key will 401 until MIMO_MODEL is a xiaomi-token-plan-<region>/<model>." >&2 ;;
            esac ;;
    esac
}

# Create the identity dir if needed, refusing a symlinked one before and
# after mkdir (the bar every read path below also enforces).
prepare_dir() {
    [ ! -L "$identity_dir" ] || {
        echo "byre: refusing shared MiMo key directory symlink: $identity_dir" >&2
        exit 1
    }
    mkdir -p "$identity_dir"
    [ -d "$identity_dir" ] && [ ! -L "$identity_dir" ] || {
        echo "byre: shared MiMo key path is not a directory: $identity_dir" >&2
        exit 1
    }
    umask 077
    tmp_file=
    trap 'if [ -n "$tmp_file" ]; then rm -f -- "$tmp_file"; fi' EXIT HUP INT TERM
}

# Stage, chmod, then rename(2): rename replaces a hostile symlink at the
# destination itself; unlike shell redirection, it never follows that
# symlink to its target. -T (GNU mv; the box is Debian) stops a DIRECTORY
# planted at the destination from swallowing the file as dir/.name.XXXXXX
# -- it fails instead. The model gets the key's treatment (0600 too): it
# chooses which provider the key is sent to. Each step is checked: a write
# that fails (full or read-only volume) must stop the hook before the next
# save, never report "saved"; the EXIT trap removes the staged temp file.
save() {
    tmp_file=$(mktemp "$identity_dir/.$1.XXXXXX") || save_failed "$1"
    printf '%s\n' "$2" > "$tmp_file" || save_failed "$1"
    chmod 0600 "$tmp_file" || save_failed "$1"
    mv -fT -- "$tmp_file" "$identity_dir/$1" || save_failed "$1"
    tmp_file=
}
save_failed() {
    echo "byre: could not save the shared MiMo $1 in $identity_dir; nothing further was saved." >&2
    exit 1
}

# Never follow a shared-volume symlink into this box's workspace or another
# writable path. A valid stored credential is a non-symlink regular file
# reached through a non-symlink identity dir: a symlinked DIR counts as
# "nothing stored", as in env.sh and mimo-login (2026-10-02 codex review).
if [ ! -L "$identity_dir" ] && [ -f "$key_file" ] && [ ! -L "$key_file" ] && [ -s "$key_file" ]; then
    # Model-only update, scoped to a Token Plan key: a tp- key with NO model
    # file (rm'd to re-enter it, or never saved) 401s on every default model
    # (verified live 2026-10-01), so it is broken until one is stored -- and
    # otherwise unrecoverable short of deleting the key. A platform key with
    # no model is a valid steady state (its owner pressed Enter for mimo's
    # default), so it gets no prompt: an unscoped prompt nagged that owner on
    # every launch (a mimo review, 2026-10-02). Scoped by the key itself, not
    # a "declined" marker file: nothing new to store, and the one key that
    # needs a model keeps being asked until it has one. Only when the model
    # file is truly absent (a symlink or other odd entry stays env.sh's
    # problem: it ignores it) and no project MIMO_MODEL overrides it anyway.
    if [ ! -e "$model_file" ] && [ ! -L "$model_file" ] && [ -z "${MIMO_MODEL:-}" ]; then
        # The whole key is read (never echoed) for detect_model; only its
        # first 3 chars scope this prompt.
        stored_key=$(tr -d '[:space:]' < "$key_file" 2>/dev/null)
        key_prefix=$(printf '%s' "$stored_key" | cut -c1-3)
        [ "$key_prefix" = tp- ] || exit 0
        echo ""
        echo "=== byre: mimo-shared-auth — no shared MiMo model stored ==="
        echo "The stored Token Plan (tp-) key needs a xiaomi-token-plan-<region>/<model> model."
        detect_model "$stored_key"
        stored_key=
        if [ -n "$detected" ]; then
            prompt_model "$detected" tp detected
        else
            echo "Enter one, or press Enter to skip: you'll be asked again next launch until a"
            echo "model is stored, or set MIMO_MODEL in a project."
            prompt_model "" tp
        fi
        if [ -z "$model" ]; then
            echo "byre: no model stored; a tp- key needs one (xiaomi-token-plan-<region>/<model>)." >&2
            exit 0
        fi
        warn_tp_model "$key_prefix" "$model"
        prepare_dir
        save model "$model"
        trap - EXIT HUP INT TERM
        echo "byre: model saved. This launch will use it; other running boxes pick it up when relaunched."
    fi
    exit 0
fi

echo ""
echo "=== byre: mimo-shared-auth — one Xiaomi MiMo key for all your projects ==="
echo "Paste a Xiaomi MiMo API key (platform or Token Plan) to save it in byre's"
echo "machine-scoped identity volume. Press Enter to skip; this box can still"
echo "receive XIAOMI_API_KEY directly, or use mimo's own paste-code login."
printf "API key: "
IFS= read -rs key || key=
echo ""

# Trim whitespace without echoing the credential. Only the tp- prefix is
# inspected below (for advice, never rejection): platform keys publish no
# stable prefix that is safe to validate here.
key=$(printf '%s' "$key" | tr -d '[:space:]')
[ -n "$key" ] || {
    echo "byre: skipped — no shared MiMo key saved."
    exit 0
}

# A stored model (left by a rotation that removed only api-key) is offered
# as the Enter default -- read only through a non-symlink dir, the bar the
# writes below enforce.
current_model=
if [ ! -L "$identity_dir" ] && [ -f "$model_file" ] && [ ! -L "$model_file" ] && [ -s "$model_file" ]; then
    current_model=$(tr -d '[:space:]' < "$model_file" 2>/dev/null)
fi
# A tp- key's detected model outranks a stored one: it was just proven
# against THIS key, while a stored model may name a rotated-away key's region.
detect_model "$key"
if [ -n "$detected" ]; then
    prompt_model "$detected" tp detected
else
    case "$key" in tp-*) prompt_model "$current_model" tp ;; *) prompt_model "$current_model" ;; esac
fi
warn_tp_model "$key" "${model:-$current_model}"
if [ -n "${MIMO_MODEL:-}" ]; then
    echo "byre: note — this project sets MIMO_MODEL=$MIMO_MODEL, which wins here over the shared model."
fi

prepare_dir
# Model first: the key file is the "configured" marker both this hook and
# mimo-login test, so it lands last -- a failed or interrupted model save
# stops here (save exits 1) and the next launch re-asks for both, rather
# than leaving a key with a missing model.
if [ -n "$model" ]; then
    save model "$model"
fi
save api-key "$key"
trap - EXIT HUP INT TERM
echo "byre: saved. This launch will use it; other running boxes pick it up when relaunched."
