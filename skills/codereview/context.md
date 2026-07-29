# Code review loop (codereview)

byre placed this guidance here; it applies to every session in this box.

## Run a review after each feature or fix

This box ships `byre-codereview` — an independent reviewer (Codex by default;
`--reviewer grok|claude` or `BYRE_REVIEWER=...` picks another installed one).
After completing any feature or fix, run it yourself and act on the findings;
don't ask permission first.

```sh
byre-codereview                       # review the current changes
byre-codereview "auth error handling" # focus the review
byre-codereview --continue "..."      # re-check after fixes (resumes the session)
byre-codereview --reviewer grok "..." # second opinion from grok instead
byre-codereview --raw "prompt"        # your prompt verbatim (no built-in review prompt)
```

Prefer a reviewer that ISN'T the model driving this session: same-model review
is a second pass, not a second opinion. `--reviewer claude` is there for boxes
where claude is the only CLI.

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
reviewer's prior session (codex `exec resume`, grok/claude `--resume`), so the
reviewer still has its own earlier findings, and your replies to them, in
context. That makes a resumed run a re-read of a conversation it is already
invested in: it is prone to accept "fixed" at your word and to repeat its own
framing. Omit the flag and the reviewer starts from an empty context and sees
only the code.

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
