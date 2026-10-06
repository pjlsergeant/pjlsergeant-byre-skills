#!/usr/bin/env bash
# byre-codereview — an independent second-opinion review of the current changes.
# Shipped by the codereview skill; pairs with a reviewer skill that installs the
# reviewer binary: codex (the default), grok, claude, opencode, mimo, zai,
# and/or vibe.
# Reviews the working tree's git changes and prints findings, and appends them
# to .byre-devlog/reviews.md.
#
#   byre-codereview                        # review current changes (codex)
#   byre-codereview "focus area"           # focus the review
#   byre-codereview --continue "..."       # re-check after fixes (resumes session)
#   byre-codereview --reviewer grok "..."  # use grok as the reviewer
#   byre-codereview --raw "prompt"         # your prompt verbatim, no review prompt
#   byre-codereview --timeout 10m "..."    # give up (exit 124) after 10 minutes
#
# BYRE_REVIEWER sets the default reviewer (codex when unset). A reviewer is
# "harness" or "harness:model" — see the parsing below; every harness hands the
# model to its own CLI's model flag (vibe, which has none, to its active_model
# setting), and a bare harness means that CLI's own default.
# BYRE_REVIEW_TIMEOUT sets the default --timeout (none when unset).
#
# zai is the Z.AI (GLM) Codex wrapper: a reviewer under its OWN name, never a
# silent fallback for codex. The Running line and reviews.md must say who
# actually reviewed, and in a zai-authored box a zai review is a same-family
# second pass, not an independent opinion.
#
# --raw replaces the built-in review prompt entirely: the arguments become the
# whole prompt (required). The mechanics stay — reviewer enforcement flags,
# session resume, the tripwire, the reviews.md log (tagged "raw") — but the
# execution policy below is only as strong as YOUR prompt, and the truncation
# marker check is skipped since nothing mandates a "Probes run:" section.
#
# Review execution policy (the prompt below enforces it, the tripwire checks
# it): the reviewer may run cheap, targeted, read-only probes to put evidence
# behind a specific finding — a --help, a one-liner repro — but never builds or
# the project's test suite (the author owns green; re-running it buys latency,
# not evidence), and never anything that mutates the tree, git state, or shared
# state. After every run the script re-hashes the working tree and warns loudly
# if it changed (legibility, not a gate).
set -euo pipefail

usage() {
  cat <<'EOF'
byre-codereview — an independent second-opinion review of the current changes.

Usage:
  byre-codereview                        review current changes
  byre-codereview "focus area"           review current changes, focused on a topic
  byre-codereview --continue "..."       re-check after fixes (resumes prior session)
  byre-codereview --reviewer <name> ...  choose the reviewer: codex (default) | grok | claude | opencode | mimo | zai | vibe
                                         alone, the reviewer runs its CLI's own default model;
                                         <name>:<model> pins one, passed to that CLI as-is:
                                           codex:gpt-5.6-sol     (no model-list command; a model the
                                                                 account can't use fails with codex's
                                                                 own 400, and the script names it)
                                           zai:glm-4.5
                                           grok:<model>          ('grok models' lists them)
                                           claude:opus           (an alias or a full model id)
                                           opencode:openrouter/~openai/gpt-latest
                                           mimo:xiaomi/mimo-v2.6-pro
                                           mimo:xiaomi-token-plan-sgp/mimo-v2.6-pro  (a Token Plan
                                                                 tp- key: pin its region's provider)
                                           vibe:<alias>          (an alias from the box's
                                                                 ~/.vibe/config.toml [[models]];
                                                                 vibe has no --model flag)
                                         bare mimo instead pins what byre-mimo-model resolves
                                         (MIMO_MODEL, or a Token Plan key's region) and names it
                                         zai reviews through the isolated Z.AI Codex home (GLM)
  byre-codereview --timeout <duration>   give up after <duration> and exit 124, e.g. --timeout 10m
                                         (coreutils timeout syntax: 90, 90s, 2.5m, 1h; 0 = none)
  byre-codereview --raw "prompt"         send YOUR prompt verbatim (skips the
                                         built-in review prompt; mechanics stay)
  byre-codereview --raw -- "--anything"  -- ends option parsing, so option-shaped
                                         prompt text passes through

BYRE_REVIEWER sets the default reviewer; BYRE_REVIEW_TIMEOUT the default --timeout
(no timeout when unset).
EOF
}

REVIEWER="${BYRE_REVIEWER:-codex}"
CONTINUE=false
RAW=false
TIMEOUT="${BYRE_REVIEW_TIMEOUT:-}"
timeout_flag=false
FOCUS=()
expect_reviewer=false
expect_timeout=false
ddash=false
for arg in "$@"; do
  if [ "$ddash" = true ]; then
    FOCUS+=("$arg")
    continue
  fi
  if [ "$expect_reviewer" = true ]; then
    REVIEWER="$arg"
    expect_reviewer=false
    continue
  fi
  if [ "$expect_timeout" = true ]; then
    TIMEOUT="$arg"
    expect_timeout=false
    continue
  fi
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --continue) CONTINUE=true ;;
    --raw) RAW=true ;;
    --reviewer) expect_reviewer=true ;;
    --reviewer=*) REVIEWER="${arg#--reviewer=}" ;;
    --timeout) expect_timeout=true; timeout_flag=true ;;
    --timeout=*) TIMEOUT="${arg#--timeout=}"; timeout_flag=true ;;
    # Everything after -- is prompt text, never an option — the only way an
    # option-shaped prompt ("--help") can reach the reviewer, raw or focused.
    --) ddash=true ;;
    *) FOCUS+=("$arg") ;;
  esac
done
if [ "$expect_reviewer" = true ]; then
  echo "byre-codereview: --reviewer needs a value: a harness (codex | grok | claude | opencode | mimo | zai | vibe)," >&2
  echo "  optionally with a model as <harness>:<model> (e.g. claude:opus)." >&2
  exit 2
fi
if [ "$expect_timeout" = true ]; then
  echo "byre-codereview: --timeout needs a duration (e.g. --timeout 10m)." >&2
  exit 2
fi
# --timeout takes coreutils timeout(1) syntax — integer or decimal, optional
# s/m/h/d suffix — checked here so a typo fails in milliseconds with a clear
# message, not as a cryptic timeout(1) error after the run was announced. An
# explicit flag is validated even when empty ("--timeout=" is a typo, not a
# request); an empty BYRE_REVIEW_TIMEOUT just means unset. A zero duration
# disables timeout(1) itself, so it is normalized to "no timeout" here, where
# the Running line would otherwise claim a "(timeout: 0)" that never fires —
# which also makes --timeout 0 the way to override BYRE_REVIEW_TIMEOUT once.
if [ "$timeout_flag" = true ] || [ -n "$TIMEOUT" ]; then
  if ! [[ "$TIMEOUT" =~ ^[0-9]+(\.[0-9]+)?[smhd]?$ ]]; then
    if [ "$timeout_flag" = true ]; then src="--timeout"; else src="BYRE_REVIEW_TIMEOUT"; fi
    echo "byre-codereview: invalid $src '$TIMEOUT'." >&2
    echo "  Use coreutils timeout syntax: a number with an optional s/m/h/d suffix, e.g. 600, 10m, 1.5h." >&2
    exit 2
  fi
  [[ "$TIMEOUT" =~ ^0+(\.0+)?[smhd]?$ ]] && TIMEOUT=""
fi
if [ -n "$TIMEOUT" ] && ! command -v timeout >/dev/null 2>&1; then
  echo "byre-codereview: --timeout needs coreutils 'timeout', which is not on PATH." >&2
  exit 2
fi
# The timeout bounds the whole RUN, not each reviewer invocation: a resume
# that fails late and falls back to a fresh review must not get a second full
# allowance (found by a codex review of this feature, 2026-10-01 — --timeout
# 10m could take nearly 20m). So it becomes one absolute DEADLINE, set here,
# that run_reviewer_cmd counts down to. Whole seconds, rounded UP (awk, since
# bash has no float arithmetic), so 0.5s is 1s, never 0. Epoch seconds give
# the deadline ~1s of slack either way; fine for a bound measured in minutes.
DEADLINE=""
if [ -n "$TIMEOUT" ]; then
  case "$TIMEOUT" in
    *d) mult=86400 ;; *h) mult=3600 ;; *m) mult=60 ;; *) mult=1 ;;
  esac
  TIMEOUT_SECS=$(awk -v n="${TIMEOUT%[smhd]}" -v m="$mult" \
    'BEGIN { x = n * m; i = int(x); if (x > i) i++; print i }')
  DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
fi
if [ "$RAW" = true ] && [ "${#FOCUS[@]}" -eq 0 ]; then
  echo "byre-codereview: --raw needs a prompt (the arguments become the whole prompt)." >&2
  exit 2
fi

# A reviewer is "harness" or "harness:model": the harness names the CLI, and
# everything after the FIRST colon is a model spec handed to that harness
# (model ids may themselves contain slashes, e.g. openrouter/~openai/...).
# $REVIEWER keeps the full user-given string for display — the Running line
# and the reviews.md heading show what actually reviewed; $HARNESS drives
# command lookup, session files, and dispatch. Every harness consumes the
# model, each through its own CLI's flag (codex/zai/grok -m, claude --model,
# opencode/mimo --model; vibe has no model flag, so VIBE_ACTIVE_MODEL), on
# the fresh and resume paths alike. The model is
# passed through unvalidated: a model the CLI can't run must FAIL from that
# CLI, never be swapped for its default while the log names the pinned one.
# A bare harness passes no flag at all, so the CLI's own default applies.
HARNESS="$REVIEWER"
MODEL=""
case "$REVIEWER" in
  *:*)
    HARNESS="${REVIEWER%%:*}"
    MODEL="${REVIEWER#*:}"
    # "claude:" (empty model) means no model — same as bare "claude".
    [ -z "$MODEL" ] && REVIEWER="$HARNESS"
    ;;
esac

case "$HARNESS" in
  codex|grok|claude|opencode|mimo|zai|vibe) ;;
  *)
    echo "byre-codereview: unsupported reviewer '$HARNESS' (codex | grok | claude | opencode | mimo | zai | vibe," >&2
    echo "  each optionally as <harness>:<model>, e.g. codex:gpt-5.6-sol)." >&2
    exit 2
    ;;
esac

if ! command -v "$HARNESS" >/dev/null 2>&1; then
  echo "byre-codereview: $HARNESS not found on PATH." >&2
  echo "  Add the $HARNESS skill (skills = [\"$HARNESS\", \"codereview\"]) and rebuild." >&2
  for other in codex grok claude opencode mimo zai vibe; do
    [ "$other" = "$HARNESS" ] && continue
    if command -v "$other" >/dev/null 2>&1; then
      echo "  ($other is available: byre-codereview --reviewer $other)" >&2
    fi
  done
  exit 127
fi

# zai pre-flight. Two cheap checks BEFORE a run that would otherwise burn
# minutes failing:
# - ZAI_CODEX_BIN points zai at byre's Codex launch adapter, which injects the
#   AUTHORING agent's MCP config and developer context. A reviewer must start
#   unprimed — the review prompt only — so the review path always drops back to
#   the plain codex binary. (The isolation stays: zai still wraps it in the
#   Z.AI CODEX_HOME.)
# - ZAI_API_KEY is zai's only credential (env, never config). Without it Z.AI
#   401s, which Codex surfaces as five reconnect attempts and a misleading
#   "stream closed" — better refused here than diagnosed after the fact.
if [ "$HARNESS" = zai ]; then
  unset ZAI_CODEX_BIN
  if [ -z "${ZAI_API_KEY:-}" ]; then
    echo "byre-codereview: zai needs ZAI_API_KEY in the environment, and it is not set." >&2
    echo "  byre's zai skill reads the key from the environment only (never from config)." >&2
    echo "  Forward it from the host (env_from_host), or install/repair" >&2
    echo "  pjlsergeant/zai-shared-auth, which asks once and exports it every launch." >&2
    exit 1
  fi
fi

# codex pre-flight, the mirror image of zai's: a zai-agent box exports
# CODEX_HOME pointing at zai's isolated home for the whole session, so plain
# `codex` — including the DEFAULT reviewer — silently runs Z.AI's GLM while
# the Running line and reviews.md say "codex". No alias required; inheritance
# does the forgery (verified in-box 2026-08-16: --reviewer codex answered
# "GLM-4.5, trained by Z.ai"). Strip the inherited zai home so codex uses its
# OWN home: a real codex review if that home is logged in, an honest auth
# failure (with the zai hint below) if it is not. A CODEX_HOME pointing
# anywhere else is a deliberate user choice and is left alone.
if [ "$HARNESS" = codex ]; then
  zai_home="${ZAI_CODEX_HOME:-/home/dev/.zai-codex-home}"
  if [ "${CODEX_HOME:-}" = "$zai_home" ]; then
    unset CODEX_HOME
    echo "byre-codereview: note — stripped the inherited zai CODEX_HOME ($zai_home)" >&2
    echo "  so the codex reviewer uses codex's own home. Without this it would silently" >&2
    echo "  review as Z.AI's GLM while the log named it codex. Want GLM? Say so:" >&2
    echo "  byre-codereview --reviewer zai" >&2
  fi
fi

# mimo pre-flight. Two inherited variables go, unconditionally and silently,
# so the reviewer starts from mimo's own defaults (the idea of the zai strip
# above). MIMOCODE_DANGEROUSLY_SKIP_PERMISSIONS: pjlsergeant/mimo launches the
# authoring agent with it, and this script runs as that agent's child. In
# mimo 0.1.15 it merges an allow-all base under every config layer
# (config.ts:972, source 2026-10-01): explicit denies still win, but every
# "ask" becomes an allow, silently lifting the external_directory ask that
# confines a headless reviewer to the repo. MIMOCODE_CONFIG_CONTENT:
# byre-mimo-launch exports it carrying the author's MCP servers and baked
# context as `instructions`, a config layer to mimo (config.ts:890), so an
# inherited copy would prime the reviewer with the author's context and
# tools. mimo already scrubs it from children its tools spawn
# (util/credential-env.ts, effect/cross-spawn-spawner.ts:112; live
# 2026-10-01, mimo 0.1.15's bash tool saw it unset); the unset covers every
# other route. The box's ~/.config/mimocode config and auth still load.
# MIMOCODE_AUTH_CONTENT stays: credentials, not context, so stripping it
# could only turn a working review into an auth failure.
# A bare `--reviewer mimo` then pins what byre-mimo-model resolves
# (pjlsergeant/mimo's resolver: MIMO_MODEL when set, else a Token Plan key's
# probed region, cached per project, else nothing). byre-mimo-launch makes
# that mimo's default only through the MIMOCODE_CONFIG_CONTENT just unset,
# and a reviewer runs plain `mimo`, so it must ask the resolver itself; on a
# Token Plan box that is the only provider the tp- key can use. $REVIEWER is
# read at call time by announce_*/record_review/save_session, so the Running
# line, the reviews.md heading and session-file line 2 name the resolved
# model as they would a typed pin, which already set MODEL and wins. No
# resolver on PATH: mimo's own default. -q: an unresolved region stays quiet
# here because report_failure_mimo explains the 401 it causes (a malformed
# MIMO_MODEL, dropped by the resolver, runs as bare `mimo`). `|| true`: the
# resolver exits 0 on every path it knows, but set -e must not end a review
# on a broken copy. A bad value fails from mimo, under its own name.
if [ "$HARNESS" = mimo ]; then
  unset MIMOCODE_DANGEROUSLY_SKIP_PERMISSIONS MIMOCODE_CONFIG_CONTENT
  if [ -z "$MODEL" ] && command -v byre-mimo-model >/dev/null 2>&1; then
    MODEL=$(byre-mimo-model -q) || true
    if [ -n "$MODEL" ]; then
      REVIEWER="mimo:$MODEL"
    fi
  fi
