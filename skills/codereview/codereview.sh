#!/usr/bin/env bash
# byre-codereview — an independent second-opinion review of the current changes.
# Shipped by the codereview skill; pairs with a reviewer skill that installs the
# reviewer binary: codex (the default), grok, claude, opencode, and/or zai.
# Reviews the working tree's git changes and prints findings, and appends them
# to .byre-devlog/reviews.md.
#
#   byre-codereview                        # review current changes (codex)
#   byre-codereview "focus area"           # focus the review
#   byre-codereview --continue "..."       # re-check after fixes (resumes session)
#   byre-codereview --reviewer grok "..."  # use grok as the reviewer
#   byre-codereview --raw "prompt"         # your prompt verbatim, no review prompt
#
# BYRE_REVIEWER sets the default reviewer (codex when unset). A reviewer is
# "harness" or "harness:model" — see the parsing below; only opencode consumes
# a model today.
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
  byre-codereview --reviewer <name> ...  choose the reviewer: codex (default) | grok | claude | opencode | zai
                                         opencode also takes a model as opencode:<provider/model>
                                         (e.g. opencode:openrouter/~openai/gpt-latest)
                                         zai reviews through the isolated Z.AI Codex home (GLM)
  byre-codereview --raw "prompt"         send YOUR prompt verbatim (skips the
                                         built-in review prompt; mechanics stay)
  byre-codereview --raw -- "--anything"  -- ends option parsing, so option-shaped
                                         prompt text passes through

BYRE_REVIEWER sets the default reviewer.
EOF
}

REVIEWER="${BYRE_REVIEWER:-codex}"
CONTINUE=false
RAW=false
FOCUS=()
expect_reviewer=false
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
  case "$arg" in
    -h|--help) usage; exit 0 ;;
    --continue) CONTINUE=true ;;
    --raw) RAW=true ;;
    --reviewer) expect_reviewer=true ;;
    --reviewer=*) REVIEWER="${arg#--reviewer=}" ;;
    # Everything after -- is prompt text, never an option — the only way an
    # option-shaped prompt ("--help") can reach the reviewer, raw or focused.
    --) ddash=true ;;
    *) FOCUS+=("$arg") ;;
  esac
done
if [ "$expect_reviewer" = true ]; then
  echo "byre-codereview: --reviewer needs a value (codex | grok | claude | opencode | zai)." >&2
  exit 2
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
# command lookup, session files, and dispatch. Only opencode consumes a model
# today; a harness that got one it can't use must FAIL, not silently review
# with its default while the log claims otherwise.
HARNESS="$REVIEWER"
MODEL=""
case "$REVIEWER" in
  *:*)
    HARNESS="${REVIEWER%%:*}"
    MODEL="${REVIEWER#*:}"
    # "opencode:" (empty model) means no model — same as bare "opencode".
    [ -z "$MODEL" ] && REVIEWER="$HARNESS"
    ;;
esac

case "$HARNESS" in
  codex|grok|claude|opencode|zai) ;;
  *)
    echo "byre-codereview: unsupported reviewer '$HARNESS' (codex | grok | claude | opencode | zai)." >&2
    exit 2
    ;;
esac

if ! command -v "$HARNESS" >/dev/null 2>&1; then
  echo "byre-codereview: $HARNESS not found on PATH." >&2
  echo "  Add the $HARNESS skill (skills = [\"$HARNESS\", \"codereview\"]) and rebuild." >&2
  for other in codex grok claude opencode zai; do
    [ "$other" = "$HARNESS" ] && continue
    if command -v "$other" >/dev/null 2>&1; then
      echo "  ($other is available: byre-codereview --reviewer $other)" >&2
    fi
  done
  exit 127
fi

