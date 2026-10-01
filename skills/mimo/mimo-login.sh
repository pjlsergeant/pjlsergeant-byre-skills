#!/bin/sh
# mimo first-run auth hook (a port of byre's opencode-login hook) -- runs as
# the dev user, before the agent launches, on a fresh box. If no MiMo
# credential is stored, run `mimo auth login -p xiaomi` so the agent works
# out of the box.
#
# That login is a paste-code flow (verified live, mimo 0.1.15): it prints a
# https://platform.xiaomimimo.com/authorize?... URL and waits at "Paste code
# here if prompted >" -- no in-box browser needed (its xdg-open attempt fails
# with a harmless warning). The credential lands in auth.json in the
# .mimocode state volume, so this runs once per project and survives
# rebuilds. Best-effort: skip with Ctrl-C (or on failure/timeout) and the
# box still launches -- log in later with `mimo auth login -p xiaomi` from
# `byre shell`.
command -v mimo >/dev/null 2>&1 || exit 0
# mimo's data dir is the XDG data home (verified, `mimo debug paths`);
# honoring XDG_DATA_HOME keeps the hook faithful to the CLI's own resolution
# (and is the test seam). MIMOCODE_HOME would relocate it too, but the
# state volume would not follow -- unsupported, like XDG_DATA_HOME in [env].
data_root="${XDG_DATA_HOME:-/home/dev/.local/share}"
cred="$data_root/mimocode/auth.json"
# A symlinked credential must never count -- drop it so a clean re-login
# writes a fresh regular file a planted link can't redirect (mimo writes
# auth.json IN PLACE, chmod 0600, no temp+rename --
# packages/shared/src/filesystem.ts:80 -- so a login would write THROUGH a
# link). There is no mimo shared-auth companion yet, hence no trusted
# identity-dir exception as in the opencode hook.
if [ -L "$cred" ]; then
  rm -f "$cred"
  echo "byre: removed a symlinked mimo credential ($cred); log in again to store a regular file." >&2
fi
# A static key in the environment makes the file login unnecessary: the
# models.dev catalog's env name for provider `xiaomi` (verified live).
[ -n "${XIAOMI_API_KEY:-}" ] && exit 0
# Already authenticated? There is no `login status` probe, so the guard is
# a shape sniff (the opencode/grok precedent): auth.json is a provider-keyed
# map whose entries all carry a "type" member ({"type":"api","key":...}),
# and a complete JSON.stringify'd store ends in "}" -- the trailing-brace
# check catches the truncation an interrupted in-place write can leave; an
# empty store ({}) fails the "type" test. Not caught: a revoked key or an
# empty balance -- those surface at use time.
if [ -s "$cred" ] && grep -q '"type"' "$cred" 2>/dev/null \
  && [ "$(tail -c 1 "$cred" 2>/dev/null)" = "}" ]; then
  exit 0
fi

# Interactive only: the paste flow needs a terminal, and a non-interactive
# launch must not sit blocked on stdin until the timeout. Placed after the
# symlink sweep so a planted link is dropped even on a headless launch.
[ -t 0 ] || exit 0

# Clean skip on Ctrl-C: exit 0 so no signal-death propagates toward the
# launcher -- the box proceeds to the agent regardless.
trap 'echo; echo "byre: mimo login skipped. To do it later, open another terminal and run '\''byre shell'\'', then '\''mimo auth login -p xiaomi'\''."; exit 0' INT

echo ""
echo "=== byre: first-run MiMo Code login ==="
echo "Open the URL below, sign in to the Xiaomi MiMo platform, and paste the code back here."
echo "Stored per-project, survives rebuilds. Ctrl-C to skip (or set XIAOMI_API_KEY instead)."
echo "Note: the free MiMo channel has ended; the account needs a balance (otherwise requests answer 402)."
echo ""
# Bound the wait; --foreground keeps mimo in the terminal's foreground
# process group so Ctrl-C reaches it immediately.
TO=""
command -v timeout >/dev/null 2>&1 && TO="timeout --foreground 600"
$TO mimo auth login -p xiaomi \
  || echo "byre: mimo login didn't complete. To do it later, open another terminal and run 'byre shell', then 'mimo auth login -p xiaomi'." >&2
exit 0