fi

# vibe pre-flight. VIBE_MCP_SERVERS goes, unconditionally and silently (the
# mimo MIMOCODE_CONFIG_CONTENT rationale above): pjlsergeant/vibe's
# byre-vibe-launch exports it into the AUTHORING vibe carrying byre's MCP
# servers, this script runs as a child of that vibe's bash tool, and vibe
# reads any config field from VIBE_<FIELD> above the user's config.toml
# (vibe/core/config/default_orchestrator.py:68-78), so an inherited copy
# would start the author's MCP servers inside the reviewer. Their tools could
# not execute anyway (--enabled-tools, see run_vibe), but a stdio server is a
# process the reviewer would spawn, and the review should not depend on that.
# Everything else stays: the box's ~/.vibe config, its .env key, and any
# VIBE_ACTIVE_MODEL the box exports (that IS this box's vibe default).
if [ "$HARNESS" = vibe ]; then
  unset VIBE_MCP_SERVERS
fi

# Persisted artifacts live in .byre-devlog/ at the repo root — a self-ignoring
# dir (its own .gitignore is "*"), so the review log and agent diary persist via
# the workspace mount but never land in git and need no per-project .gitignore
# entry. byre_devlog_dir (shared lib, shipped alongside this script) provides
# the dir; a user-placed node at that path is never destroyed — the lib warns
# and stands down, which under set -e ends the review here, loudly.
if root=$(git rev-parse --show-toplevel 2>/dev/null); then
  cd "$root"
else
  root="$PWD"
fi
. /usr/local/lib/byre-devlog-lib.sh
byre_devlog_dir "$root"
REVIEW_DIR="$root/.byre-devlog"
LOG_FILE="$REVIEW_DIR/reviews.md"
# Sessions are per-reviewer: resuming a codex thread with grok (or vice versa)
# is meaningless. The codex file keeps its historical name so a box upgraded
# mid-loop can still --continue.
# zai gets its own file for a sharper reason: its ids are the SAME shape as
# codex's (it is the same CLI) but its threads live in a different CODEX_HOME
# and a different provider. Sharing codex's file would make --continue resume
# another provider's thread by accident — the ids validate, so nothing would
# catch it. zai must be chosen by name, and its sessions kept apart.
# Keyed by harness, not by model: a --continue with a different model resumes
# the same thread (every CLI here applies the model per-prompt, not per-session,
# except vibe, which keeps a thread's model; run_resume_vibe handles that).
# That crossing is legitimate — handing a thread to a stronger model is a real
# move — but it must be VISIBLE. So every harness's file has one shape: line 1
# the session id, line 2 the reviewer string that started the thread, and
# every resume path warns (warn_cross_reviewer_resume) when it differs from
# the resuming one (surfaced for opencode by a deepseek review, 2026-08-08;
# uniform since every harness takes a model). A one-line file — written before
# its harness took a model — has no line 2 and resumes silently; only line 1
# is ever parsed as the id. codex/zai resume also REWRITES the file (see
# run_resume_codex_family), in the same shape. mimo's ids are the
# same shape as opencode's (it is a fork), so the separate file is what keeps
# --continue from resuming an opencode thread in mimo's session store, or the
# reverse — the ids would validate either way.
# vibe's ids are UUID-shaped too (lowercase 8-4-4-4-12 hex, though not
# RFC-4122), so its own file is again what keeps codex's/claude's/grok's
# threads out of its session store.
case "$HARNESS" in
  codex)    SESSION_FILE="$REVIEW_DIR/.review-session" ;;
  grok)     SESSION_FILE="$REVIEW_DIR/.review-session-grok" ;;
  claude)   SESSION_FILE="$REVIEW_DIR/.review-session-claude" ;;
  opencode) SESSION_FILE="$REVIEW_DIR/.review-session-opencode" ;;
  mimo)     SESSION_FILE="$REVIEW_DIR/.review-session-mimo" ;;
  zai)      SESSION_FILE="$REVIEW_DIR/.review-session-zai" ;;
  vibe)     SESSION_FILE="$REVIEW_DIR/.review-session-vibe" ;;
esac

# The reviewer string that started this harness's saved thread (line 2 of the
# session file; empty for a one-line file or none).
session_starter() { sed -n 2p "$SESSION_FILE" 2>/dev/null || true; }

# A resume under a different reviewer string feeds the OLD model's thread —
# its findings, your replies — to the new one while the Running line and the
# reviews.md heading name only the new one. Legitimate, but never silent.
# Warn-only, and an absent line 2 (a one-line session file) says nothing.
# Every run_resume_* calls this first.
warn_cross_reviewer_resume() {
  local prev; prev=$(session_starter)
  if [ -n "$prev" ] && [ "$prev" != "$REVIEWER" ]; then
    echo "byre-codereview: note — resuming a session started by '$prev' as '$REVIEWER':" >&2
    echo "  the thread's earlier turns are the old model's. For an unprimed opinion" >&2
    echo "  from '$REVIEWER', run without --continue." >&2
  fi
}

# Every fresh run records its thread the same way (see the SESSION_FILE
# comment): id, then WHO started it.
save_session() { printf '%s\n%s\n' "$1" "$REVIEWER" > "$SESSION_FILE"; }

# RUN_NOTE annotates the "Running..." line: raw mode says so instead of echoing
# the whole prompt back as a "focus". TIMEOUT_NOTE rides both the Running and
# Continuing lines, so a caller sees the deadline before the wait starts. Both
# lines name $REVIEWER — the full user string, model included — for every
# harness, matching the reviews.md heading.
if [ "$RAW" = true ]; then RUN_NOTE=" (raw)"; else RUN_NOTE="${FOCUS:+ (focus: ${FOCUS[*]})}"; fi
TIMEOUT_NOTE="${TIMEOUT:+ (timeout: $TIMEOUT)}"
announce_fresh()  { echo "Running code review (${REVIEWER})${RUN_NOTE}${TIMEOUT_NOTE} — this may take several minutes..."; }
announce_resume() { echo "Continuing previous review session (${REVIEWER})${TIMEOUT_NOTE} — this may take several minutes..."; }

read -r -d '' PROMPT <<'EOF' || true
You are PURELY a code-review agent: you review, the author fixes. Do not modify
anything — not the working tree, not git state, not credentials or other shared
state. The working tree is re-checked after your run; a reviewer that mutates
the tree contaminates the thing under review.

NEVER run an authentication command of any CLI — no `login`, `logout`, `auth`,
or credential-writing subcommand, not even to check whether something works.
`codex login --with-api-key`, `grok login`, `opencode auth login`, and friends
WRITE credential state that is shared with the rest of the box and is NOT
covered by the tree tripwire, so nothing will catch it and nothing will roll
it back. A reviewer doing this has already logged a box out in the middle of a
review loop, taking the author's tooling down with it.

To be explicit about the line: `codex login --help` and `grok login --help` are
FINE and are the intended way to check what an auth flag does — `--help` prints
and exits without touching credentials. What is banned is invoking the flow
itself, including seemingly-harmless probes like `login --with-api-key` or
`login status`.

Do NOT run builds or the project's test suite — the author owns keeping those
green, and re-running them here adds minutes and no evidence. You MAY run
cheap, targeted, read-only probes (a --help, a one-liner repro, inspecting a
generated artifact) when a specific finding you are about to report depends on
a fact you can verify in seconds. If verifying a claim would be expensive or
have side effects, report the finding anyway with its confidence marked down
and say what would verify it.

Process:
1. Read any project guidance you can find (CLAUDE.md / AGENTS.md / README) for context.
   NEVER read `.byre-devlog/` — review logs, session/debug files, the diary.
   Those are audit artifacts ABOUT reviews, not project source: a fresh reviewer
   that reads an earlier review primes itself exactly as `--continue` would.
2. Run: git status, git diff, git diff --cached, git log --oneline -8.
3. Review the changes (committed-but-recent and uncommitted).

Focus on: correctness bugs and logic errors, missing edge cases, security issues,
and clear code-quality problems. Prefer a short list of high-confidence findings
over a long list of nits. For each finding give file:line, what's wrong, why,
and whether you verified it. End the report with a "Probes run:" list of any
commands you executed beyond the git reads above ("none" if none). Give the
full report as your final message.
EOF

if [ "$RAW" = true ]; then
  # --raw: the arguments ARE the prompt. The enforcement flags and tripwire
  # still apply; the policy the built-in prompt encodes does not.
  PROMPT="${FOCUS[*]}"
elif [ "${#FOCUS[@]}" -gt 0 ]; then
  PROMPT="$PROMPT

Pay particular attention to: ${FOCUS[*]}"
fi

OUT=$(mktemp "$REVIEW_DIR/.out.XXXXXX")
DBG=$(mktemp "$REVIEW_DIR/.dbg.XXXXXX")
cleanup() { rm -f "$OUT" "$DBG"; }

# Every reviewer invocation goes through here, so --timeout covers all seven
# harnesses on fresh and resume paths alike. Each call gets only what is LEFT
# of the run's DEADLINE (see the parsing above), so a resume and the fresh
# review it falls back to share one budget — the whole point. With nothing
# left, the CLI is not started at all: it returns 124 as timeout(1) would, so
# callers' exit_if_timed_out handles it the same way ($OUT/$DBG stay empty).
# Env assignments ride `env` inside
# the call (run_reviewer_cmd env VAR=... cmd) rather than as a `VAR=... cmd`
# prefix on it, so they unambiguously reach the reviewer itself, not just
# timeout(1). Default (non --foreground) timeout is deliberate: it puts itself
# and the command in a fresh process group and signals the WHOLE group on
# expiry, so a reviewer's spawned probes (a hung git, a repro that never
# returns) die with it instead of outliving the review. The cost of
# non-foreground — the child can't read the TTY — is moot: every invocation
# redirects stdin. -k 15s escalates to KILL if the CLI ignores TERM (exit 137
# instead of 124). That grace is per invocation, so the worst case is the
# deadline plus 15s — the fallback can't start a second grace, since a
# resume that hit the deadline exits rather than falling back.
run_reviewer_cmd() {
  [ -n "$DEADLINE" ] || { "$@"; return; }
  local remaining=$(( DEADLINE - $(date +%s) ))
  [ "$remaining" -gt 0 ] || return 124
  timeout -k 15s "${remaining}s" "$@"
}

# Called FIRST on every failure path, before any other classification: a
# timed-out run has no meaningful auth/model diagnosis, and a resume that
# timed out must NOT fall back to a fresh review — the run's deadline has
# passed, so the fallback could only report the same timeout (or, before the
# shared deadline, would have doubled the very wait the caller capped). A
# resume that fails for any OTHER reason still falls back, on whatever is left
# of the same deadline. 124/137 count only when a timeout was set: without
# one, 137 is an OOM-kill or similar, and the normal failure path owns it.
# $1 = the exit status, $2 = fresh|resume. A fresh run drops its session file
# (as every fresh failure does); a resume keeps it, so a later --continue can
# retry the same thread. Nothing is appended to reviews.md — failures never
# are.
exit_if_timed_out() {
  [ -n "$TIMEOUT" ] || return 0
  [ "$1" -eq 124 ] || [ "$1" -eq 137 ] || return 0
  echo "byre-codereview: review timed out after $TIMEOUT ($REVIEWER)." >&2
  [ -s "$OUT" ] && cat "$OUT" >&2
  echo "  Debug log: $DBG" >&2
  rm -f "$OUT"
  [ "$2" = fresh ] && rm -f "$SESSION_FILE"
  exit 124
}

# Snapshot of the working tree the reviewer must not change. NOTE the limit of
# what this can police: it covers the git working tree and nothing else. State
# outside it — credentials (~/.codex/auth.json, ~/.grok, opencode's
# ~/.local/share/opencode/auth.json, mimo's ~/.local/share/mimocode/auth.json,
# vibe's ~/.vibe/.env),
# other volumes, the rest of $HOME — is
# invisible here, so a reviewer that clobbers a login is
# caught by nobody (observed 2026-07-29: a reviewer ran `codex login
# --with-api-key` as a "probe" and logged the box out). The prompt above bans
# that explicitly because the tripwire structurally cannot.
# Contents: status + tracked-content diff + untracked-file CONTENT hashes
# (porcelain alone only lists
# untracked NAMES, so a content-only edit to an existing untracked file would
# slip through; ls-files -o is plumbing, so it also sidesteps a
# status.showUntrackedFiles=no config). Gitignored files (including .byre-devlog/,
# where this script's own log and temp files live) are deliberately outside
# the snapshot. Empty outside git — the tripwire is inert there, matching the
# rest of the script's non-repo degradation.
tree_state() {
  {
    git status --porcelain=v1 2>/dev/null
    git diff HEAD 2>/dev/null
    git ls-files -o --exclude-standard -z 2>/dev/null | sort -z | xargs -0r sha256sum 2>/dev/null
  } | sha256sum 2>/dev/null || true
}
# Fail open but SAY so: without sha256sum every snapshot is empty and the
# tripwire can't fire. All supported bases ship coreutils, so this is a
# one-line legibility note, not machinery.
command -v sha256sum >/dev/null 2>&1 \
  || echo "byre-codereview: note — sha256sum missing, the tree tripwire is disabled." >&2