# After the PATH check, so a missing harness is reported as the missing
# harness it is — not as a model-wiring gap it also happens to have.
if [ -n "$MODEL" ] && [ "$HARNESS" != opencode ]; then
  echo "byre-codereview: model selection is only wired up for opencode — '$HARNESS' would silently ignore '$MODEL'." >&2
  echo "  Run '--reviewer $HARNESS' plain, or extend the $HARNESS runner to consume a model." >&2
  exit 2
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
# the same thread (every CLI here applies the model per-prompt, not per-session).
# That crossing is legitimate — handing a thread to a stronger model is a real
# move — but it must be VISIBLE, so opencode's file carries the reviewer
# string on a second line and the resume path warns when it differs (surfaced
# by a deepseek review of this very feature, 2026-08-08).
case "$HARNESS" in
  codex)    SESSION_FILE="$REVIEW_DIR/.review-session" ;;
  grok)     SESSION_FILE="$REVIEW_DIR/.review-session-grok" ;;
  claude)   SESSION_FILE="$REVIEW_DIR/.review-session-claude" ;;
  opencode) SESSION_FILE="$REVIEW_DIR/.review-session-opencode" ;;
  zai)      SESSION_FILE="$REVIEW_DIR/.review-session-zai" ;;
esac

# RUN_NOTE annotates the "Running..." line: raw mode says so instead of echoing
# the whole prompt back as a "focus".
if [ "$RAW" = true ]; then RUN_NOTE=" (raw)"; else RUN_NOTE="${FOCUS:+ (focus: ${FOCUS[*]})}"; fi

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

# Snapshot of the working tree the reviewer must not change. NOTE the limit of
# what this can police: it covers the git working tree and nothing else. State
# outside it — credentials (~/.codex/auth.json, ~/.grok, opencode's
# ~/.local/share/opencode/auth.json), other volumes, the rest of $HOME — is
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
  echo "Running code review (${HARNESS})${RUN_NOTE} — this may take several minutes..."
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
  if "$HARNESS" exec --skip-git-repo-check --json --sandbox danger-full-access "$PROMPT" \
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
    [ -n "$sid" ] && [ "$sid" != "null" ] && echo "$sid" > "$SESSION_FILE" || rm -f "$SESSION_FILE"
    cat "$OUT"; record_review; cleanup
  else
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
  if printf '%s' "$errs" | grep -qiE 'token_expired|refresh token|sign in again|authentication token is expired|401 unauthorized'; then
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

report_failure_zai() {
  local errs; errs=$(codex_family_error_events)
  if printf '%s' "$errs" | grep -qiE '"code"[[:space:]]*:[[:space:]]*401|token expired or incorrect|stream closed before response\.completed|unauthorized|invalid api key|api key|401'; then
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
  echo "Continuing previous review session (${HARNESS}) — this may take several minutes..."
  # The resume subcommand rejects --sandbox ("unexpected argument", clap exit 2
  # — every resume then fell back to a fresh review, silently), but it takes -c
  # overrides, and sandbox_mode is the same knob by its config name (value
  # matches the fresh path's --sandbox; see the rationale there). It DOES
  # accept --output-last-message, so the fresh path's extraction works here too.
  if "$HARNESS" exec resume --skip-git-repo-check --json -c sandbox_mode="danger-full-access" \
       "$sid" "$PROMPT" --output-last-message "$OUT" < /dev/null > "$DBG" 2>&1; then
    new=$(extract_codex_session); [ -n "$new" ] && [ "$new" != "null" ] && echo "$new" > "$SESSION_FILE"
    # No extractable message: keep $DBG — cleanup would delete the very file
    # the notice points at (a raw --continue can legitimately end with no
    # final text, and an extraction failure needs the log even more).
    if [ -s "$OUT" ]; then cat "$OUT"; record_review; cleanup; else
      echo "(could not extract final message; raw kept at: $DBG)"; rm -f "$OUT"
    fi
  else
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
  echo "Running code review (grok)${RUN_NOTE} — this may take several minutes..."
  # -s pre-assigns the session UUID (grok creates it), so --continue can
  # --resume it later without parsing any output.
  local sid; sid=$(cat /proc/sys/kernel/random/uuid)
  if GROK_SUBAGENTS=0 grok -p "$PROMPT" -s "$sid" --always-approve --disallowed-tools "$GROK_TOOL_STRIP" \
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
    echo "$sid" > "$SESSION_FILE"
    cat "$OUT"; record_review; cleanup
  else
    # Surface whatever partial output exists — same courtesy as the startup
    # path; failure details otherwise vanish with the temp file.
    [ -s "$OUT" ] && cat "$OUT" >&2
    report_failure_grok
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
}

