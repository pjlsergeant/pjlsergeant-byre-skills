# codex-security (byre skill)

`codex-security` (OpenAI's `@openai/codex-security`) is on PATH: scan a
repo for security vulnerabilities, validate candidate findings, patch
them, export SARIF/CSV/JSON. `codex-security --help` lists the verbs;
`--dry-run` on `scan` validates inputs (auth, python, target) for free.

## Auth: rides the codex login

No login of its own. It reads `auth.json` from `$CODEX_HOME` (the codex
skill's state volume), so the box's existing codex credential works
as-is -- check with `codex-security login status`; if codex is logged
in, so is this.

HAZARD -- credential copy vs rotation: each scan COPIES `auth.json` into
a throwaway isolated home and runs its bundled codex binary there. The
ChatGPT credential is a rotating OAuth token, so a refresh that fires
mid-scan lands in the throwaway copy and orphans the real `auth.json`'s
refresh chain: the next codex refresh fails with "refresh token already
used" (byre-codereview dying on 401s is the usual symptom). Low
probability per run, higher on long scans. Recovery is a fresh
`codex login --device-auth` (plain `codex login` needs a browser the box
doesn't have). That form always works wherever codex itself is present,
which is the only thing this skill can promise: it is a companion to
`codex` alone. Boxes that ALSO run codereview 1.1.0 or newer get a
`codex-login` helper wrapping exactly that command -- but packages are
pinned independently, so check it is on PATH before reaching for it
rather than assuming. In a shared-auth box the brick hits every box
sharing the credential, same remedy.

## Sandbox: what this skill turns off, and what the host must provide

The scan agent runs every command inside bubblewrap, which needs
unprivileged user namespaces. Docker's defaults block that twice over --
the seccomp filter refuses creating the namespace, and the docker-default
AppArmor profile denies the mounts bwrap performs next -- so since 1.1.0
this skill ships `run_args`:

    --security-opt seccomp=unconfined --security-opt apparmor=unconfined

**This removes the box's syscall filter and LSM confinement entirely.**
What remains of the container boundary is namespaces, capabilities,
mounts, and the runtime itself. Treat the box accordingly: mount nothing
into it you wouldn't hand to the scan agent -- no docker socket, no broad
host directories, no credentials beyond what the scan needs. byre's grant
review shows the raw flags at enable time and `byre status` degrades the
box's claims while they're live; that is correct, not a bug.

One prerequisite the skill cannot ship (Ubuntu 24.04+ hosts): the flags
make box processes unconfined, and `kernel.apparmor_restrict_unprivileged_userns=1`
(the Ubuntu default) cripples user namespaces for exactly those -- scans
die at `uid_map: Operation not permitted`. The HOST must set it to 0:

    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
    echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-userns.conf

(Recipe verified end-to-end 2026-07-30: default box -> userns blocked by
seccomp; seccomp off alone -> bwrap's mounts blocked by docker-default;
both flags + host sysctl 0 -> full bwrap pattern works.)

Probe before spending: `codex sandbox true` exercises the whole stack in
milliseconds for $0. If it fails, a scan will burn ~$1/2min producing an
empty directory and a misleading save error (see the wart below).

## Cost: real money per scan -- always cap it

A standard-mode scan of a five-line toy repo cost ~$1.60 (measured
2026-07-29; defaults were gpt-5.6-sol at xhigh reasoning). Repo-sized
scans cost accordingly. Always pass `--max-cost <USD>`, and prefer
`--diff` / `--working-tree` / `--path` scoping over whole-repo scans
while iterating.

## State

Scan history persists under `$CODEX_HOME/state/plugins/codex-security/`
-- inside the codex state volume, so it survives rebuilds with no extra
volume.

## Egress

Inference and auth ride the codex skill's grants. `bulk-scan`'s GitHub
repository discovery additionally needs `api.github.com` -- grant it in
the box config if you use that verb.

## Known wart (v0.1.x)

A scan can appear to complete and then fail to save with
"scan-manifest.json: expected a regular file inside the scan directory".
Root cause (openai/codex-security#20): when the bwrap sandbox cannot
start, every agent command fails, the agent writes no artifacts, and
finalization surfaces this error anyway -- after the scan's full cost in
time and tokens. If you hit it with an empty scans dir, suspect the
sandbox first: run `codex sandbox true` and re-check the requirements in
the Sandbox section above.
