#!/bin/bash
# byre's mimo launch adapter (a port of byre's built-in opencode adapter --
# MiMo Code is an opencode fork): build a MIMOCODE_CONFIG_CONTENT carrying
# the canonical /etc/byre/mcp.json servers (ADR 0033) and the baked agent
# context as an `instructions` entry (ADR 0046), then exec mimo. mimo loads
# MIMOCODE_CONFIG_CONTENT as the "local" layer and deep-MERGES it AFTER
# global + project config (packages/cli/src/config/config.ts:890), and
# `instructions` arrays SET-UNION across layers (mergeConfigConcatArrays,
# config.ts:53) -- so injected content COMPOSES with the user's own config
# and never replaces it. Pure injection: no state writes.
#
# Schema (packages/cli/src/config/mcp.ts:17,51 -- identical to opencode):
# the top-level `mcp` map, keyed by name, discriminated on `type`:
#   stdio  -> mcp.<name> = {type:"local",  command:[cmd, arg...]}
#   remote -> mcp.<name> = {type:"remote", url, headers:{Name:Value}}
# `command` is ONE combined array (binary + args).
#
# Env mapping: mimo spawns local MCP servers with {...childProcessEnv(),
# ...mcp.environment} (packages/cli/src/mcp/index.ts:676), where
# childProcessEnv is the full process env MINUS only MIMOCODE_AUTH_CONTENT
# and MIMOCODE_CONFIG_CONTENT (util/credential-env.ts) -- so the file's
# `x_byre_env` NAMES are already visible to a local server and need no
# `environment` block here. (The scrub also means the expanded header
# values below never reach a local server or the bash tool by inheritance.)
# Remote `headers` take literal VALUES only, so `${VAR}` refs are expanded
# HERE at launch ($ENV); an unset ref stays literal (claude/codex parity).
set -eu

# Overridable for tests; byre boxes use the bake.
MCP=${BYRE_MCP_CONFIG:-/etc/byre/mcp.json}

byre_mcp="{}"
if [ -r "$MCP" ]; then
  byre_mcp=$(jq -c '
    def expand: gsub("\\$\\{(?<n>[A-Za-z_][A-Za-z0-9_]*)\\}"; ($ENV[.n] // "${\(.n)}"));
    (.mcpServers // {}) | to_entries | map(
      .key as $k |
      if .value.url then
        { ($k): ({ type: "remote", url: .value.url }
          + (if (.value.headers // {}) != {}
             then { headers: (.value.headers | with_entries(.value |= expand)) }
             else {} end)) }
      else
        { ($k): { type: "local", command: ([.value.command] + (.value.args // [])) } }
      end
    ) | add // {}
  ' "$MCP")
fi

# Agent context (ADR 0046): the baked file rides mimo's `instructions`
# config key -- absolute paths are globbed as files and appended to the
# system context (packages/cli/src/session/instruction.ts:161; a missing
# file is a silent no-op, but the bake makes it unconditional). When the box
# (or a user) has ALREADY set MIMOCODE_CONFIG_CONTENT, byre's content
# deep-merges ON TOP: mcp servers win per-name, instructions UNION. A bare
# string `instructions` coerces to a one-element array rather than bricking
# the launch on a jq type error; any other wrong type is dropped. Unparseable
# pre-set JSON is replaced (mimo would refuse it anyway). Per-session
# additions ($BYRE_SESSION_CONTEXT) don't ride this file-path channel.
CTX=${BYRE_AGENT_CONTEXT:-/etc/byre/agent-context.md}
base=${MIMOCODE_CONFIG_CONTENT:-'{}'}
printf '%s' "$base" | jq empty 2>/dev/null || base='{}'
MIMOCODE_CONFIG_CONTENT=$(printf '%s' "$base" \
  | jq -c --argjson mcp "$byre_mcp" --arg ctx "$CTX" '
      . * {mcp: ((.mcp // {}) * $mcp)}
      | ((.instructions // []) | if type == "string" then [.] elif type != "array" then [] else . end) as $ins
      | .instructions = ($ins + (if ($ins | index($ctx)) then [] else [$ctx] end))
      | if .mcp == {} then del(.mcp) else . end')

# The box's default model, from byre-mimo-model (installed beside this
# adapter; see its header): MIMO_MODEL when set, else -- for a Token Plan
# (tp-) key -- the regional xiaomi-token-plan-<region>/<model> it detects by
# probing (cached per project in mimo's data dir), else nothing. This is
# what makes a bare Token Plan key work with NO configuration: such a key is
# valid only on its region's provider and 401s on mimo's default xiaomi/*
# (verified live 2026-10-01). MIMO_MODEL still overrides. Folded in as
# top-level `model` ("provider/model", config.ts schema -- the same key `-m`
# overrides per run). Why here and not the global
# ~/.config/mimocode/mimocode.jsonc: that file is image-layer in a byre box
# and resets on rebuild; env and the data-dir cache survive. Precedence:
# the resolver > a `model` already in a pre-set MIMOCODE_CONFIG_CONTENT >
# the global config (this layer deep-merges after global, config.ts:890).
# It is a DEFAULT, not a lock (source-verified 2026-10-01, mimo 0.1.15): an
# explicit `-m` beats it everywhere; in the TUI the last model picked there
# (recent, in the image-layer ~/.local/state/mimocode/model.json) beats it
# too (cli/cmd/tui/util/model.ts:48), until a rebuild clears that file;
# `mimo run` takes it first (Provider.defaultModel,
# provider/provider.ts:1913). An id the registry doesn't list is NOT an
# error there: mimo log.warns and falls through to its own default.
# The resolver never fails a launch (it prints nothing and warns instead);
# the `|| model=` covers a missing or broken copy all the same. Looked up
# beside this script first (both live in /usr/local/bin in a box, and side
# by side in the skill's source dir), then on PATH.
resolver="$(dirname -- "$0")/byre-mimo-model"
[ -x "$resolver" ] || resolver=byre-mimo-model
model=$("$resolver") || model=
if [ -n "$model" ]; then
  MIMOCODE_CONFIG_CONTENT=$(printf '%s' "$MIMOCODE_CONFIG_CONTENT" \
    | jq -c --arg m "$model" '.model = $m')
fi
export MIMOCODE_CONFIG_CONTENT

exec mimo "$@"