# Every harness, before any reviewer runs (their children inherit it): a
# reviewer may legitimately import the code under review to verify a
# finding, and the byte-code cache that leaves (__pycache__/, untracked
# unless the repo ignores it) is a tree write that is nobody's finding --
# observed live 2026-10-02, a reviewer's `python3 -c "import calc"` fired
# this tripwire. Only Python honours it; other toolchains' caches are not
# covered (unverified whether any reviewer probe has tripped one).
export PYTHONDONTWRITEBYTECODE=1
PRE_STATE=$(tree_state)
# The observe-don't-mutate tripwire. A warning, not a rollback: byre's job is
# to make the violation legible, the human decides what to do with it. Fires
# on any tree change during the run — including a concurrent session's edits —
# so it names both possibilities. Installed as an EXIT trap so it also runs on
# the FAILURE paths: a run that mutates the tree and then dies is exactly the
# contamination case this exists for.
check_tripwire() {
  [ "$(tree_state)" = "$PRE_STATE" ] && return 0
  {
    echo ""
    echo "byre-codereview: WARNING — the working tree changed during this review."
    echo "  Either the reviewer modified files (it must not) or something edited the"
    echo "  tree concurrently. Inspect 'git status' / 'git diff' before trusting or"
    echo "  acting on these findings."
  } >&2
}
trap check_tripwire EXIT

# Append the captured findings to the review log with a timestamp + reviewer.
# A run that died mid-review can leave a plausible-looking fragment (grok's
# permission/sandbox deaths print a preamble, then stop — one got recorded as
# a clean review before this check). The prompt mandates a trailing
# "Probes run:" section, so its absence marks a likely truncation: record it,
# but say so — in the log heading and on stderr. Warn-only: a reviewer that
# merely forgot the section must not have its findings suppressed.
record_review() {
  [ -s "$OUT" ] || return 0
  # Tail-anchored, not body-wide: a review that QUOTES the mandate mid-body
  # (any review of this script would) and then dies must still be flagged —
  # the marker only counts as the trailing section it was mandated to be.
  # Raw runs skip the check entirely: only the built-in prompt mandates the
  # section, so its absence marks nothing.
  note=""
  if [ "$RAW" != true ] && ! tail -n 40 "$OUT" 2>/dev/null | grep -qi 'probes run'; then
    note=" — POSSIBLY TRUNCATED: missing the mandated 'Probes run:' section"
    {
      echo ""
      echo "byre-codereview: WARNING — the review lacks its mandated 'Probes run:' section,"
      echo "  so the run may have died mid-review. Treat the findings — and especially the"
      echo "  APPARENT ABSENCE of findings — accordingly."
    } >&2
  # Raw runs have no marker to miss, which left them the ONE mode where a
  # recorded non-review carried no warning at all — the gate lets an
  # auth-on-stdout death through by design, and the net above never fired to
  # say so. This is the net for that mode: it WARNS, never discards, so the
  # loose read of a caller's arbitrary output cannot cost them a real answer.
  elif [ "$RAW" = true ] && opens_like_auth "$OUT"; then
    note=" — POSSIBLY NOT A REVIEW: opens with something shaped like an auth diagnostic"
    {
      echo ""
      echo "byre-codereview: WARNING — this raw run's output opens like an authentication"
      echo "  diagnostic rather than an answer. Recorded anyway (raw output is yours to"
      echo "  judge), but check the reviewer is still logged in before trusting it."
    } >&2
  fi
  raw_tag=""
  [ "$RAW" = true ] && raw_tag=", raw"
  { printf '\n## %s (%s%s)%s\n\n' "$(date -u +%FT%TZ)" "$REVIEWER" "$raw_tag" "$note"; cat "$OUT"; } >> "$LOG_FILE"
}

extract_codex_session() {
  # zai emits the same events (same CLI, different CODEX_HOME/provider), so
  # this serves both harnesses.
  grep -m1 '"type":"thread.started"' "$DBG" 2>/dev/null \
    | jq -r '.thread_id' 2>/dev/null || true
}

# The codex FAMILY engine: codex and zai are the same CLI surface, so both
# harnesses ride these functions and differ only in the command ($HARNESS),
# the session file, and the failure reporter. The one thing this must NEVER do
# is substitute one for the other — "codex" means OpenAI-login codex, "zai"
# means the Z.AI home, and reviews.md names whichever you picked.
run_fresh_codex_family() {
  # Starting fresh: drop any prior session up front, so an interrupted run can't
  # leave a stale session that a later --continue would wrongly resume.
  rm -f "$SESSION_FILE"
  announce_fresh
  # --sandbox danger-full-access: the BOX is the wall, not codex's own sandbox.
  # Codex sandboxes Linux commands with bundled bwrap, which must create a user
  # namespace — and container runtimes routinely deny that (docker-default
  # seccomp blocks unprivileged namespace clones; Ubuntu 23.10+ AppArmor piles
  # on). Under --sandbox read-only every probe then dies BEFORE execution and
  # the review returns "no findings" with zero coverage — which reads as a
  # clean bill, worse than no review (verified in-box 2026-07-19, codex
  # 0.144.6, Ubuntu 24.04 host). zai runs the same binary and so inherits the
  # same posture: honest enforcement ordering, where the box boundary and the
  # tree tripwire actually hold; read-only is asked of the reviewer by the
  # prompt, not the OS. Cost stated plainly: a prompt-injection in the code
  # under review can now act through writes — same accepted exposure as grok,
  # and what the tripwire exists to catch.
  # --skip-git-repo-check: codex refuses non-git dirs by default, but half of
  # what byre boxes isn't a repo, and the BOX is the trust boundary here — the
  # check duplicates an enclosure byre already provides (footgun doctrine).
  # -m: the harness:model form's model (codex-cli 0.159.3 `exec` takes
  # -m/--model, verified 2026-10-01); absent, codex's configured default.
  if run_reviewer_cmd "$HARNESS" exec --skip-git-repo-check --json --sandbox danger-full-access \
       ${MODEL:+-m "$MODEL"} "$PROMPT" \
       --output-last-message "$OUT" < /dev/null > "$DBG" 2>&1; then
    # Same empty-output guard as grok and claude: exit 0 with nothing extracted
    # would otherwise print nothing, record nothing, and exit 0 — a silent
    # non-review indistinguishable from success. codex has not been seen doing
    # this; the check costs a line and removes an asymmetry with no reason.
    # --raw sends the caller's prompt verbatim, and a caller may legitimately
    # want no final text, so the guard applies only to built-in reviews, which
    # must return a report.
    if [ "$RAW" != true ] && [ ! -s "$OUT" ]; then
      echo "byre-codereview: $HARNESS exited 0 but produced no final message." >&2
      "report_failure_$HARNESS"
      rm -f "$OUT" "$SESSION_FILE"; exit 1
    fi
    sid=$(extract_codex_session)
    [ -n "$sid" ] && [ "$sid" != "null" ] && save_session "$sid" || rm -f "$SESSION_FILE"
    cat "$OUT"; record_review; cleanup
  else
    # $? here is the if-condition's status — the reviewer's (or timeout's).
    exit_if_timed_out "$?" fresh
    "report_failure_$HARNESS"
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
}

run_fresh_codex() { run_fresh_codex_family; }
run_fresh_zai()   { run_fresh_codex_family; }

# report_failure_codex inspects the debug log and prints an actionable message.
# The common, opaque failure is an expired/invalidated codex credential: codex
# 401s ("token_expired" / "refresh token ... already used" / "sign in again")
# and the only signal would otherwise be a raw temp log. Codex auth is a
# rotating token, so this WILL recur — name the fix instead of making the next
# person cat a log.
report_failure_codex() {
  # Same scoped classifier as zai (codex_family_error_events, defined below):
  # the raw JSONL stream embeds reviewer command output, and a review that
  # quotes "token_expired" — any review of auth code — must not turn an
  # unrelated failure into re-login advice.
  local errs; errs=$(codex_family_error_events)
  # A pinned model the account can't run, checked BEFORE auth so a model
  # rejection is never sent to re-login. Verified live 2026-10-01 (codex-cli
  # 0.159.3, ChatGPT login): every gpt-5*-codex name and plain gpt-5 come back
  # as {"type":"error","status":400,"error":{"type":"invalid_request_error",
  # "message":"The 'gpt-5' model is not supported when using Codex with a
  # ChatGPT account."}} — an error event, so in the owned channel above. The
  # "not found" arm takes a single-token model name on purpose: codex also
  # emits "Model metadata for `<m>` not found. Defaulting to fallback ..." as
  # an item.completed warning, outside the owned channel today, and a broader
  # pattern would turn that harmless warning into model advice if it ever
  # moved into one.
  if printf '%s' "$errs" | grep -qiE 'model is not supported|model [^[:space:]]+ not found|unknown model|invalid model'; then
    echo "byre-codereview: codex rejected the model${MODEL:+ '$MODEL'} — this account can't run it." >&2
    echo "  Pass one it can: --reviewer codex:<model> (codex has no model-list command;" >&2
    echo "  the slugs this login can use are in \$CODEX_HOME/models_cache.json, by default" >&2
    echo "  ~/.codex/models_cache.json), or run bare '--reviewer codex' for its default." >&2
    echo "  Debug log: $DBG" >&2
  elif printf '%s' "$errs" | grep -qiE 'token_expired|refresh token|sign in again|authentication token is expired|401 unauthorized'; then
    echo "byre-codereview: codex authentication failed — the login expired or was invalidated." >&2
    echo "  Re-authenticate in another terminal: run 'byre shell', then:" >&2
    echo "      codex-login                  # this package's wrapper, or:" >&2
    echo "      codex login --device-auth    # the same thing, always available" >&2
    echo "  (Plain 'codex login' opens a browser flow the box can't complete.)" >&2
    if command -v zai >/dev/null 2>&1; then
      echo "  This box also carries zai, and if its agent is zai you may have skipped" >&2
      echo "  this login deliberately. 'byre-codereview --reviewer zai' then works on" >&2
      echo "  ZAI_API_KEY alone — but zai is GLM: in a zai-authored box that is a" >&2
      echo "  same-family second pass, not an independent opinion. Complete" >&2
      echo "  codex-login (or use grok/claude/opencode) when independence matters." >&2
    fi
    echo "  Debug log: $DBG" >&2
  else
    echo "byre-codereview: review failed. Debug log: $DBG" >&2
  fi
}

