#!/bin/bash
# byre's vibe launch adapter: deliver the canonical /etc/byre/mcp.json
# servers (ADR 0033) through Mistral Vibe's VIBE_MCP_SERVERS env layer and
# the baked agent context plus the launcher's per-session additions
# ($BYRE_SESSION_CONTEXT) as an AGENTS.md in an `--add-dir` directory
# (ADR 0046), then exec vibe. Pure injection: byre writes NOTHING into
# ~/.vibe -- $VIBE_HOME/AGENTS.md and config.toml are the user's files.
#
# MCP. Every Vibe config field is overridable by env VIBE_<FIELD> (pydantic-
# settings; lists/objects as JSON), and the env layer sits ABOVE the user's
# config.toml (vibe/core/config/default_orchestrator.py:68-78) while
# `mcp_servers` lists union-merge by server name across layers -- so the
# injected servers COMPOSE with the user's own and win per name. Verified
# live with the 2.26.0 bundle: VIBE_MCP_SERVERS='[{...stdio...}]' logs
# "Initializing MCP integrations (1 servers)" (probe REPORT.md B).
# Schema (vibe/core/config/models.py:202-447, MCPServer discriminated on
# `transport`):
#   stdio  -> {name, transport:"stdio", command:[cmd], args:[...], env:{}}
#   remote -> {name, transport:"streamable-http", url,
#              auth:{type:"static", headers:{Name:Value}}}
# `command` goes as a ONE-element LIST: a string command is shlex.split
# (MCPStdio.argv, models.py:435-441), which would break a path with spaces.
# byre's "http" type is streamable HTTP (claude's `type: "http"`), hence
# "streamable-http" rather than vibe's legacy "http" transport.
#
# Env mapping -- unlike claude/mimo, a vibe stdio server does NOT inherit
# the agent's environment: vibe hands only the config `env` dict to
# mcp.StdioServerParameters (vibe/core/tools/mcp/registry.py:420,446;
# tools.py:393-396), and the mcp SDK merges that over a MINIMAL default
# (HOME, PATH, SHELL, TERM, ...). Verified live (REPORT.md B2/B3): a parent
# var outside `env` never reached the child. So each `x_byre_env` NAME that
# is SET in this launch env is copied into the server's `env` map by VALUE;
# an unset name is omitted (never a literal "${NAME}" -- that would be a
# garbage credential). byre's env contract (the declared names reach the
# server) holds; undeclared names do not reach it, by vibe's design.
# Remote `headers` take literal VALUES only, so `${VAR}` refs are expanded
# HERE at launch ($ENV); an unset ref stays literal (claude/codex parity).
#
# Test seams: BYRE_MCP_CONFIG, BYRE_AGENT_CONTEXT, BYRE_VIBE_CONTEXT_DIR
# (the baked fallback dir) -- byre boxes use the bakes. BYRE_VIBE_LAUNCH_DRYRUN=1
# prints the composed VIBE_MCP_SERVERS and the vibe argv (one per line) and
# exits 0 instead of exec'ing vibe.
set -eu

MCP=${BYRE_MCP_CONFIG:-/etc/byre/mcp.json}

