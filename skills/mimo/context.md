# MiMo Code (byre skill)

`mimo` is MiMo Code, Xiaomi's MIT-licensed terminal coding agent (a fork of
OpenCode; also subject to upstream's USE_RESTRICTIONS.md), pinned at 0.1.15
as a standalone binary at `/usr/local/bin/mimo`. A box selects it as its
agent with `agent = "pjlsergeant/mimo"`; the agent command is
`byre-mimo-launch`, which injects byre's MCP servers and this context through
`MIMOCODE_CONFIG_CONTENT` (merged over the user's own config, never
replacing it) and execs `mimo`. `mimo models xiaomi` lists the models
(default family `xiaomi/mimo-v2.6-pro` etc.).

## Auth

- Login: the user runs `mimo-login` in `byre shell` (it wraps
  `mimo auth login -p xiaomi`; it needs a terminal, so never from a tool
  call). It prints a `platform.xiaomimimo.com/authorize` URL; they open it
  on the host, authorize, and paste the code back. Platform and Token Plan
  accounts both log in this way, and a fresh interactive box offers it once
  at first run (Ctrl-C skips). The result lands in
  `~/.local/share/mimocode/auth.json` (per project), or machine-wide with
  `pjlsergeant/mimo-shared-auth`. `mimo auth whoami` shows the login status.
  A Token Plan login already carries its regional endpoint (auth.json
  `metadata.base_url`, e.g. `https://token-plan-sgp.xiaomimimo.com/v1`,
  verified live 2026-10-02; MiMo-Code plugin/mimo.ts `auth.loader` applies
  it as provider `xiaomi`'s baseURL), so a login needs no region routing:
  `byre-mimo-model` serves only env `XIAOMI_API_KEY` keys.
- Or a static key: `XIAOMI_API_KEY` (a credential: `byre credentials set`
  or `env_from_host`, never a baked `[env]` literal). An `env_from_host`
  key makes the first-run login stand down.
- Token Plan keys (prefix `tp-`) work only on their regional provider,
  `xiaomi-token-plan-cn`, `-ams` or `-sgp` (they read `XIAOMI_API_KEY`
  too); on the default `xiaomi` provider a valid `tp-` key answers 401
  "Invalid API Key". This needs no configuration: the launch adapter asks
  `byre-mimo-model`, which probes the three regions with the key once,
  picks the one that accepts it (model `mimo-v2.6-pro` when listed), and
  caches the answer in `~/.local/share/mimocode/byre-token-plan` (key id
  hash and region, never the key; per project, survives rebuilds). Run
  `byre-mimo-model` to see what this box will run (nothing printed = mimo's
  own default); `--no-cache` re-probes and says why on failure. A `tp-` key
  that still 401s means detection failed -- usually a bad key.
- `MIMO_MODEL` (`provider/model`, a plain non-secret env value) is an
  optional override of that choice; the adapter folds the resolved model
  into `MIMOCODE_CONFIG_CONTENT` as `model`, over any pre-set value there
  and over `~/.config/mimocode/mimocode.jsonc` (image-layer: edits there
  reset on rebuild). It is a default: `-m` beats it, and so does a model
  you last picked in the TUI, until the next rebuild. A malformed value is
  warned about and ignored. An id mimo doesn't list falls back to mimo's
  default with no error.
- `pjlsergeant/mimo-shared-auth`, if enabled, makes `auth.json` a symlink
  into `~/.byre-identity/mimo/`, so one login serves every opted-in
  project. It exports nothing; `XIAOMI_API_KEY` stays per project.
- The free anonymous "MiMo Auto" channel is gone: `mimo run` then prints
  "MiMo free API service has ended..." and still exits 0. An account with
  no balance answers 402 "Insufficient account balance", also exit 0 --
  check stderr, not just the exit code, before trusting a `mimo run`.

## State and isolation

Data (auth.json, mimocode.db sessions, memory, logs) lives at
`~/.local/share/mimocode`, the per-project `.mimocode` state volume -- it
survives rebuilds. Config (`~/.config/mimocode`), cache and
`~/.local/state/mimocode` are image-layer and reset on rebuild. The data
dir also holds byre's Token Plan region cache, `byre-token-plan`; deleting
it just makes the next launch re-probe. Don't set
`MIMOCODE_HOME` or `XDG_DATA_HOME`: mimo would move, the volume would not.

## Environment set by the skill

- `MIMOCODE_DISABLE_AUTOUPDATE=true` -- the image pins the version.
- `MIMOCODE_ENABLE_ANALYSIS=false` -- analytics default ON upstream
  (tracking.miui.com); off here.
- The agent launch also sets `MIMOCODE_DANGEROUSLY_SKIP_PERMISSIONS=1`
  (allow everything not explicitly denied; your config's denies still win)
  and passes `--trust` (no workspace-trust prompt).
- Never set `MIMOCODE_MIMO_ONLY` -- it disables env-key detection, so
  `XIAOMI_API_KEY` would stop working.

## Network

Open: `api.xiaomimimo.com` (inference), `platform.xiaomimimo.com` (login),
`models.dev` (model catalog), and the Token Plan inference hosts
`token-plan-{cn,ams,sgp}.xiaomimimo.com`. Offered, closed by default:
`mimo.xiaomi.com`. Closed on purpose: analytics, the self-update host, and
`registry.npmjs.org` -- mimo kicks a background `npm install
@mimo-ai/plugin` per config dir and logs a warning when it fails; that
warning is harmless. If the login result points at a different API host
(a custom `base_url`), add that host to the project config's `egress`.

## As a reviewer

With the codereview skill installed, `byre-codereview --reviewer mimo` asks
mimo for the second opinion. Running a `xiaomi/*` model it is a genuinely
different model family from claude/codex/grok/zai -- but mimo is a meta-CLI
like opencode, so the reviewer name says nothing about the model unless you
pin it: `--reviewer mimo:<provider/model>`. A bare `--reviewer mimo` runs
whatever `byre-mimo-model` resolves (`MIMO_MODEL`, or the detected Token
Plan region) and names it on the Running line, so a Token Plan box needs no
per-run pin.
