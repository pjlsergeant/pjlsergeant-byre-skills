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

- Paste-code login: `byre shell`, then `mimo auth login -p xiaomi`. It
  prints a `platform.xiaomimimo.com/authorize` URL; open it on the host,
  sign in, paste the code back. A fresh interactive box offers this once at
  first run (Ctrl-C skips). The key lands in
  `~/.local/share/mimocode/auth.json`.
- Or a static key: `XIAOMI_API_KEY` (a credential: `byre credentials set`
  or `env_from_host`, never a baked `[env]` literal). Set, it makes the
  first-run login stand down.
- The free anonymous "MiMo Auto" channel is gone: `mimo run` then prints
  "MiMo free API service has ended..." and still exits 0. An account with
  no balance answers 402 "Insufficient account balance", also exit 0 --
  check stderr, not just the exit code, before trusting a `mimo run`.

## State and isolation

Data (auth.json, mimocode.db sessions, memory, logs) lives at
`~/.local/share/mimocode`, the per-project `.mimocode` state volume -- it
survives rebuilds. Config (`~/.config/mimocode`), cache and
`~/.local/state/mimocode` are image-layer and reset on rebuild. Don't set
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
`models.dev` (model catalog). Offered, closed by default:
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
pin it: `--reviewer mimo:<provider/model>`.