byre_mcp="[]"
if [ -r "$MCP" ]; then
  byre_mcp=$(jq -c '
    def expand: gsub("\\$\\{(?<n>[A-Za-z_][A-Za-z0-9_]*)\\}"; ($ENV[.n] // "${\(.n)}"));
    (.mcpServers // {}) | to_entries | map(
      .key as $k |
      if .value.url then
        { name: $k, transport: "streamable-http", url: .value.url }
        + (if (.value.headers // {}) != {}
           then { auth: { type: "static", headers: (.value.headers | with_entries(.value |= expand)) } }
           else {} end)
      else
        ((.value.x_byre_env // [])
          | map(select(type == "string") | select($ENV[.] != null) | { (.): $ENV[.] })
          | add // {}) as $env |
        { name: $k, transport: "stdio", command: [.value.command], args: (.value.args // []) }
        + (if $env != {} then { env: $env } else {} end)
      end
    )
  ' "$MCP")
fi

# A VIBE_MCP_SERVERS the box (or a user) ALREADY set is kept and unioned by
# server name: byre's entry wins on a name clash, every other entry stays,
# in its original order, ahead of byre's. Anything that is not a JSON array
# is replaced -- vibe would reject it at config load anyway, which would
# brick the launch. Exported only when the result is non-empty; an empty
# list leaves nothing behind.
base=${VIBE_MCP_SERVERS:-'[]'}
printf '%s' "$base" | jq -e 'type == "array"' >/dev/null 2>&1 || base='[]'
VIBE_MCP_SERVERS=$(printf '%s' "$base" | jq -c --argjson byre "$byre_mcp" '
  ($byre | map(.name)) as $names
  | map(select((type == "object" and (.name | type) == "string"
                and (.name as $n | $names | any(.[]; . == $n))) | not))
  + $byre')
if [ "$VIBE_MCP_SERVERS" = "[]" ]; then
  unset VIBE_MCP_SERVERS
else
  export VIBE_MCP_SERVERS
fi

# Agent context (ADR 0046). Vibe has no append-a-file flag; what it has is
# `--add-dir DIR` (vibe/cli/entrypoint.py:174), which opens DIR as an extra,
# implicitly trusted project root (harness_files/_harness_manager.py:304-
# 312) whose AGENTS.md lands in the system prompt under "## Project
# instructions" -- even when the cwd is untrusted, symlinks followed
# (load_project_docs, :281-300; verified live, REPORT.md A and amendment 5).
# The baked context and the session additions are composed into ONE
# AGENTS.md in a launch-owned dir (the claude adapter's merge, ported).
#
# ONE launch-owned path, replaced on every start: exec replaces this shell,
# so nothing can clean up after vibe exits -- a fresh mktemp name per
# launch would accumulate context copies across container restarts. One
# launcher runs per container, so the fixed name needs no uniqueness, and
# the stable path stays readable in-box. The dir must be a real directory
# this user owns, never a symlink (a planted link would route byre's write
# into its target): mkdir, then probe. The compose goes through a mktemp
# file and an atomic rename onto the fixed name: a plain `>` to a
# predictable path would FOLLOW anything planted there (rename replaces the
# plant instead). A planted DIRECTORY at the AGENTS.md name would swallow
# the mv -- POSIX mv moves the file INTO it, and reports SUCCESS -- so probe
# with -d first (-d follows symlinks, covering the symlink-to-directory
# arm), and re-probe with -f AFTER the mv: a directory landing between the
# two swallows the temp file but leaves the fixed name a non-file, so the
# -f probe takes the degrade branch instead of handing vibe a directory.
# The residue of that lost race is one context copy inside the agent-made
# directory: nothing overwritten, same-trust content. What no probe can
# close is the read side -- the dir lives in TMPDIR, so a concurrently
# running agent can corrupt or delete it before vibe reads it; that only
# sabotages the agent's own context.
# An --add-dir root also contributes its .vibe/{hooks.toml,tools,skills,
# agents,prompts,plugins} (_harness_manager.py:136-212), so a `.vibe`
# planted in this dir would load hooks into every later launch: removed
# here (the dir is ours; nothing byre writes is named .vibe). Same-trust
# residue: a plant landing after the rm and before vibe reads.
# Best-effort throughout: context is informational, so a failure composing
# it must never block the launch -- degrade to the baked dir (its AGENTS.md
# is a symlink to the baked file, made at build; used only when that
# resolves to a regular readable file), then to no injection at
# all, dropping the partial write rather than injecting it. An empty
# composition (no readable baked file, no session additions) injects
# nothing. NOT `if ! { ...; } > file`: bash treats a failure of the
# redirect itself as success there (verified on 5.2.15), which would hand
# vibe a dead path instead of degrading -- the || form takes the failure
# branch.
# $CTX counts as readable only as a REGULAR readable file (-f follows a
# symlink, so a link to a regular file is fine): a directory there makes
# cat fail, and a FIFO makes it BLOCK, hanging the launch on a planted or
# misconfigured BYRE_AGENT_CONTEXT. A non-regular $CTX is treated like an
# absent one. And the compose is a function whose status is each read's
# own: in `{ [ -r "$CTX" ] && cat "$CTX"; printf ...; }` the group returned
# printf's status, so a failed cat was masked and an empty or partial
# composition was injected instead of degrading.
CTX=${BYRE_AGENT_CONTEXT:-/etc/byre/agent-context.md}
BAKED=${BYRE_VIBE_CONTEXT_DIR:-/etc/byre/vibe-context}
ctxdir="${TMPDIR:-/tmp}/byre-vibe-context"
merged="$ctxdir/AGENTS.md"
tmp=""
ctx_readable() { [ -f "$CTX" ] && [ -r "$CTX" ]; }
compose_context() {
  if ctx_readable; then cat "$CTX" || return 1; fi
  printf '%s' "${BYRE_SESSION_CONTEXT:-}"
}
if ! ctx_readable && [ -z "${BYRE_SESSION_CONTEXT:-}" ]; then
  ctxdir=""
else
  mkdir -m 0700 "$ctxdir" 2>/dev/null || true
  if [ -d "$ctxdir" ] && [ ! -L "$ctxdir" ] && [ -O "$ctxdir" ] &&
    rm -rf -- "$ctxdir/.vibe" 2>/dev/null &&
    tmp=$(mktemp "$ctxdir/.AGENTS.md.XXXXXXXX" 2>/dev/null); then
    compose_context > "$tmp" 2>/dev/null &&
      [ ! -d "$merged" ] &&
      mv -f "$tmp" "$merged" 2>/dev/null &&
      [ -f "$merged" ] ||
      { rm -f "$tmp" 2>/dev/null || true; ctxdir=""; }
  else
    ctxdir=""
  fi
  if [ -z "$ctxdir" ] && [ -f "$BAKED/AGENTS.md" ] && [ -r "$BAKED/AGENTS.md" ]; then
    ctxdir=$BAKED
  fi
fi

if [ -n "$ctxdir" ]; then
  set -- --add-dir "$ctxdir" "$@"
fi

if [ "${BYRE_VIBE_LAUNCH_DRYRUN:-}" = 1 ]; then
  printf 'VIBE_MCP_SERVERS=%s\n' "${VIBE_MCP_SERVERS-<unset>}"
  printf 'argv: vibe\n'
  printf '  %s\n' "$@"
  exit 0
fi
exec vibe "$@"