# zai failure advice. Known shape (observed in-box, Z.AI Responses): an expired
# or incorrect key returns {"code":401,"msg":"token expired or incorrect"}, which
# Codex surfaces misleadingly as five missing-response.completed reconnects and
# then "stream closed before response.completed". Name it, and name the fix —
# there is NO zai login command to run: the key is environmental.
#
# codex_family_error_events is the scoped classifier for BOTH codex-family
# reporters (same CLI, same event schema). It reads CLI/provider-owned TEXT
# channels, never the whole debug
# log: error/turn.failed fields, error-shaped msg objects, and standalone
# provider body lines (which carry no top-level type). Codex's
# --json stream embeds reviewer command output (item.completed events carry git
# diffs and file reads), and this very script contains every auth word below.
# Grepping all of $DBG would diagnose an expired key — and recommend rotating
# the machine-wide shared key — after any unrelated failure in a review that
# happened to quote "401" or "api key" (found by the first zai review of this
# very wiring, 2026-08-16). A missed match here costs a vaguer message; a false
# match costs a credential rotation across every opted-in project. turn.failed
# is Codex's terminal failure event, carrying error.message per 0.147's
# exec_events.rs, and is where the Z.AI stream-closed shape arrives; the
# standalone body {"code":401,"msg":"token expired or incorrect"} has no
# top-level type, hence the string-msg channel. Every branch COERCES to a
# string before join: join on an object aborts jq (exit 5, empty output),
# which would silently drop a diagnosis the same log supported.
# NOTE: keep prose comments OUT of the jq program: it rides a single-quoted
# shell string, and an apostrophe inside a comment would end that string.
codex_family_error_events() {
  jq -rRs '
    [ split("\n")[] | fromjson? ]
    | [ .[]
        | ( ( if .type == "turn.failed" then (.error.message // "")
              else (.message // .error.message // "") end )
            | if type == "string" then . else "" end ) as $owned
        | ( if (.msg | type) == "string" then .msg
            elif (.msg | type) == "object" and .msg.type? == "error"
            then (.msg.message // .msg.content // "")
            else "" end
          | if type == "string" then . else "" end ) as $msg
        | select($owned != "" or $msg != "")
        | [$owned, $msg] | join("\n") ]
    | join("\n")
  ' "$DBG" 2>/dev/null || true
}

# Quota exhaustion is checked FIRST: it surfaces in the same reconnect-then-
# stream-closed shape as the 401, and sending it to the key advice below costs
# a needless machine-wide key rotation. Observed 2026-10-02 (codex-family
# --json, Z.AI): five {"type":"error","message":"Reconnecting... 5/5 (rate
# limit exceeded: Weekly/Monthly Limit Exhausted. Your limit will reset at
# 2026-10-06 19:54:40 ...)"} events, then {"type":"turn.failed","error":
# {"message":"rate limit exceeded: ..."}} -- both in the owned channel
# codex_family_error_events reads, so a review quoting these words cannot
# trip it. The reset time is passed on as Z.AI states it (no zone added).
# `grep >/dev/null`, not -q, and `sed -n 1p`, not head: the SIGPIPE-under-
# pipefail hole report_failure_mimo documents.
report_failure_zai() {
  local errs reset; errs=$(codex_family_error_events)
  if printf '%s' "$errs" | grep -iE 'rate limit exceeded|limit exhausted' >/dev/null; then
    reset=$(printf '%s' "$errs" \
      | grep -oiE 'reset at [0-9]{4}-[0-9]{2}-[0-9]{2}([ T][0-9]{2}:[0-9]{2}(:[0-9]{2})?)?' \
      | sed -n '1s/^[^0-9]*//p' || true)
    echo "byre-codereview: Z.AI refused the request: the plan's quota is exhausted (not a key" >&2
    if [ -n "$reset" ]; then
      echo "  problem); it resets at $reset. Do not rotate the key; wait for the reset" >&2
    else
      echo "  problem); the log gives no reset time. Do not rotate the key; wait for the reset" >&2
    fi
    echo "  or use another reviewer (codex, grok, mimo, vibe)." >&2
    echo "  Debug log: $DBG" >&2
  elif printf '%s' "$errs" | grep -qiE '"code"[[:space:]]*:[[:space:]]*401|token expired or incorrect|stream closed before response\.completed|unauthorized|invalid api key|api key|401'; then
    echo "byre-codereview: Z.AI may have rejected the request — an expired or" >&2
    echo "  incorrect ZAI_API_KEY is the common cause. The reconnect-then-stream-" >&2
    echo "  closed shape is how that 401 usually surfaces in Codex; a plain network" >&2
    echo "  fault can look similar, so the debug log below is the tiebreaker. A" >&2
    echo "  project-sourced ZAI_API_KEY wins, so replace that at its source. With" >&2
    echo "  zai-shared-auth, rotate the machine key: run 'byre shell', then:" >&2
    echo "      rm ~/.byre-identity/zai/api-key" >&2
    echo "  exit that shell IMMEDIATELY (it still exports the old key), and relaunch" >&2
    echo "  byre — the first-run prompt asks for the replacement." >&2
    echo "  Debug log: $DBG" >&2
  else
    echo "byre-codereview: review failed. Debug log: $DBG" >&2
  fi
}

run_resume_codex_family() {
  local sid="$1"
  warn_cross_reviewer_resume
  announce_resume
  # The resume subcommand rejects --sandbox ("unexpected argument", clap exit 2
  # — every resume then fell back to a fresh review, silently), but it takes -c
  # overrides, and sandbox_mode is the same knob by its config name (value
  # matches the fresh path's --sandbox; see the rationale there). It DOES
  # accept --output-last-message, so the fresh path's extraction works here too.
  # It also takes -m/--model (codex-cli 0.159.3, verified 2026-10-01), so a
  # resume runs the model the caller named, like every other harness's resume.
  if run_reviewer_cmd "$HARNESS" exec resume --skip-git-repo-check --json -c sandbox_mode="danger-full-access" \
       ${MODEL:+-m "$MODEL"} "$sid" "$PROMPT" --output-last-message "$OUT" < /dev/null > "$DBG" 2>&1; then
    # Unlike the other resumes, this one REWRITES the session file when the
    # event stream carries a thread id. It keeps the two-line shape and keeps
    # line 2 as the thread's STARTER, not the resumer — the cross-reviewer
    # note is about whose turns the thread holds. A one-line file stays one
    # line rather than guessing who started it.
    new=$(extract_codex_session)
    if [ -n "$new" ] && [ "$new" != "null" ]; then
      starter=$(session_starter)
      if [ -n "$starter" ]; then printf '%s\n%s\n' "$new" "$starter" > "$SESSION_FILE"
      else printf '%s\n' "$new" > "$SESSION_FILE"; fi
    fi
    # No extractable message: keep $DBG — cleanup would delete the very file
    # the notice points at (a raw --continue can legitimately end with no
    # final text, and an extraction failure needs the log even more).
    if [ -s "$OUT" ]; then cat "$OUT"; record_review; cleanup; else
      echo "(could not extract final message; raw kept at: $DBG)"; rm -f "$OUT"
    fi
  else
    exit_if_timed_out "$?" resume
    echo "Resume failed — falling back to a fresh review." >&2
    rm -f "$SESSION_FILE"; run_fresh_codex_family
  fi
}

run_resume_codex() { run_resume_codex_family "$@"; }
run_resume_zai()   { run_resume_codex_family "$@"; }

# Grok reviewer notes. Honest enforcement ordering: the box boundary and the
# tripwire are what actually hold; the tool strip is best-effort narrowing.
# - NO --sandbox: grok's Landlock profiles break tool execution inside a byre
#   box — every tool-using turn returns exit 0 with EMPTY output (verified
#   in-box 2026-07-09, grok 0.2.93 on a linuxkit kernel; nothing in the debug
#   log). Codex hit the same wall a different way (bwrap vs userns denial,
#   2026-07-19) and now also runs unsandboxed — see run_fresh_codex. Both
#   reviewers: box boundary + tripwire enforce; the prompt asks read-only.
# - --disallowed-tools strips the file-edit + todo tools (write_file and
#   apply_patch are speculative IDs — unknown names are accepted harmlessly,
#   verified). bash stays: the review needs git reads and cheap probes, so
#   free-form writes remain POSSIBLE — that's what the tripwire is for.
# - GROK_SUBAGENTS=0 closes the subagent bypass (a spawned task would get the
#   FULL toolset, edit tools included). It must be the env var: putting
#   "Agent" in the denylist breaks grok session construction outright
#   (0.2.93 run_terminal_cmd params bug, verified in-box).
# - --always-approve is REQUIRED for headless tool use: grok's default
#   permission mode prompts for any command off its safe fast-path list (git
#   reads, ls/cat/grep — NOT rg, bash, or --help probes), headless has no TTY
#   to prompt, and the turn silently DIES there — exit 0, preamble-only output
#   (reproduced in-box 2026-07-09, whose stub got recorded as a clean review).
#   --permission-mode dontAsk would fit byre's posture better; 0.2.93 does not
#   enforce it from the flag, so tighten to that when it does.
# - Because of that silent-empty shape, exit 0 is not trusted on its own:
#   grok_not_a_review decides, and mid-run deaths leaving a preamble are caught
#   by the "Probes run:" check in record_review.
GROK_TOOL_STRIP="search_replace,todo_write,write_file,apply_patch"

# DISCARD pattern. An auth diagnostic as a CLI emits one: starting a line, and
# ending it or running into punctuation. Both anchors matter — unanchored this
# matches ordinary findings ("Unauthorized access via IDOR"), and a review of
# this file quotes every string in the list.
#
# Deliberately biased toward missing: a missed diagnostic is recorded and
# flagged by record_review, a false match destroys a real review. So a run-on
# like "Please sign in to continue" is knowingly not matched.
#
# Scope, stated honestly: these are grok's shapes, and only grok's gate uses it.
# claude's real diagnostic is a compound line ("Not logged in · Please run
# /login") and codex's include "sign in again" and "refresh token" — none of
# which match this deliberately strict form. Their auth handling lives in their
# own report_failure_* functions; do not wire this into their gates.
AUTH_DIAG_LINE_RE='^[[:space:]]*(error:[[:space:]]*)?(you are[[:space:]]+)?(not signed in|not logged in|please log ?in|please sign in|token_expired|invalid api key|(http[[:space:]]+)?401[[:space:]]+unauthorized|unauthorized)([[:punct:]]|[[:space:]]*$)'

# ADVISORY pattern — warnings and failure advice, never a discard, so it is
# free to be loose and to cover all three CLIs' wordings.
#
# It is composed FROM the discard pattern rather than restating it, which makes
# it a superset BY CONSTRUCTION. Two hand-maintained lists drifted apart twice:
# first over "unauthorized", then over "please log in" — each time a run the
# gate had killed was told only that the review failed, instead of how to
# re-authenticate. A comment asserting the invariant did not hold it; this does.
AUTH_ADVICE_RE="$AUTH_DIAG_LINE_RE|token_expired|refresh token|not (logged|signed) in|sign ?in|log ?in|401|api key|unauthorized|authenticat"
auth_advice() { grep -qiE "$AUTH_ADVICE_RE" "$1" 2>/dev/null; }
# Auth text at the TOP of a stream — advisory, so it may read $OUT where the
# gate must not.
opens_like_auth() { head -n 5 "$1" 2>/dev/null | grep -qiE "$AUTH_ADVICE_RE"; }

# grok can exit 0 having never reviewed. Only CLI-owned signals may condemn a
# run: $OUT being empty, its FIRST line being grok's session-construction
# error, or an auth diagnostic on stderr. The body of $OUT is never a discard
# signal — it belongs to the model, which quotes diagnostics when reviewing
# this very file, and every attempt to classify it destroyed real reviews.
#
# Accepted residual: auth on stdout with silent stderr is recorded. It arrives
# without the mandated "Probes run:" section, so record_review flags it.
grok_not_a_review() {
  [ ! -s "$OUT" ] && return 0
  head -n1 "$OUT" 2>/dev/null | grep -q "^Couldn.t create session" && return 0
  grep -qiE "$AUTH_DIAG_LINE_RE" "$DBG" 2>/dev/null
}

run_fresh_grok() {
  rm -f "$SESSION_FILE"
  announce_fresh
  # -s pre-assigns the session UUID (grok creates it), so --continue can
  # --resume it later without parsing any output. -m: the harness:model form's
  # model (grok 1.0.46 takes -m/--model, verified 2026-10-01).
  local sid; sid=$(cat /proc/sys/kernel/random/uuid)
  if run_reviewer_cmd env GROK_SUBAGENTS=0 grok -p "$PROMPT" -s "$sid" ${MODEL:+-m "$MODEL"} \
       --always-approve --disallowed-tools "$GROK_TOOL_STRIP" \
       < /dev/null > "$OUT" 2> "$DBG"; then
    # grok can exit 0 having never reviewed: empty output, a startup death, or
    # an auth failure. Each condition here reads a CLI-owned signal only —
    # $OUT's emptiness and its FIRST line, and $DBG. Nothing inspects the
    # body of the report, which is what five earlier versions kept doing and
    # kept destroying real reviews over.
    if grok_not_a_review; then
      echo "byre-codereview: grok failed before reviewing (exit 0 with empty output, or a startup/auth error):" >&2
      cat "$OUT" >&2
      # Run the same detector as the non-zero path rather than printing a bare
      # log path and leaving the reader to guess. It prints the debug log
      # either way, so this replaces that line rather than adding to it.
      report_failure_grok
      rm -f "$OUT" "$SESSION_FILE"; exit 1
    fi
    save_session "$sid"
    cat "$OUT"; record_review; cleanup
  else
    exit_if_timed_out "$?" fresh
    # Surface whatever partial output exists — same courtesy as the startup
    # path; failure details otherwise vanish with the temp file.
    [ -s "$OUT" ] && cat "$OUT" >&2
    report_failure_grok
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
}

run_resume_grok() {
  local sid="$1"
  warn_cross_reviewer_resume
  announce_resume
  if run_reviewer_cmd env GROK_SUBAGENTS=0 grok -p "$PROMPT" --resume "$sid" ${MODEL:+-m "$MODEL"} \
       --always-approve --disallowed-tools "$GROK_TOOL_STRIP" \
       < /dev/null > "$OUT" 2> "$DBG" && ! grok_not_a_review; then
    cat "$OUT"; record_review; cleanup
  else
    # $? is grok's status when grok failed, or 1 from `! grok_not_a_review` —
    # which can't be mistaken for a timeout.
    exit_if_timed_out "$?" resume
    # Same partial-output courtesy as the fresh path before the fallback eats it.
    [ -s "$OUT" ] && cat "$OUT" >&2
    echo "Resume failed — falling back to a fresh review." >&2
    rm -f "$SESSION_FILE"; run_fresh_grok
  fi
}

# Claude reviewer notes (all claims verified in-box 2026-07-10).
# - INDEPENDENCE CAVEAT: when claude is also the box's authoring agent, this is
#   a second PASS by the same model family, not a second opinion. Prefer codex
#   or grok when they're available; claude earns its keep as the reviewer in a
#   box where it's the only CLI, or as a differently-prompted extra pass.
# - Enforcement, same honest ordering as grok: the box boundary and the
#   tripwire are what actually hold; the tool strip is best-effort narrowing.
#   --disallowedTools strips the file-edit tools plus Task (a spawned subagent
#   would get the full toolset — the same bypass grok closes via
#   GROK_SUBAGENTS=0). --allowedTools Bash keeps git reads and cheap probes
#   working (headless runs auto-DENY any tool that would prompt — a deny, not
#   grok's silent death), so free-form writes remain POSSIBLE — that's what
#   the tripwire is for. No codex-style OS sandbox is applied.
# - --safe-mode keeps the REVIEWED repo's claude customizations (settings,
#   hooks, plugins, MCP servers, CLAUDE.md) from loading: without it a
#   malicious repo's hooks would execute at reviewer startup — code running
#   BEFORE the prompt or denylist gets a say. The review prompt is
#   self-contained, so the reviewer loses nothing it needs.
# - The PROMPT rides stdin: --allowedTools/--disallowedTools are variadic and
#   swallow a trailing prompt argument (each prompt word became a bogus
#   permission rule when passed after them). For the same reason --model (the
#   harness:model form's model — an alias like opus/sonnet or a full id;
#   claude 2.1.286, verified 2026-10-01) goes BEFORE them.
# - Sessions: --session-id pre-assigns the UUID, like grok's -s; --resume works
#   headless, repeatedly, against the SAME id. A run that dies early can still
#   consume its pre-assigned id ("already in use"), which is one more reason
#   every fresh run mints a new one.
CLAUDE_TOOL_STRIP="Edit,Write,NotebookEdit,TodoWrite,Task"

run_fresh_claude() {
  rm -f "$SESSION_FILE"
  announce_fresh
  local sid; sid=$(cat /proc/sys/kernel/random/uuid)
  if printf '%s' "$PROMPT" | run_reviewer_cmd claude -p --safe-mode --session-id "$sid" \
       ${MODEL:+--model "$MODEL"} \
       --allowedTools "Bash" --disallowedTools "$CLAUDE_TOOL_STRIP" \
       > "$OUT" 2> "$DBG"; then
    # Exit 0 with nothing to say has no legitimate reading — never record it
    # as a clean review (grok's lesson, applied preemptively).
    if [ ! -s "$OUT" ]; then
      echo "byre-codereview: claude produced no output despite exit 0." >&2
      echo "  Debug log: $DBG" >&2
      rm -f "$OUT" "$SESSION_FILE"; exit 1
    fi
    save_session "$sid"
    cat "$OUT"; record_review; cleanup
  else
    exit_if_timed_out "$?" fresh
    # Surface whatever partial output exists — claude prints some failures
    # (e.g. "Not logged in") to STDOUT, and they'd otherwise vanish with the
    # temp file.
    [ -s "$OUT" ] && cat "$OUT" >&2
    report_failure_claude
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
}

run_resume_claude() {
  local sid="$1"
  warn_cross_reviewer_resume
  announce_resume
  if printf '%s' "$PROMPT" | run_reviewer_cmd claude -p --safe-mode --resume "$sid" \
       ${MODEL:+--model "$MODEL"} \
       --allowedTools "Bash" --disallowedTools "$CLAUDE_TOOL_STRIP" \
       > "$OUT" 2> "$DBG" && [ -s "$OUT" ]; then
    cat "$OUT"; record_review; cleanup
  else
    exit_if_timed_out "$?" resume
    # Same partial-output courtesy as the fresh path before the fallback eats it.
    [ -s "$OUT" ] && cat "$OUT" >&2
    echo "Resume failed — falling back to a fresh review." >&2
    rm -f "$SESSION_FILE"; run_fresh_claude
  fi
}

# "Not logged in · Please run /login" arrives on STDOUT with exit 1 (verified),
# so the auth grep covers $OUT as well as the debug log. Tight patterns only,
# same rationale as grok's. No model-rejection branch yet (codex and grok have
# one): claude's wording for a bad --model is unverified — not logged in here.
report_failure_claude() {
  if grep -qiE 'not logged in|please run /login|oauth token.*(expired|revoked)|invalid api key|401' "$OUT" "$DBG" 2>/dev/null; then
    echo "byre-codereview: claude authentication failed." >&2
    echo "  Log in once in the box (run 'claude', then /login). If this box rides a" >&2
    echo "  shared token (claude-shared-auth), see that skill's notes instead." >&2
    echo "  Debug log: $DBG" >&2
  else
    echo "byre-codereview: review failed. Debug log: $DBG" >&2
  fi
}

# opencode reviewer notes (all claims verified in-box 2026-08-07, opencode
# 1.18.15, against the source in the box).
# - INDEPENDENCE CAVEAT, sharper than claude's: opencode is a meta-CLI — the
#   model it runs is whatever the box's opencode config defaults to, which can
#   be the same family as the authoring agent. The reviewer name tells you
#   nothing about the model; check the box's opencode config if independence
#   matters.
# - Enforcement, honest ordering as ever: the box boundary and the tripwire
#   are what actually hold; the rest is best-effort narrowing — and opencode's
#   narrowing is the strongest of the four:
#     --agent plan            file edits DENIED by permission (write/edit/patch
#                             all gate on the "edit" permission), and the
#                             edit-capable "general" subagent denied with them.
#                             bash stays for git reads and cheap probes — free-
#                             form writes remain POSSIBLE; that's the tripwire's
#                             job.
#     OPENCODE_PERMISSION     merged into config AFTER every config file, so
#                             its edit/todowrite deny holds even against a
#                             repo or global config that re-allows them.
#     OPENCODE_DISABLE_PROJECT_CONFIG=1
#                             the --safe-mode analog: the REVIEWED repo's
#                             .opencode/opencode.json (plugins, MCP servers,
#                             permission overrides — code that would run at
#                             reviewer startup) never loads. Global config and
#                             auth still do. NOT --pure: that strips the box
#                             owner's own plugins, which can carry the auth
#                             provider the reviewer rides on.
#     OPENCODE_DISABLE_AUTOUPDATE=1
#                             a review run must not rewrite the reviewer binary.
# - Headless permission model: any "ask" is auto-REJECTED (a deny the model
#   sees and works around — not grok's silent death). The plan agent leaves
#   bash on the allow path, so probes run without asking; external-directory
#   asks reject, confining the reviewer to the repo.
# - The PROMPT rides stdin: `run` re-quotes argv words containing spaces and
#   escapes their inner quotes (run.ts builds the message back out of shell
#   words), which mangles a prompt passed as one big argument. Piped stdin is
#   passed through verbatim.
# - --format json: all UI chrome goes to stderr; stdout is clean JSONL, every
#   event stamped with the run's sessionID. Failures (provider 4xx, "Session
#   not found") arrive as "error" events on STDOUT with exit 1, so the debug
#   log below is stdout(events)+stderr appended.
# - No session pre-assignment (--session must name an EXISTING session), so
#   unlike the others the id is extracted from the event stream after the run.
#   Ids are ses_ + 12 hex + 14 base62 chars — case-SENSITIVE, which is why the
#   dispatch at the bottom must not lowercase them.
# - A logged-out opencode does not necessarily fail: it ships free zero-auth
#   models. The failure modes that DO occur are a provider auth error and a
#   default model that can't do tool use (both land as error events);
#   report_failure_opencode names the fix for each.
OPENCODE_REVIEW_PERMS='{"edit":"deny","todowrite":"deny"}'

# The opencode FAMILY extractors: opencode and mimo share them. mimo (Xiaomi's
# MiMo Code) is an opencode fork whose `run --format json` emits the same
# stream — {type,timestamp,sessionID,...} per line (mimo 0.1.15 run.ts:439
# emit), "text" events carrying {part:{id,messageID,text}} once a text part
# finishes (run.ts:517), "error" events carrying {error:{name,data:{message,
# statusCode}}} (run.ts:552) — verified in source and against live mimo
# output 2026-10-01. A divergence in either CLI's stream belongs here, once.
#
# Final report = the text parts of the LAST assistant message, joined. Joining
# (rather than taking only the last part) keeps a report the model split
# across parts; unique_by drops any re-emitted part update and sorts by part
# id, which is chronological (ascending ids). fromjson? skips the appended
# stderr lines. Three cases yield NO output, not "", because jq -r prints ""
# as a newline: a 1-byte $OUT that passes every [ -s "$OUT" ] guard, so
# before this fix opencode's "exited 0 but produced no final message" check
# could never fire. No text events at all. Text that is empty or
# whitespace-only: --format json emits the "text" event BEFORE the CLI's own
# blank check (mimo run.ts:517-519, opencode's twin), so the final select
# drops a joined report with no non-whitespace character. A non-string text
# (object/array): coerced to "", since join would abort jq and, via the
# `|| true`, blank the whole report, good parts of the same message included
# (found by a mimo review, 2026-10-01).
extract_ocfamily_report() {
  jq -rRs '
    [ split("\n")[] | fromjson? | select(type=="object" and .type=="text") ]
    | unique_by(.part.id)
    | if length==0 then empty else
        (.[-1].part.messageID) as $m
        | [ .[] | select(.part.messageID==$m) | (.part.text | if type=="string" then . else "" end) ] | join("\n\n")
        | select(test("\\S"))
      end' "$DBG" 2>/dev/null || true
}

# objects only: a stderr line that happens to parse as a JSON scalar (a bare
# number) would otherwise make .sessionID abort the whole jq program.
extract_ocfamily_session() {
  jq -rRs '[ split("\n")[] | fromjson? | objects | .sessionID // empty ] | first // empty' "$DBG" 2>/dev/null || true
}

# Runs opencode and normalizes its two streams into the usual shape: $DBG =
# JSONL events then stderr, $OUT = extracted final report. Shared by fresh and
# resume, which differ only in the session flag. Returns opencode's exit code.
run_opencode() {
  local err rc=0
  err=$(mktemp "$REVIEW_DIR/.err.XXXXXX")
  # ${MODEL:+...} adds --model only when the harness:model form supplied one;
  # otherwise the box's opencode config picks, as before.
  printf '%s' "$PROMPT" | run_reviewer_cmd env OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_AUTOUPDATE=1 \
      OPENCODE_PERMISSION="$OPENCODE_REVIEW_PERMS" \
      opencode run --format json --agent plan --title "byre-codereview" \
      ${MODEL:+--model "$MODEL"} "$@" \
      > "$DBG" 2> "$err" || rc=$?
  cat "$err" >> "$DBG" 2>/dev/null; rm -f "$err"
  extract_ocfamily_report > "$OUT"
  return "$rc"
}

run_fresh_opencode() {
  rm -f "$SESSION_FILE"
  announce_fresh
  if run_opencode; then
    # Same empty-output guard as the others: exit 0 with no final message must
    # not read as a clean review. Raw callers may legitimately want no final
    # text, so the guard applies only to built-in reviews (codex's rationale).
    if [ "$RAW" != true ] && [ ! -s "$OUT" ]; then
      echo "byre-codereview: opencode exited 0 but produced no final message." >&2
      echo "  Debug log: $DBG" >&2
      rm -f "$OUT" "$SESSION_FILE"; exit 1
    fi
    sid=$(extract_ocfamily_session)
    [ -n "$sid" ] && save_session "$sid" || rm -f "$SESSION_FILE"
    cat "$OUT"; record_review; cleanup
  else
    exit_if_timed_out "$?" fresh
    # Partial-output courtesy, as everywhere: a report extracted from a failed
    # run still beats a bare log path.
    [ -s "$OUT" ] && cat "$OUT" >&2
    report_failure_opencode
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
}

run_resume_opencode() {
  local sid="$1"
  warn_cross_reviewer_resume
  announce_resume
  if run_opencode --session "$sid"; then
    # Same no-message handling as the codex resume: keep $DBG, since the
    # notice points at it and cleanup would delete it.
    if [ -s "$OUT" ]; then cat "$OUT"; record_review; cleanup; else
      echo "(could not extract final message; raw kept at: $DBG)"; rm -f "$OUT"
    fi
  else
    exit_if_timed_out "$?" resume
    [ -s "$OUT" ] && cat "$OUT" >&2
    echo "Resume failed — falling back to a fresh review." >&2
    rm -f "$SESSION_FILE"; run_fresh_opencode
  fi
}

# Advice-only, so loose patterns are fine (grok's report_failure rationale).
# First surface the machine-readable error events — in --format json the actual
# failure text lands on stdout as an error event, not on stderr — then name the
# fix for the two failure shapes seen in-box.
report_failure_opencode() {
  jq -rRs '[ split("\n")[] | fromjson? | select(.type=="error")
             | (.error.data.message // .error.name) // empty ] | unique | join("\n")' \
    "$DBG" 2>/dev/null | sed 's/^/  /' >&2 || true
  if grep -qiE '401|unauthorized|invalid api key|authenticat' "$DBG" 2>/dev/null; then
    echo "byre-codereview: opencode's provider rejected the request — its login/key may have expired." >&2
    echo "  Re-authenticate in another terminal: run 'byre shell', then 'opencode auth login'" >&2
    echo "  (a terminal paste flow — no browser needed, so no wrapper script exists for it)." >&2
    echo "  Debug log: $DBG" >&2
  elif grep -qiE 'no endpoints found|model not found|does not support tool' "$DBG" 2>/dev/null; then
    echo "byre-codereview: opencode's model can't run the review (no tool support, or not found)." >&2
    echo "  Pass a tool-capable model: --reviewer opencode:<provider/model> ('opencode models'" >&2
    echo "  lists them), or set a default in the box's global opencode config" >&2
    echo "  (~/.config/opencode/opencode.json, e.g. {\"model\": \"openrouter/...\"})." >&2
    echo "  Debug log: $DBG" >&2
  else
    echo "byre-codereview: review failed. Debug log: $DBG" >&2
  fi
}

# mimo reviewer notes (MiMo Code, Xiaomi's opencode fork; claims verified
# 2026-10-01 against mimo 0.1.15, source and live binary, unless marked
# otherwise). It is opencode's runner with two load-bearing differences, the
# agent and the exit code; run_opencode's notes carry the shared rationale.
# - INDEPENDENCE: mimo defaults to Xiaomi's MiMo models, a genuinely different
#   family from claude/codex/grok/zai. But it is a meta-CLI like opencode: -m
#   can point at any provider and its login can import Claude Code
#   credentials, so the name says nothing about the model unless pinned.
# - POSTURE, by mimo's own names: MIMOCODE_PERMISSION, deep-merged over every
#   config layer (config.ts:979), with opencode's edit/todowrite deny;
#   MIMOCODE_DISABLE_PROJECT_CONFIG=1 (config.ts:821: the repo's .mimocode
#   config/plugins never load); MIMOCODE_DISABLE_AUTOUPDATE=1 (flag.ts:98);
#   MIMOCODE_ENABLE_ANALYSIS=false (flag.ts:107: no metrics to
#   tracking.miui.com). NOT --pure, for opencode's reason.
# - AGENT: the review runs its own primary agent, byre-review, defined in a
#   MIMOCODE_CONFIG_CONTENT built by mimo_review_config (below) and exported
#   only into mimo's env, after the pre-flight dropped any inherited copy.
#   Not plan: its hardPermission re-allows edits to .mimocode/plans/*.md after
#   every user/config/session rule (agent/agent.ts:200, runtimePermission at
#   :89, last via findLast), and its reminder, which "supersedes any other
#   instructions", has the model write <worktree>/.mimocode/plans/<ts>-<slug>.md
#   (session/prompt.ts:1624-1660, session.ts:378). Verified live 2026-10-01:
#   told not to modify files, with edit denied for .mimocode/** in both
#   MIMOCODE_PERMISSION and the plan agent's config, it wrote the file anyway.
#   Not build: its general coding persona reaches for scratch files outside
#   the repo, an external_directory ASK that headless `run` auto-rejects
#   (run.ts:556-573); the RejectedError BLOCKS the session loop
#   (session/processor.ts:439, ctx.shouldBreak from :861), so mimo ends the
#   turn, exit 0, no report. Live A/B 2026-10-01, same planted bug: build 0/2
#   usable, byre-review 4/4. byre-review, from source:
#   - a cfg.agent entry with no built-in of its name gets merge(defaults,
#     user), the user layer carrying MIMOCODE_PERMISSION, then its own
#     `permission` (agent/agent.ts:429-459); last match wins
#     (permission/evaluate.ts:11), so its rules beat the belt and the belt
#     covers what they leave unsaid. No hardPermission, no plan reminder.
#   - `run --agent` finds config agents via Agent.get (run.ts:628); mode must
#     not be "subagent" (run.ts:637), hence "primary". An unknown name only
#     prints `! agent "<name>" not found. Falling back to default agent` and
#     reviews under build, so mimo_error_event fails that line (verified live
#     2026-10-01 by misspelling it).
#   - `prompt` REPLACES the built-in base prompt (session/system.ts:54, first
#     in session/llm.ts:320-328; environment, instructions and skills still
#     follow), so the persona below is the whole identity.
#   - external_directory {"*":"deny"} makes the out-of-tree ask a rule deny:
#     a DeniedError (permission/index.ts:262), returned to the model as the
#     tool's error text, not a loop breaker. mimo re-allows its truncation and
#     skill dirs after config (agent.ts:462). bash_delete deny does the same
#     for the forced-ask `rm` confirmation.
#   - experimental.continue_loop_on_deny=true (config.ts:395, read only at
#     processor.ts:861/1040) is the general belt: any OTHER auto-rejected ask
#     (a .env read, doom_loop) reaches the model instead of ending the review.
#   - memory.disable_write=true: memory writes skip both the edit ask and
#     external_directory (tool/external-directory.ts:38,155) and land in
#     mimo's data dir for a later review to find; this stops them and the
#     memory injection (config.ts:339-343, memory/write-gate.ts).
#   The persona is not enforcement: 2 of the 4 A/B runs still wrote probe
#   inputs to /tmp by redirection, which mimo's bash scan (path arguments
#   only, tool/bash.ts:73,627) does not see. Harmless outside the tree.
#   bash stays, as for every harness, so free-form writes remain possible,
#   which is the tripwire's job; `run` denies question and plan_exit itself
#   (run.ts:368). No `steps` cap: the schema has one (config/agent.ts:56) but
#   it forces a text-only answer mid-investigation; --timeout bounds a run.
# - MIMOCODE_EXPERIMENTAL_CRON=false: the scheduler is on by default
#   (flag.ts:394) and at a session's first prompt writes .mimocode/.cron-lock
#   and a self-ignoring .gitignore into the cwd (cron/cron-lock.ts:18,207;
#   session/prompt.ts:4710). This flag keeps the bridge from starting
#   (cron-bridge.ts:130); MIMOCODE_DISABLE_CRON does not, as the lock comes
#   before any tick (verified live 2026-10-01). The other .gitignore writer
#   (config.ts:856) needs project config (config/paths.ts:30), which is off.
# - The prompt rides stdin and --session <id> resumes (both verified live);
#   session ids are opencode's shape (id.ts:88).
# - EXIT 0 IS NOT SUCCESS. Provider failures arrive as an "error" event on
#   stdout with exit 0 (verified live: a 401 "Invalid API Key" and a 402
#   "Insufficient account balance"), where opencode exits 1. With no
#   credential the dead free channel prints "error: MiMo free API service has
#   ended. ..." to stderr only (Provider.getLanguage, in the shipped binary,
#   not the published source), exit 0 (verified live). So mimo_error_event
#   decides, and a built-in review must also have extracted a report.
# - Token Plan (tp-) keys 401 on the default `xiaomi` provider and work only
#   on their region's xiaomi-token-plan-* (verified live 2026-10-01). The
#   pre-flight comment owns how a bare `--reviewer mimo` routes them.
MIMO_REVIEW_PERMS='{"edit":"deny","todowrite":"deny"}'
MIMO_REVIEW_AGENT=byre-review
MIMO_REVIEW_PERSONA='You are a read-only code reviewer. You review; the author fixes.

You have NO ability to create, modify or delete files anywhere: not in the repository, not in /tmp or any scratch location, not in your own config or memory directories. Every write tool is disabled, paths outside the repository are denied, and attempts only waste your turn. Never try to write a file, scratch note, plan or patch, by any tool or by shell redirection.

Do all of your analysis in your reply. You may run read-only commands through bash: git status/diff/log/show, reading or grepping files, --help output, and small one-line probes whose output you read directly. Keep all intermediate notes in your own reasoning, never on disk.

When a tool call is refused, do not retry it or work around it: continue the review with what you have.

Finish with your full report as your final message, ending with a "Probes run:" section listing every command you ran beyond the basic git reads ("none" if none).'

# The MIMOCODE_CONFIG_CONTENT for the review (see the notes above for every
# key). Built with jq so the persona needs no hand-escaping. No model here:
# the model rides --model (an explicit pin or byre-mimo-model's answer), so
# a review the resolver has no opinion on keeps mimo's own default.
mimo_review_config() {
  jq -cn --arg agent "$MIMO_REVIEW_AGENT" --arg prompt "$MIMO_REVIEW_PERSONA" '{
    experimental: { continue_loop_on_deny: true },
    memory: { disable_write: true },
    agent: { ($agent): {
      mode: "primary",
      description: "byre-codereview read-only reviewer",
      prompt: $prompt,
      permission: { edit: "deny", todowrite: "deny", bash_delete: "deny",
                    external_directory: { "*": "deny" } } } } }'
}

# The mimo twin of run_opencode — same normalized shape ($DBG = JSONL events
# then stderr, $OUT = extracted report), same return of the CLI's exit code,
# which for mimo is necessary-not-sufficient (see above). The resume path
# passes the same agent and config: --session continues the thread under
# whatever agent this run names.
run_mimo() {
  local err rc=0 cfg
  err=$(mktemp "$REVIEW_DIR/.err.XXXXXX")
  cfg=$(mimo_review_config)
  printf '%s' "$PROMPT" | run_reviewer_cmd env MIMOCODE_DISABLE_PROJECT_CONFIG=1 MIMOCODE_DISABLE_AUTOUPDATE=1 \
      MIMOCODE_ENABLE_ANALYSIS=false MIMOCODE_EXPERIMENTAL_CRON=false MIMOCODE_PERMISSION="$MIMO_REVIEW_PERMS" \
      MIMOCODE_CONFIG_CONTENT="$cfg" \
      mimo run --format json --agent "$MIMO_REVIEW_AGENT" --title "byre-codereview" \
      ${MODEL:+--model "$MODEL"} "$@" \
      > "$DBG" 2> "$err" || rc=$?
  cat "$err" >> "$DBG" 2>/dev/null; rm -f "$err"
  extract_ocfamily_report > "$OUT"
  return "$rc"
}

# CLI-owned failure text only: the error events' payloads (whole object, so
# statusCode rides along) and the non-JSON lines of $DBG, which are mimo's
# stderr. Never the rest of the stream — tool_use events embed reviewer command
# output, and a review of this very script quotes "402" and "Invalid API Key";
# grepping all of $DBG would turn any unrelated failure into credential advice
# (the zai lesson, see codex_family_error_events). A line FAILING to parse is
# what marks a stderr line — tested as an empty [fromjson?], not as a null
# result, since a stderr line that parses (a bare "false" or "null") is still
# not an event, and `fromjson? // null` would also have treated the JSON
# literals false/null as unparsed (found by a mimo review of 1.6.0,
# 2026-10-01). Such parseable-but-not-object lines are neither stderr text
# nor events: dropped.
mimo_failure_text() {
  jq -rRs '
    split("\n")[] | . as $l | [fromjson?] as $j
    | if ($j | length) == 0 then $l
      elif ($j[0] | type) == "object" and $j[0].type == "error" then ($j[0].error | tojson)
      else empty end' "$DBG" 2>/dev/null || true
}

# True when mimo reported a failure its exit code hid: an "error" event on
# stdout; an "error:" line on stderr (the dead free tier, which emits no
# event); or the agent-fallback line (`! agent "<name>" not found. Falling
# back to default agent`, or "is a subagent"; run.ts:628-645), after which
# mimo reviews under build, without byre-review's persona and denies, and
# exits 0 with a report. All three are CLI-owned: under --format json tool
# output never reaches mimo's own stderr (verified live 2026-10-01, mimo
# 0.1.15: a probe's "error: probe-marker" came back inside its tool_use
# event), so neither a probe nor a report quoting an error can trip this.
# The fallback line is ANSI-coloured, placement unverified, so strip_ansi runs
# first and the match is unanchored; case-insensitive here and in
# report_failure_mimo alike, so gate and advice agree. `grep >/dev/null`, not
# -q: under pipefail an early -q exit SIGPIPEs jq/sed, the pipeline returns
# 141, and `! mimo_error_event` reads that as "no error" (reproduced
# 2026-10-02: one fallback line + ~200 KB of filler).
mimo_error_event() {
  jq -eRs '[ split("\n")[] | fromjson? | select(type=="object" and .type=="error") ] | length > 0' \
    "$DBG" >/dev/null 2>&1 && return 0
  jq -rRs 'split("\n")[] | select([fromjson?] | length == 0)' "$DBG" 2>/dev/null \
    | strip_ansi | grep -iE "^error:|$MIMO_AGENT_FALLBACK_RE" >/dev/null
}

# SGR colour sequences (ESC [ params m) out of a text stream. \x1b in a sed
# regex is a GNU sed extension -- fine here, the box is Debian (GNU sed);
# POSIX sed would read it as a literal "x1b".
strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }
# mimo's agent-fallback line, shared by the gate and the advice (both -i).
MIMO_AGENT_FALLBACK_RE='agent "[^"]*" (not found|is a subagent)'

run_fresh_mimo() {
  rm -f "$SESSION_FILE"
  announce_fresh
  local rc=0; run_mimo || rc=$?
  exit_if_timed_out "$rc" fresh
  # Success needs all three: exit 0, no error event, and (for built-in
  # reviews) an extracted report. Raw callers may legitimately want no final
  # text (codex's rationale), so only they are spared the last condition.
  if [ "$rc" -eq 0 ] && ! mimo_error_event && { [ "$RAW" = true ] || [ -s "$OUT" ]; }; then
    sid=$(extract_ocfamily_session)
    [ -n "$sid" ] && save_session "$sid" || rm -f "$SESSION_FILE"
    cat "$OUT"; record_review; cleanup
  else
    [ "$rc" -eq 0 ] && echo "byre-codereview: mimo exited 0 but did not review (an error event, an error on stderr, or no final message)." >&2
    # Partial-output courtesy, as everywhere.
    [ -s "$OUT" ] && cat "$OUT" >&2
    report_failure_mimo
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
}

run_resume_mimo() {
  local sid="$1"
  warn_cross_reviewer_resume
  announce_resume
  local rc=0; run_mimo --session "$sid" || rc=$?
  exit_if_timed_out "$rc" resume
  if [ "$rc" -eq 0 ] && ! mimo_error_event && [ -s "$OUT" ]; then
    cat "$OUT"; record_review; cleanup
  elif [ "$rc" -eq 0 ] && ! mimo_error_event && [ "$RAW" = true ]; then
    # A raw --continue may end with no final text: keep $DBG, which the notice
    # points at (the codex/opencode resume handling).
    echo "(could not extract final message; raw kept at: $DBG)"; rm -f "$OUT"
  else
    # A built-in review with no report is a failure here too, not a notice:
    # exit-0 silence is mimo's failure shape, so it gets the fresh run (whose
    # own failure path then names the fix).
    [ -s "$OUT" ] && cat "$OUT" >&2
    echo "Resume failed — falling back to a fresh review." >&2
    rm -f "$SESSION_FILE"; run_fresh_mimo
  fi
}

# Advice-only, scoped to mimo_failure_text (CLI-owned text), not all of $DBG.
# Order: the agent fallback first (not a credential or model problem), then
# balance BEFORE auth, so a 402 is never sent to re-login, then auth, then
# model. Patterns match the live bodies (2026-10-01): {"name":"APIError",
# "data":{"message":"Insufficient account balance","statusCode":402,...}},
# {"message":"Invalid API Key: Please provide valid API Key","statusCode":401}
# and "error: MiMo free API service has ended. ..."; "Unsupported model <id>"
# is a verified 400, the other model shapes opencode's, assumed inherited.
# The 401 lead depends on $MODEL: with a pin (typed, or resolved by the
# pre-flight) the provider refused that pin; without one, the region could
# not be resolved. The Token Plan hint is appended either way: a tp- key on
# the wrong provider gives exactly the bad-key body (verified live
# 2026-10-01), and the script cannot see which kind of key the box holds.
# The box-wide fix is MIMO_MODEL, not "model" in mimocode.jsonc (image-layer
# in a byre box, reset on rebuild). No egress advice: pjlsergeant/mimo opens
# the three token-plan hosts itself.
report_failure_mimo() {
  # The CLI's own words first — error-event messages and stderr "error:"
  # lines — indented; nothing at all when there are none.
  local errs msgs; errs=$(mimo_failure_text)
  msgs=$({ jq -rRs '[ split("\n")[] | fromjson? | select(type=="object" and .type=="error")
                     | (.error.data.message // .error.name) // empty ] | unique | .[]' "$DBG" 2>/dev/null
           printf '%s\n' "$errs" | grep -iE '^error:'; } | sed '/^$/d' || true)
  [ -n "$msgs" ] && printf '%s\n' "$msgs" | sed 's/^/  /' >&2
  # grep >/dev/null, not -q, in every branch here: the same SIGPIPE-under-
  # pipefail hole as mimo_error_event (an early -q exit kills printf/sed with
  # 141, read as "no match"). Advisory only, but it keeps gate and advice
  # agreeing on the same $DBG.
  if printf '%s' "$errs" | strip_ansi | grep -iE "$MIMO_AGENT_FALLBACK_RE" >/dev/null; then
    # Not a credential or model problem, so none of the advice below fits.
    echo "byre-codereview: mimo did not load the '$MIMO_REVIEW_AGENT' review agent and fell back to its" >&2
    echo "  default agent, so the review was discarded. The agent is defined in the" >&2
    echo "  MIMOCODE_CONFIG_CONTENT this script passes; a mimo that rejects that config or" >&2
    echo "  changed its agent schema does this." >&2
  elif printf '%s' "$errs" | grep -iE 'insufficient account balance|insufficient_balance|"statusCode":402' >/dev/null; then
    echo "byre-codereview: mimo's provider refused for lack of funds (402) — the credential works," >&2
    echo "  but the Xiaomi MiMo platform account has no balance. This is NOT a login problem:" >&2
    echo "  fund the account at platform.xiaomimimo.com, or pin a model on another provider" >&2
    echo "  with --reviewer mimo:<provider/model> ('mimo models' lists them)." >&2
  elif printf '%s' "$errs" | grep -iE 'free api service has ended|invalid api key|"statusCode":401|unauthorized|authenticat' >/dev/null; then
    echo "byre-codereview: mimo has no usable MiMo credential (rejected key, or none — the free" >&2
    echo "  'MiMo Auto' tier has ended, so an unauthenticated mimo cannot review)." >&2
    echo "  Log in in another terminal: run 'byre shell', then 'mimo-login' (mimo skill 1.2.0+; else 'mimo auth login -p xiaomi')" >&2
    echo "  (a paste-code flow — no browser needed in the box). Or forward a platform key" >&2
    echo "  as XIAOMI_API_KEY in the box's environment." >&2
    # The Token Plan hint follows whatever the key kind (see the header); a
    # pinned $MODEL would make "could not be resolved" false, so lead with it.
    if [ -n "$MODEL" ]; then
      echo "  mimo's provider refused the pinned model '$MODEL' (401): a bad or expired key, or a" >&2
      echo "  Token Plan key (tp-...) from another region -- each works only on its own regional" >&2
      echo "  provider. Check the key ('byre-mimo-model --no-cache' re-detects the region), or set" >&2
    else
      echo "  A Token Plan key (tp-...) only works on its regional provider, and the region" >&2
      echo "  could not be resolved automatically ('byre-mimo-model --no-cache' says why): check" >&2
      echo "  the key, or set" >&2
    fi
    echo "  the box's MIMO_MODEL=xiaomi-token-plan-{cn,ams,sgp}/<model> (box-wide)," >&2
    echo "  or pin one run:" >&2
    echo "  --reviewer mimo:xiaomi-token-plan-<region>/<model> ('mimo models' lists them)." >&2
  elif printf '%s' "$errs" | grep -iE 'unsupported model|model not found|does not support tool|no endpoints found' >/dev/null; then
    echo "byre-codereview: mimo's model can't run the review (unsupported, not found, or no tool use)." >&2
    echo "  Pass one it can run: --reviewer mimo:<provider/model> ('mimo models' lists them)." >&2
  else
    echo "byre-codereview: review failed." >&2
  fi
  echo "  Debug log: $DBG" >&2
}

# vibe reviewer notes (Mistral Vibe; claims verified 2026-10-06 against vibe
# 2.26.0, the release bundle run against a fake OpenAI-compatible backend,
# and the source at github.com/mistralai/mistral-vibe, unless marked).
# - INDEPENDENCE: vibe runs Mistral's models (Mistral Medium 3.5 by default),
#   a different family from claude/codex/grok/GLM/MiMo. But the box's
#   ~/.vibe/config.toml can point any [[models]] alias at any OpenAI-
#   compatible endpoint, so the name says nothing about the model unless the
#   box's config is checked.
# - HARNESS: the bundle runs the closed-source "unified harness"
#   (mistralai_vibe_local_harness) by default, -p included
#   (vibe/_experimental_harness.py:122-136); --legacy-harness is upstream's
#   temporary escape hatch and is never passed. Everything below describes the
#   unified harness, as measured; the open source tree describes the legacy one.
# - POSTURE, honest ordering as ever: the box boundary and the tripwire are
#   what actually hold.
#     no --trust   the --safe-mode / OPENCODE_DISABLE_PROJECT_CONFIG analogue:
#                  an untrusted cwd loads none of the REVIEWED repo's .vibe/
#                  config, hooks, skills, agents or tools, nor its AGENTS.md
#                  (the prompt has the reviewer read that itself). vibe then
#                  prints "Warning: <cwd> is not trusted; project configuration
#                  (...) will be ignored ..." on stderr (vibe/cli/programmatic.py
#                  :177-194): expected, never a failure. UNLESS the folder is
#                  persistently trusted in ~/.vibe/trusted_folders.toml, which
#                  the script warns about (vibe_warn_persistent_trust): an
#                  interactive TUI "trust" answer writes the folder there
#                  (vibe/core/trusted_folders.py:199-218, add_trusted
#                  :327-333), and trust is the closest decision on the cwd's
#                  ancestor walk (_closest_decision :281-292), so a recorded
#                  repo root, OR AN ANCESTOR with nothing nearer untrusted, is
#                  trusted here too, --trust or not. There is no switch to
#                  drop the project layer: the harness hardcodes
#                  sources=("user", "project") (vibe/app_server/server.py:235,
#                  stdio.py:53-54). byre's own
#                  agent launch passes --trust per invocation, which persists
#                  nothing (vibe/cli/entrypoint.py:183-186), so the file only
#                  gains entries from a TUI answer someone gave in this box.
#     ~/.vibe/config.toml [[mcp_servers]]  Residual: the USER layer always
#                  loads, so MCP servers the BOX's own config declares still
#                  start inside the reviewer. Their tools cannot execute
#                  (outside the --enabled-tools allowlist, below), but each
#                  stdio server is a process the reviewer spawns. Only the
#                  inherited VIBE_MCP_SERVERS copy is dropped (the pre-flight).
#     --auto-approve --enabled-tools bash --enabled-tools read_file
#     --disabled-tools write_file/edit/task/todo/cron/run_typescript
#                  headless -p auto-DENIES every approval callback
#                  (programmatic.py:160-163), so --auto-approve is what lets
#                  the allowed tools run at all. Under the unified harness
#                  --enabled-tools is an EXECUTION allowlist, not an
#                  advertisement filter: write_file and edit stay in the tool
#                  list, and a call answers "tool_denied: Tool execution denied
#                  by approval policy" (verified: nothing written, also via
#                  run_typescript's tools.file_system.write_file). There is no
#                  grep tool (naming one is "unsupported top-level tool");
#                  bash + rg does that job. bash stays, as for every harness,
#                  so free-form writes remain possible: the tripwire's job.
#                  MCP tools are outside the allowlist too.
#                  The allowlist alone is not enough: an organisation's managed
#                  config (AdminConfigLayer, fetched from chat.mistral.ai with
#                  the Mistral key, vibe/core/config/admin_config.py:77) is the
#                  HIGHEST layer (default_orchestrator.py:68-78) and
#                  enabled_tools is WithReplaceMerge (vibe_schema.py:437), so
#                  an org enabled_tools = ["*"] REPLACES ours and --auto-approve
#                  then runs write_file and edit. disabled_tools is
#                  WithConcatMerge (vibe_schema.py:445, applied "after
#                  enabled_tools filtering"): no layer can remove an entry, so
#                  the denylist survives a managed config. Verified on its own
#                  (no --enabled-tools, --auto-approve): --disabled-tools
#                  write_file denies a write_file call with the same tool_denied
#                  and writes nothing, and also denies run_typescript's
#                  tools.file_system.write_file; --disabled-tools edit likewise
#                  for edit and tools.file_system.edit. Naming run_typescript
#                  does NOT stop the outer call (denying only run_typescript,
#                  its write_file ran and wrote), so its inner calls are gated
#                  by the inner tool's name, which the list covers; it is
#                  listed anyway, as are task (not advertised under the unified
#                  harness), todo and cron. An unknown name is not an error.
#                  Both lists stay (belt and braces). bash, and the bash-
#                  equivalent process.* capabilities, remain: the tripwire.
#     VIBE_*       env beats the user's config.toml (default_orchestrator.py:
#                  68-78). Telemetry/Sentry, update checks, GrowthBook
#                  experiments, the connectors catalog and notifications go
#                  off for the run. VIBE_API_RETRY_MAX_ELAPSED_TIME=60: 429s,
#                  5xx and network errors are retried until a wall-clock
#                  budget runs out (vibe/core/llm/backend/generic.py:279-286,
#                  default 300s, vibe/core/config/_defaults.py:17), and a run
#                  that dies on a rate limit should say so in a minute, not
#                  five; --timeout still bounds everything.
# - The PROMPT rides stdin (cli.py:61-74; an argv prompt would win over it,
#   cli.py:169-172, so none is passed).
# - --output json prints the session history as one JSON array on stdout
#   (PublicMessageEntry/PublicEffectEntry, vibe/app_server/models.py:959-992),
#   every entry stamped with sessionId; stdout is empty on failure, which
#   arrives as "Error: ..." on stderr with exit 1. Tool output stays inside
#   effect entries, never on vibe's stderr (verified: a bash probe's output
#   came back in .state.output), so stderr is CLI-owned and is what
#   report_failure_vibe reads. run_vibe appends it to $DBG after a marker line.
# - SESSIONS live under $REVIEW_DIR/.vibe-sessions (VIBE_SESSION_LOGGING__
#   SAVE_DIR), kept across runs (inside the self-ignoring .byre-devlog, so
#   outside the tripwire's snapshot and git), never in the box's ~/.vibe.
#   VIBE_SESSION_LOGGING__ENABLED=true rides along (SessionLoggingConfig,
#   vibe/core/config/models.py:99-118): a box config with [session_logging]
#   enabled = false would route the session to a throwaway root discarded at
#   close (vibe/app_server/_runtime.py:1329-1331, discard :1323), so no
#   record would land here, --continue would have nothing to resume, and the
#   pin check would fail closed with advice about aliases that does not apply.
#   Layout: unified/<sid>/{CURRENT,meta.json,generations/<gen>/...}.
#   `--resume <sid>` continues headless; an unknown id is "Error: Session not
#   found: <id>", exit 1, no request made, and falls back to fresh as for every
#   harness. -c/--continue is TTY/cwd-scoped, never used.
# - MODEL: vibe has no --model flag. The model is config active_model, an
#   ALIAS from [[models]], set here as VIBE_ACTIVE_MODEL. An alias vibe does
#   not know FALLS BACK SILENTLY to the default model (vibe/core/config/
#   vibe_schema.py:978-996: a log warning and a TUI-only validation warning):
#   exit 0, empty stderr, a review by another model (verified). And on
#   --resume the THREAD's stored model wins over VIBE_ACTIVE_MODEL (verified:
#   a resume pinned to fakealias2 requested the thread's fake-model). So with
#   a pin, vibe_pin_held reads the alias the run actually used back from the
#   session store and fails a mismatch: the ONLY guard, since neither the exit
#   code, stderr nor the json output carries the model.
VIBE_STDERR_MARK='----- vibe stderr -----'

# The two halves of $DBG. run_vibe writes vibe's stdout (the JSON history),
# then the marker line, then vibe's stderr. The marker is preceded by its own
# newline: vibe ends the json with one (vibe/cli/programmatic.py:109-110), but
# the marker must start a line even if it did not, and the blank line that
# normally results is harmless to jq and to these awk splits. The json output is indented, so no
# line of it can equal the marker (a string holding it would be quoted and
# indented); exact string compares, no regex.
vibe_json_part()   { awk -v m="$VIBE_STDERR_MARK" '$0 == m { exit } { print }' "$DBG" 2>/dev/null || true; }
vibe_stderr_part() { awk -v m="$VIBE_STDERR_MARK" 'f { print } $0 == m { f = 1 }' "$DBG" 2>/dev/null || true; }

# Final report = the text of the last assistant message entry of the LAST
# turn with any non-blank text. Scoped to the last turn because a resumed
# run's json repeats the whole thread (verified): unscoped, a resume that ends
# with no text would re-record the previous turn's report as the new one.
# The turn is the last entry's turnId. A message's text is its text blocks
# joined by blank lines, as PublicMessageEntry.text does (models.py:966-970);
# a non-string text is coerced to "" so join cannot abort jq. NO output, not
# "", when there is none (extract_ocfamily_report's reasoning: jq -r prints
# "" as a newline, a 1-byte $OUT that defeats every [ -s "$OUT" ] guard).
extract_vibe_report() {
  vibe_json_part | jq -r '
    if type != "array" or length == 0 then empty else
      (.[-1].turnId) as $t
      | [ .[] | objects
          | select(.turnId == $t and .type == "message" and .role == "assistant")
          | [ .content[]? | objects | select(.type == "text")
              | (.text | if type == "string" then . else "" end) ] | join("\n\n")
          | select(test("\\S")) ]
      | last // empty
    end' 2>/dev/null || true
}

extract_vibe_session() {
  vibe_json_part | jq -r 'if type == "array" then ([ .[] | objects | .sessionId | strings ] | first // empty) else empty end' \
    2>/dev/null || true
}

# The alias session $1 actually ran: CURRENT names the live generation, whose
# runtime-state.json records .session_metadata.active_model (the session
# store's layout, measured; meta.json has config: null). Both path parts are
# validated before use: the id is UUID-shaped, the generation all digits.
# Prints nothing when any step is missing.
vibe_session_model() {
  local sdir gen
  valid_session_id "$1" || return 0
  sdir="$REVIEW_DIR/.vibe-sessions/unified/$1"
  gen=$(jq -r '.generation // empty' "$sdir/CURRENT" 2>/dev/null || true)
  [[ "$gen" =~ ^[0-9]+$ ]] || return 0
  jq -r '.session_metadata.active_model // empty | strings' \
    "$sdir/generations/$gen/runtime-state.json" 2>/dev/null || true
}

# With a pin ($MODEL), true only when the run's session recorded exactly that
# alias. Fails CLOSED: no session id, or a store this can't read, is a
# failure too, since a review that cannot be shown to be the pinned model
# must not be logged under its name. Sets VIBE_RAN_MODEL (what vibe used, or
# "" when unknown) for report_failure_vibe. No pin: always true.
VIBE_RAN_MODEL=""
VIBE_PIN_FAILED=false
vibe_pin_held() {
  [ -n "$MODEL" ] || return 0
  VIBE_RAN_MODEL=$(vibe_session_model "$1")
  [ "$VIBE_RAN_MODEL" = "$MODEL" ] && return 0
  VIBE_PIN_FAILED=true
  return 1
}

# The entries of vibe's trust store $1, one per line: "T<TAB><path>" for
# trusted, "U<TAB><path>" for untrusted, in file order. vibe writes it with
# tomli_w as two top-level string arrays, trusted then untrusted
# (vibe/core/trusted_folders.py:269-279), e.g.
#     trusted = [
#         "/workspace",
#     ]
#     untrusted = []
# and reads it with tomllib (:252-267). There is no TOML parser in the box's
# toolset, so this is a small tokenizer for exactly that grammar: bare
# `key = [ "string", ... ]` pairs, '#' comments, single-line basic strings
# with only \\ and \" escapes, and literal '...' strings. Anything else (a
# table, a non-array value, a multi-line string, any other escape) exits 2:
# the caller warns that the file could not be read, rather than guessing.
# Other array-of-string keys are skipped, as tomllib's .get() does.
vibe_trusted_folders_entries() {
  awk '
    { buf = buf $0 "\n" }
    function bad() { exit 2 }
    END {
      n = length(buf); i = 1; st = "key"
      while (i <= n) {
        c = substr(buf, i, 1)
        if (c == " " || c == "\t" || c == "\r" || c == "\n") { i++; continue }
        if (c == "#") { while (i <= n && substr(buf, i, 1) != "\n") i++; continue }
        if (st == "key") {
          k = ""
          while (i <= n && substr(buf, i, 1) ~ /[A-Za-z0-9_-]/) { k = k substr(buf, i, 1); i++ }
          if (k == "") bad()
          st = "eq"; continue
        }
        if (st == "eq")  { if (c != "=") bad(); i++; st = "lb"; continue }
        if (st == "lb")  { if (c != "[") bad(); i++; st = "val"; continue }
        if (st == "sep") {
          if (c == ",") { i++; st = "val"; continue }
          if (c == "]") { i++; st = "key"; continue }
          bad()
        }
        # st == "val": a string, or the closing bracket (empty array, or
        # after a trailing comma).
        if (c == "]") { i++; st = "key"; continue }
        s = ""
        if (c == "\"") {
          if (substr(buf, i, 3) == "\"\"\"") bad()
          i++
          while (1) {
            if (i > n) bad()
            c = substr(buf, i, 1)
            if (c == "\n") bad()
            if (c == "\"") { i++; break }
            if (c == "\\") {
              c = substr(buf, i + 1, 1)
              if (c != "\\" && c != "\"") bad()
              s = s c; i += 2; continue
            }
            s = s c; i++
          }
        } else if (c == "\047") {
          if (substr(buf, i, 3) == "\047\047\047") bad()
          i++
          while (1) {
            if (i > n) bad()
            c = substr(buf, i, 1)
            if (c == "\n") bad()
            if (c == "\047") { i++; break }
            s = s c; i++
          }
        } else bad()
        if (k == "trusted") printf "T\t%s\n", s
        else if (k == "untrusted") printf "U\t%s\n", s
        st = "sep"
      }
      if (st != "key") bad()
    }' "$1"
}

# Legibility, not a gate (the honest ordering: the box boundary and the
# tripwire are what hold). Omitting --trust keeps the REVIEWED repo's .vibe/
# config, hooks, skills and agents out of the review only while vibe's
# persistent trust store does not cover the repo (see the vibe notes), so
# say loudly when it does, and proceed. Mirrors vibe's own lookup: the store
# is $VIBE_HOME/trusted_folders.toml, VIBE_HOME expanded and resolved,
# default ~/.vibe (vibe/utils/vibe_home.py:7-13, vibe/core/paths/
# _vibe_home.py:17); the cwd (the repo root here, physical as vibe's
# resolve() makes it) and then each ancestor up to /, the closest decision
# winning and trusted checked before untrusted at the same level
# (vibe/core/trusted_folders.py:281-292). A missing or unreadable store is
# "nothing trusted", as vibe treats it (it resets the file, :252-267);
# a store this cannot parse says so. Read-only: vibe owns the file. Once
# per run (a failed resume falls back to a fresh run_vibe).
VIBE_TRUST_CHECKED=false
vibe_warn_persistent_trust() {
  [ "$VIBE_TRUST_CHECKED" = true ] && return 0
  VIBE_TRUST_CHECKED=true
  local vh tf entries dir kind path hit="" here
  vh="${VIBE_HOME:-$HOME/.vibe}"
  case "$vh" in "~"|"~/"*) vh="$HOME${vh#\~}" ;; esac
  tf="$vh/trusted_folders.toml"
  { [ -f "$tf" ] && [ -r "$tf" ]; } || return 0
  if ! entries=$(vibe_trusted_folders_entries "$tf" 2>/dev/null); then
    echo "byre-codereview: WARNING: could not read vibe's trust store $tf" >&2
    echo "  (TOML this script does not parse), so it cannot tell whether this repo is persistently" >&2
    echo "  trusted. If it is, the reviewed repo's .vibe/ config, hooks, skills and agents WILL load" >&2
    echo "  into this review. Check the file in 'byre shell'. Proceeding." >&2
    return 0
  fi
  here=$(pwd -P)
  dir="$here"
  while [ -z "$hit" ]; do
    while IFS=$'\t' read -r kind path; do
      [ "$path" = "$dir" ] && [ "$kind" = T ] && { hit="$dir"; break; }
    done <<< "$entries"
    [ -n "$hit" ] && break
    while IFS=$'\t' read -r kind path; do
      [ "$path" = "$dir" ] && [ "$kind" = U ] && return 0
    done <<< "$entries"
    [ "$dir" = / ] && return 0
    dir="${dir%/*}"; [ -n "$dir" ] || dir=/
  done
  if [ "$hit" = "$here" ]; then
    echo "byre-codereview: WARNING: vibe persistently trusts this repo: $tf lists" >&2
    echo "  \"$hit\" (the repo root itself) under trusted." >&2
  else
    echo "byre-codereview: WARNING: vibe persistently trusts this repo: $tf lists" >&2
    echo "  \"$hit\" (an ancestor of the repo root $here) under trusted." >&2
  fi
  echo "  So the REVIEWED repo's .vibe/ config, hooks, skills and agents (and its AGENTS.md) WILL" >&2
  echo "  load into this review: omitting --trust does not isolate a trusted folder. The box" >&2
  echo "  boundary and the tripwire still hold. To undo it, remove that entry from the trusted" >&2
  echo "  list in $tf (in 'byre shell'). Proceeding." >&2
}

# Runs vibe and normalizes its two streams into the usual shape: $DBG = the
# JSON history, the marker line, then stderr; $OUT = the extracted report.
# Shared by fresh and resume, which differ only in --resume. Returns vibe's
# exit code (or timeout's).
run_vibe() {
  local err rc=0
  err=$(mktemp "$REVIEW_DIR/.err.XXXXXX")
  vibe_warn_persistent_trust
  printf '%s' "$PROMPT" | run_reviewer_cmd env VIBE_SESSION_LOGGING__SAVE_DIR="$REVIEW_DIR/.vibe-sessions" \
      VIBE_SESSION_LOGGING__ENABLED=true VIBE_ENABLE_TELEMETRY=false VIBE_ENABLE_UPDATE_CHECKS=false VIBE_EXPERIMENTS__ENABLE=false \
      VIBE_ENABLE_CONNECTORS=false VIBE_ENABLE_NOTIFICATIONS=false VIBE_API_RETRY_MAX_ELAPSED_TIME=60 \
      ${MODEL:+VIBE_ACTIVE_MODEL="$MODEL"} \
      vibe -p --auto-approve --enabled-tools bash --enabled-tools read_file \
      --disabled-tools write_file --disabled-tools edit --disabled-tools task \
      --disabled-tools todo --disabled-tools cron --disabled-tools run_typescript --output json "$@" \
      > "$DBG" 2> "$err" || rc=$?
  { printf '\n%s\n' "$VIBE_STDERR_MARK"; cat "$err"; } >> "$DBG" 2>/dev/null; rm -f "$err"
  extract_vibe_report > "$OUT"
  return "$rc"
}

run_fresh_vibe() {
  rm -f "$SESSION_FILE"
  announce_fresh
  local rc=0; run_vibe || rc=$?
  exit_if_timed_out "$rc" fresh
  if [ "$rc" -ne 0 ]; then
    # Partial-output courtesy, as everywhere (vibe's stdout is empty on the
    # failures seen, so this rarely fires).
    [ -s "$OUT" ] && cat "$OUT" >&2
    report_failure_vibe
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
  sid=$(extract_vibe_session)
  # Before the empty-report check: a review by the wrong model is the more
  # important thing to say, and its text is never shown or recorded.
  if ! vibe_pin_held "$sid"; then
    report_failure_vibe
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
  # Exit 0 with no final message must not read as a clean review; raw callers
  # may legitimately want no final text (codex's rationale).
  if [ "$RAW" != true ] && [ ! -s "$OUT" ]; then
    echo "byre-codereview: vibe exited 0 but produced no final message." >&2
    report_failure_vibe
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
  if [ -n "$sid" ] && valid_session_id "$sid"; then save_session "$sid"; else rm -f "$SESSION_FILE"; fi
  cat "$OUT"; record_review; cleanup
}

run_resume_vibe() {
  local sid="$1" rsid
  warn_cross_reviewer_resume
  announce_resume
  local rc=0; run_vibe --resume "$sid" || rc=$?
  exit_if_timed_out "$rc" resume
  local pin_miss=false
  if [ "$rc" -eq 0 ]; then
    rsid=$(extract_vibe_session)
    if ! vibe_pin_held "${rsid:-$sid}"; then
      # vibe keeps a resumed thread on the model it started with (see the
      # notes), so a pin the thread does not carry cannot be honoured by a
      # resume. The fresh review it falls back to runs the pin, and its own
      # check fails a pin vibe does not know. The resume itself worked, so
      # this is not announced as a failed one.
      echo "byre-codereview: vibe continued this thread on '${VIBE_RAN_MODEL:-an unknown model}', not the pinned '$MODEL'" >&2
      echo "  (a resumed vibe thread keeps its own model); that turn is discarded." >&2
      VIBE_PIN_FAILED=false; pin_miss=true
    elif [ -s "$OUT" ]; then
      cat "$OUT"; record_review; cleanup; return 0
    elif [ "$RAW" = true ]; then
      # A raw --continue may end with no final text: keep $DBG, which the
      # notice points at (the codex/opencode resume handling).
      echo "(could not extract final message; raw kept at: $DBG)"; rm -f "$OUT"; return 0
    fi
    # A built-in review with no report is a failure here too (mimo's
    # handling): the fresh run's own failure path then names the fix.
  fi
  # Partial-output courtesy for a failed resume only; a wrong-model turn is
  # never shown.
  if [ "$rc" -ne 0 ] && [ -s "$OUT" ]; then cat "$OUT" >&2; fi
  if [ "$pin_miss" = true ]; then
    echo "A fresh review on the pinned '$MODEL' follows." >&2
  else
    echo "Resume failed — falling back to a fresh review." >&2
  fi
  rm -f "$SESSION_FILE"; VIBE_RAN_MODEL=""; run_fresh_vibe
}

# Advice-only, scoped to vibe's stderr (vibe_stderr_part, CLI-owned under
# --output json), never the history: effect entries embed reviewer command
# output, and a review of this very script quotes every pattern below (the
# zai lesson, see codex_family_error_events). Shapes verified 2026-10-06
# (vibe 2.26.0): "Error: Missing <VAR> environment variable for <provider>
# provider. ...", "Error: Invalid API key (from env var <VAR>). ..." (a 401),
# "Error: Client error '402 Payment Required' for url ...", "'429 Too Many
# Requests'", "Error: Server error '500 Internal Server Error' ...", "Error:
# Session not found: <id>". Order: the pin check's verdict first (exit 0, so
# stderr is silent), then the resume miss, then auth, then funds and rate
# limits, which are NOT key problems, then outages. `grep >/dev/null`, not -q:
# the SIGPIPE-under-pipefail hole report_failure_mimo documents.
report_failure_vibe() {
  local errs var
  errs=$(vibe_stderr_part)
  # vibe's own words first, indented; the untrusted-cwd warning is not one.
  { printf '%s\n' "$errs" | grep -E '^Error:' || true; } | sed 's/^/  /' >&2
  if [ "$VIBE_PIN_FAILED" = true ]; then
    if [ -n "$VIBE_RAN_MODEL" ]; then
      echo "byre-codereview: vibe ran '$VIBE_RAN_MODEL', not the pinned '$MODEL', so the review was discarded." >&2
      echo "  vibe silently falls back to its default model when an alias is not one it knows." >&2
    else
      echo "byre-codereview: could not confirm that vibe ran the pinned '$MODEL' (no session id or" >&2
      echo "  session record in .byre-devlog/.vibe-sessions), so the review was discarded." >&2
    fi
    echo "  vibe takes a config ALIAS, not a provider model id: the aliases are the [[models]]" >&2
    echo "  entries' alias = \"...\" in the box's ~/.vibe/config.toml. Pin one of those with" >&2
    echo "  --reviewer vibe:<alias>, or run bare '--reviewer vibe' for the box's active_model." >&2
  elif printf '%s' "$errs" | grep -E '^Error: Session not found' >/dev/null; then
    echo "byre-codereview: vibe no longer has the saved review session." >&2
  elif printf '%s' "$errs" | grep -E '^Error: (Missing [A-Za-z0-9_]+ environment variable|Invalid API key)' >/dev/null; then
    var=$(printf '%s' "$errs" | grep -oE 'Missing [A-Za-z0-9_]+ environment variable|from env var [A-Za-z0-9_]+' \
      | sed -n '1{s/^Missing //;s/ environment variable$//;s/^from env var //;p}' || true)
    if [ -z "$var" ] || [ "$var" = MISTRAL_API_KEY ]; then
      echo "byre-codereview: vibe has no usable Mistral API key (MISTRAL_API_KEY missing or rejected)." >&2
      echo "  Set MISTRAL_API_KEY for the box: byre credentials, env_from_host, or the" >&2
      echo "  pjlsergeant/vibe-shared-auth skill (asks once, exports it every launch). Or log in" >&2
      echo "  once in another terminal: run 'byre shell', then 'vibe-login' (vibe's own onboarding;" >&2
      echo "  it needs a terminal, so never from a tool call). A key from console.mistral.ai." >&2
      if [ -n "$MODEL" ]; then
        echo "  With a pin: an alias vibe does not know falls back to its default Mistral model," >&2
        echo "  which is what needs this key — check that '$MODEL' is an alias in the box's" >&2
        echo "  ~/.vibe/config.toml [[models]] first." >&2
      fi
    else
      echo "byre-codereview: vibe's provider key $var is missing or was rejected. The box's" >&2
      echo "  ~/.vibe/config.toml routes the model to a provider that reads it; set it in the" >&2
      echo "  box's environment (byre credentials / env_from_host) or in ~/.vibe/.env." >&2
    fi
  elif printf '%s' "$errs" | grep -E "^Error: Client error '402" >/dev/null; then
    echo "byre-codereview: vibe's provider refused for lack of credits (402 Payment Required)." >&2
    echo "  The key works; this is NOT a key problem. Add credits or a plan to the Mistral" >&2
    echo "  account (console.mistral.ai), or use another reviewer." >&2
  elif printf '%s' "$errs" | grep -E "^Error: Client error '429" >/dev/null; then
    echo "byre-codereview: vibe's provider rate-limited the review (429 Too Many Requests), still" >&2
    echo "  after vibe's retries (capped at 60s here). NOT a key problem: retry later, or use" >&2
    echo "  another reviewer." >&2
  elif printf '%s' "$errs" | grep -E "^Error: Server error '5" >/dev/null; then
    echo "byre-codereview: vibe's provider failed with a server error (5xx), still after vibe's" >&2
    echo "  retries (capped at 60s here) — a provider outage, not a key problem. Retry later," >&2
    echo "  or use another reviewer." >&2
  else
    echo "byre-codereview: review failed." >&2
  fi
  echo "  Debug log: $DBG" >&2
}

# Chooses which ADVICE a run that has ALREADY failed prints. Nothing here can
# discard anything, which is exactly why it may read what the gate must not:
# a wrong guess costs a wasted glance.
#
# So $DBG gets the loose hint pattern, and $OUT is consulted too — head-anchored
# via the gate pattern, since an auth death announces itself at the top. That
# matters for the common shape the gate deliberately no longer catches: auth
# text on stdout with a non-zero exit. Without this the reader gets a bare
# "review failed" and a log path, which is how the original "Not signed in"
# miss went unnoticed (observed in-box 2026-07-29): the old pattern looked for
# "not logged in" and "sign in", and "sign in" != "signed in".
#
# Model rejection is checked first, so a bad pinned model is never sent to
# re-login. grok's shape is stderr-only with exit 1 (verified live 2026-10-01,
# grok 1.0.46): "Couldn't set model 'nonexistent-model': Invalid params:
# "unknown model id". Run 'grok models' to see available models." — read from
# $DBG (CLI stderr, a CLI-owned channel), never the $OUT body. Advice only:
# this pattern must NOT be wired into grok_not_a_review, the discard gate.
report_failure_grok() {
  if grep -qiE "Couldn.t set model|unknown model id" "$DBG" 2>/dev/null; then
    echo "byre-codereview: grok rejected the model${MODEL:+ '$MODEL'}." >&2
    echo "  'grok models' lists the ones it can run; pin one with --reviewer grok:<model>," >&2
    echo "  or run bare '--reviewer grok' for its default." >&2
    echo "  Debug log: $DBG" >&2
  elif auth_advice "$DBG" || opens_like_auth "$OUT"; then
    echo "byre-codereview: grok may need re-authentication (its ~6h tokens refresh silently until the chain dies)." >&2
    echo "  Run 'byre shell', then: grok-login (or: grok login --device-auth)" >&2
    echo "  Debug log: $DBG" >&2
  else
    echo "byre-codereview: review failed. Debug log: $DBG" >&2
  fi
}

# Session-id validation is per-CLI. codex/zai/grok/claude/vibe ids are UUIDs, case-
# folded here because historical session files vary in case. opencode and mimo
# ids are ses_ + 12 hex + 14 base62 chars and case-SENSITIVE (mimo: id.ts:88,
# live sample ses_ffe5f078b3f48ffe3Asi4Y6Y82) — folding one would corrupt it,
# so that branch must never share the tr.
# vibe ids ride the generic branch: lowercase 8-4-4-4-12 hex, UUID-shaped but
# NOT RFC-4122 (the version/variant nibbles are arbitrary, e.g.
# bc0cd530-1134-dd89-4a48-db039c69f144), so never tighten it to a v4 check.
valid_session_id() {
  case "$HARNESS" in
    opencode|mimo) [[ "$1" =~ ^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$ ]] ;;
    *) [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ;;
  esac
}

if [ "$CONTINUE" = true ] && [ -f "$SESSION_FILE" ]; then
  # Every session file is id, then reviewer string (one line in older files) —
  # only line 1 is the id; see the SESSION_FILE comment. The UUID harnesses'
  # ids are case-folded, opencode's/mimo's never (see valid_session_id).
  if [ "$HARNESS" = opencode ] || [ "$HARNESS" = mimo ]; then sid=$(head -n1 "$SESSION_FILE")
  else sid=$(head -n1 "$SESSION_FILE" | tr '[:upper:]' '[:lower:]'); fi
  if valid_session_id "$sid"; then
    "run_resume_$HARNESS" "$sid"
  else
    rm -f "$SESSION_FILE"; "run_fresh_$HARNESS"
  fi
else
  "run_fresh_$HARNESS"
fi
