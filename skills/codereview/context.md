# Code review loop (codereview)

byre placed this guidance here; it applies to every session in this box.

## Run a review after each feature or fix

This box ships `byre-codereview` — an independent reviewer (Codex by default;
`--reviewer grok|claude|opencode|zai` or `BYRE_REVIEWER=...` picks another
installed one). After completing any feature or fix, run it yourself and act
on the findings; don't ask permission first.

```sh
byre-codereview                       # review the current changes
byre-codereview "auth error handling" # focus the review
byre-codereview --continue "..."      # re-check after fixes (resumes the session)
byre-codereview --reviewer grok "..." # second opinion from grok instead
byre-codereview --raw "prompt"        # your prompt verbatim (no built-in review prompt)
```

Prefer a reviewer that ISN'T the model driving this session: same-model review
is a second pass, not a second opinion. `--reviewer claude` is there for boxes
where claude is the only CLI. `--reviewer zai` runs GLM through the isolated
Z.AI Codex home — in a zai-authored box that is the same family again, so use
it as a consciously-named second pass, never as a codex stand-in. Note that
`--reviewer opencode` says nothing
about the model: opencode is a meta-CLI, and the review runs on whatever model
the box's opencode config defaults to — check that config when independence
matters, or pin the model yourself with the `harness:model` form:

```sh
byre-codereview --reviewer opencode:openrouter/~openai/gpt-latest "..."
```

`opencode models` lists what the box can run. Only opencode consumes a model
today; the other harnesses reject the colon form rather than silently ignore
it.

The loop: run it → read every finding → for each, fix it or note why you're
leaving it → if you changed anything, re-run with `--continue` → stop only when
clean or all remaining items are consciously deferred. Findings are also
appended to `.byre-devlog/reviews.md`. Reviewers may run cheap read-only probes
to back up findings but never your test suite — green stays YOUR job — and must
not touch the tree; the script warns if the working tree changed during a
review.

### Fresh / blinded runs

A **fresh** or **blinded** review means running **without `--continue`** — and
that is the whole of what those words mean here. `--continue` resumes the
reviewer's prior session (codex/zai `exec resume`, grok/claude `--resume`,
opencode `--session`), so the reviewer still has its own earlier findings, and
your replies to them, in context. That makes a resumed run a re-read of a conversation it is already
invested in: it is prone to accept "fixed" at your word and to repeat its own
framing. Omit the flag and the reviewer starts from an empty context and sees
only the code.

"Sees only the code" includes the audit trail: the built-in prompt forbids
reading `.byre-devlog/` (earlier findings, session/debug files, the diary).
A "fresh" reviewer that reads its predecessor's review has re-primed itself
through the back door — same bias, new session id. If a reviewer discloses
that it read review artifacts anyway, treat its run as resumed, not fresh.

So when asked for a fresh, blinded, clean-room, or independent look — or to
confirm a fix "properly" — drop `--continue`. Do not reach for a different
reviewer instead: switching from codex to grok is a different *opinion*, not a
blinded one, and switching back and forth is not a substitute for an unprimed
context.

Both have their place, and the useful cycle alternates them: `--continue` to
verify a specific fix cheaply (the reviewer knows what it asked for), then a
fresh run to check the result without priming, repeating until a fresh run
comes back clean. A `--continue` run that reports "all resolved" is weaker
evidence than a fresh run that finds nothing, because only the second one was
never told what to expect.

The reviewer needs to be logged in once per box. This skill ships two
helpers for that:

```sh
codex-login   # device-code sign-in for codex
grok-login    # device-code sign-in for grok
```

Both wrap their CLI's `login --device-auth`. Use them instead of a plain
`codex login` / `grok login`, which start a browser-redirect flow that cannot
complete in a no-browser sandbox. They need a terminal to show the URL and
code, so **you cannot run them yourself from a tool call** — if
`byre-codereview` reports an authentication failure, tell the user to run
`byre shell` and then the relevant helper.

opencode needs no helper: `opencode auth login` is already a terminal paste
flow. It is still interactive, so the same rule applies — the user runs it in
`byre shell`, never you from a tool call. opencode also needs a tool-capable
default model (`model` in the global opencode config); the review script names
that fix when a run fails on it.

### zai boxes: codex exists, its OpenAI login may not

When the box's agent is `pjlsergeant/zai`, the codex binary is present (zai
requires byre's built-in Codex skill) but its OpenAI login was likely skipped —
it is irrelevant to zai, which authenticates with `ZAI_API_KEY` instead. The
default `codex` reviewer will therefore keep failing until someone completes
`codex-login`. That is not a bug to paper over: do NOT alias, fall back, or
point codex at zai's `CODEX_HOME`. The review log names the reviewer, and a
`codex` entry that actually ran GLM is a forged audit trail — worse than a
failed review, because nobody can see what they didn't get.

Choose deliberately:

- **Independent opinion** — complete `codex-login` (device flow, user-run in
  `byre shell`), or use grok/claude/opencode when installed.
- **Same-family second pass, honestly named** — `byre-codereview --reviewer
  zai`. This works on `ZAI_API_KEY` alone.

zai keeps its own session file (`.byre-devlog/.review-session-zai`): its thread
ids look exactly like codex's but live in another `CODEX_HOME` and another
provider, so `--continue` must never cross between them. Review runs also strip
`ZAI_CODEX_BIN`, so the reviewer rides the plain codex binary rather than
byre's launch adapter — it inherits neither the authoring agent's MCP servers
nor its injected developer context. A blinded review starts unprimed — and the
built-in prompt keeps it out of `.byre-devlog/`, as for every harness.

zai has no login command. If Z.AI rejects the key, the script names the
rotation: a project-sourced `ZAI_API_KEY` is replaced at its source; with
`zai-shared-auth` the user removes `~/.byre-identity/zai/api-key` in
`byre shell`, exits that shell immediately (it still exports the old key), and
relaunches byre to paste the replacement.