run_resume_grok() {
  local sid="$1"
  echo "Continuing previous review session (grok) — this may take several minutes..."
  if GROK_SUBAGENTS=0 grok -p "$PROMPT" --resume "$sid" --always-approve --disallowed-tools "$GROK_TOOL_STRIP" \
       < /dev/null > "$OUT" 2> "$DBG" && ! grok_not_a_review; then
    cat "$OUT"; record_review; cleanup
  else
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
#   permission rule when passed after them).
# - Sessions: --session-id pre-assigns the UUID, like grok's -s; --resume works
#   headless, repeatedly, against the SAME id. A run that dies early can still
#   consume its pre-assigned id ("already in use"), which is one more reason
#   every fresh run mints a new one.
CLAUDE_TOOL_STRIP="Edit,Write,NotebookEdit,TodoWrite,Task"

run_fresh_claude() {
  rm -f "$SESSION_FILE"
  echo "Running code review (claude)${RUN_NOTE} — this may take several minutes..."
  local sid; sid=$(cat /proc/sys/kernel/random/uuid)
  if printf '%s' "$PROMPT" | claude -p --safe-mode --session-id "$sid" \
       --allowedTools "Bash" --disallowedTools "$CLAUDE_TOOL_STRIP" \
       > "$OUT" 2> "$DBG"; then
    # Exit 0 with nothing to say has no legitimate reading — never record it
    # as a clean review (grok's lesson, applied preemptively).
    if [ ! -s "$OUT" ]; then
      echo "byre-codereview: claude produced no output despite exit 0." >&2
      echo "  Debug log: $DBG" >&2
      rm -f "$OUT" "$SESSION_FILE"; exit 1
    fi
    echo "$sid" > "$SESSION_FILE"
    cat "$OUT"; record_review; cleanup
  else
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
  echo "Continuing previous review session (claude) — this may take several minutes..."
  if printf '%s' "$PROMPT" | claude -p --safe-mode --resume "$sid" \
       --allowedTools "Bash" --disallowedTools "$CLAUDE_TOOL_STRIP" \
       > "$OUT" 2> "$DBG" && [ -s "$OUT" ]; then
    cat "$OUT"; record_review; cleanup
  else
    # Same partial-output courtesy as the fresh path before the fallback eats it.
    [ -s "$OUT" ] && cat "$OUT" >&2
    echo "Resume failed — falling back to a fresh review." >&2
    rm -f "$SESSION_FILE"; run_fresh_claude
  fi
}

# "Not logged in · Please run /login" arrives on STDOUT with exit 1 (verified),
# so the auth grep covers $OUT as well as the debug log. Tight patterns only,
# same rationale as grok's.
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

# Final report = the text parts of the LAST assistant message, joined. Joining
# (rather than taking only the last part) keeps a report the model split
# across parts; unique_by drops any re-emitted part update and sorts by part
# id, which is chronological (ascending ids). fromjson? skips the appended
# stderr lines.
extract_opencode_report() {
  jq -rRs '
    [ split("\n")[] | fromjson? | select(.type=="text") ]
    | unique_by(.part.id)
    | if length==0 then "" else
        (.[-1].part.messageID) as $m
        | [ .[] | select(.part.messageID==$m) | .part.text ] | join("\n\n")
      end' "$DBG" 2>/dev/null || true
}

extract_opencode_session() {
  jq -rRs '[ split("\n")[] | fromjson? | .sessionID ] | first // empty' "$DBG" 2>/dev/null || true
}

# Runs opencode and normalizes its two streams into the usual shape: $DBG =
# JSONL events then stderr, $OUT = extracted final report. Shared by fresh and
# resume, which differ only in the session flag. Returns opencode's exit code.
run_opencode() {
  local err rc=0
  err=$(mktemp "$REVIEW_DIR/.err.XXXXXX")
  # ${MODEL:+...} adds --model only when the harness:model form supplied one;
  # otherwise the box's opencode config picks, as before.
  printf '%s' "$PROMPT" | OPENCODE_DISABLE_PROJECT_CONFIG=1 OPENCODE_DISABLE_AUTOUPDATE=1 \
      OPENCODE_PERMISSION="$OPENCODE_REVIEW_PERMS" \
      opencode run --format json --agent plan --title "byre-codereview" \
      ${MODEL:+--model "$MODEL"} "$@" \
      > "$DBG" 2> "$err" || rc=$?
  cat "$err" >> "$DBG" 2>/dev/null; rm -f "$err"
  extract_opencode_report > "$OUT"
  return "$rc"
}

run_fresh_opencode() {
  rm -f "$SESSION_FILE"
  echo "Running code review (${REVIEWER})${RUN_NOTE} — this may take several minutes..."
  if run_opencode; then
    # Same empty-output guard as the others: exit 0 with no final message must
    # not read as a clean review. Raw callers may legitimately want no final
    # text, so the guard applies only to built-in reviews (codex's rationale).
    if [ "$RAW" != true ] && [ ! -s "$OUT" ]; then
      echo "byre-codereview: opencode exited 0 but produced no final message." >&2
      echo "  Debug log: $DBG" >&2
      rm -f "$OUT" "$SESSION_FILE"; exit 1
    fi
    sid=$(extract_opencode_session)
    # Line 2 records WHO started the thread (see the SESSION_FILE comment).
    [ -n "$sid" ] && printf '%s\n%s\n' "$sid" "$REVIEWER" > "$SESSION_FILE" || rm -f "$SESSION_FILE"
    cat "$OUT"; record_review; cleanup
  else
    # Partial-output courtesy, as everywhere: a report extracted from a failed
    # run still beats a bare log path.
    [ -s "$OUT" ] && cat "$OUT" >&2
    report_failure_opencode
    rm -f "$OUT" "$SESSION_FILE"; exit 1
  fi
}

run_resume_opencode() {
  local sid="$1"
  # A resume under a different reviewer string feeds the OLD model's thread —
  # its findings, your replies — to the new one while the Running line and the
  # reviews.md heading name only the new one. Legitimate, but never silent.
  # Warn-only, and absent line 2 (a pre-1.3.0 session file) says nothing.
  local prev; prev=$(sed -n 2p "$SESSION_FILE" 2>/dev/null || true)
  if [ -n "$prev" ] && [ "$prev" != "$REVIEWER" ]; then
    echo "byre-codereview: note — resuming a session started by '$prev' as '$REVIEWER':" >&2
    echo "  the thread's earlier turns are the old model's. For an unprimed opinion" >&2
    echo "  from '$REVIEWER', run without --continue." >&2
  fi
  echo "Continuing previous review session (${REVIEWER}) — this may take several minutes..."
  if run_opencode --session "$sid"; then
    # Same no-message handling as the codex resume: keep $DBG, since the
    # notice points at it and cleanup would delete it.
    if [ -s "$OUT" ]; then cat "$OUT"; record_review; cleanup; else
      echo "(could not extract final message; raw kept at: $DBG)"; rm -f "$OUT"
    fi
  else
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
report_failure_grok() {
  if auth_advice "$DBG" || opens_like_auth "$OUT"; then
    echo "byre-codereview: grok may need re-authentication (its ~6h tokens refresh silently until the chain dies)." >&2
    echo "  Run 'byre shell', then: grok-login (or: grok login --device-auth)" >&2
    echo "  Debug log: $DBG" >&2
  else
    echo "byre-codereview: review failed. Debug log: $DBG" >&2
  fi
}

# Session-id validation is per-CLI. codex/zai/grok/claude ids are UUIDs, case-
# folded here because historical session files vary in case. opencode ids are
# ses_ + 12 hex + 14 base62 chars and case-SENSITIVE — folding one would
# corrupt it, so that branch must never share the tr.
valid_session_id() {
  case "$HARNESS" in
    opencode) [[ "$1" =~ ^ses_[0-9a-f]{12}[0-9A-Za-z]{14}$ ]] ;;
    *) [[ "$1" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ;;
  esac
}

if [ "$CONTINUE" = true ] && [ -f "$SESSION_FILE" ]; then
  # opencode's file is two lines (id, then reviewer string) — only line 1 is
  # the id; see the SESSION_FILE comment.
  if [ "$HARNESS" = opencode ]; then sid=$(head -n1 "$SESSION_FILE"); else sid=$(tr '[:upper:]' '[:lower:]' < "$SESSION_FILE"); fi
  if valid_session_id "$sid"; then
    "run_resume_$HARNESS" "$sid"
  else
    rm -f "$SESSION_FILE"; "run_fresh_$HARNESS"
  fi
else
  "run_fresh_$HARNESS"
fi
