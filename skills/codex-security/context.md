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

## Known wart (v0.1.0)

Observed 2026-07-29: a scan can complete and then fail to save with
"scan-manifest.json: expected a regular file inside the scan directory",
leaving partial output in the scans dir (the error names the path).
Check that dir before assuming a failed scan produced nothing.
