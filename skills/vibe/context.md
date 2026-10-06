# Mistral Vibe (byre skill)

`vibe` is Mistral Vibe, Mistral AI's Apache-2.0 terminal coding agent,
pinned at 2.26.0 as the self-contained release bundle in `/opt/vibe`
(`/usr/local/bin/vibe` links to it). A box selects it as its agent with
`agent = "pjlsergeant/vibe"`; the agent command is `byre-vibe-launch --trust
--auto-approve`, which injects byre's MCP servers through `VIBE_MCP_SERVERS`
and this context as an `AGENTS.md` in an `--add-dir` directory, then execs
`vibe`. `--trust` trusts the working directory for that run only (nothing
is written to `trusted_folders.toml`); `--auto-approve` approves every tool
call. The model is the config's `active_model`, an alias from `[[models]]`
in `~/.vibe/config.toml` (Mistral Medium 3.5 by default); vibe has no
`--model` flag, but `VIBE_ACTIVE_MODEL=<alias>` overrides it per run.

## Auth

- Login: the user runs `vibe-login` in `byre shell` (it wraps
  `vibe --setup`; it needs a terminal, so never from a tool call). It is
  Vibe's own setup screen: "Launch browser" shows a Mistral sign-in URL to
  open on the host (vibe polls until it is done), or "Use an API key"
  takes a pasted key (console.mistral.ai). Either way the result is a
  Mistral API key in `~/.vibe/.env` (per project; there is no keyring in a
  box). A fresh interactive box offers it once at first run (Ctrl-C skips).
- Or a static key: `MISTRAL_API_KEY` (a credential: `byre credentials set`
  or `env_from_host`, never a baked `[env]` literal). A non-empty value in
  the environment wins over `~/.vibe/.env`, and makes the first-run login
  stand down (a `byre credentials` value only on byre 1.12+; older byre
  delivered those after the first-run hooks).
- `pjlsergeant/vibe-shared-auth`, if enabled, stores one key machine-wide
  and exports it as `MISTRAL_API_KEY` in every opted-in project (unless the
  project sets its own).
- No key at all: `vibe -p` fails with "Missing MISTRAL_API_KEY environment
  variable for mistral provider"; a bad one with "Invalid API key". 402 and
  429 are billing/quota answers, not key problems; 429 and 5xx are retried
  for up to `api_retry_max_elapsed_time` (300 s) before vibe gives up.
- `~/.vibe/.env` must be a regular file: the login hook and `vibe-login`
  refuse to touch a symlink (or any other non-file) there and say so.

## State and isolation

`~/.vibe` (`VIBE_HOME`) is the per-project `.vibe` state volume -- it
survives rebuilds: `.env` (the login's key), `config.toml`, `logs/`
(`vibe.log`, sessions under `logs/session/`), `trusted_folders.toml`,
`agents/`, `prompts/`, `skills/`. `~/.vibe/AGENTS.md` is the user's own
file; byre never writes it (its context rides `--add-dir`, a launch-owned
`$TMPDIR/byre-vibe-context/AGENTS.md`, falling back to the baked
`/etc/byre/vibe-context`). Don't set `VIBE_HOME` in `[env]`: vibe would
move, the volume would not, and the login would stop surviving rebuilds.

## Environment set by the skill

- `VIBE_ENABLE_TELEMETRY=false` -- telemetry and Sentry crash reports,
  both default ON upstream.
- `VIBE_ENABLE_UPDATE_CHECKS=false` -- the image pins the version.
- `VIBE_EXPERIMENTS__ENABLE=false` -- GrowthBook remote feature flags.
- `VIBE_INCLUDE_COMMIT_SIGNATURE=false` -- no "Co-Authored-By: Mistral
  Vibe" trailer on commits vibe makes.
- `TERM=xterm-256color` -- for the Textual TUI.

Any Vibe config field can be set as `VIBE_<FIELD>` (nested with `__`,
JSON for lists); the environment layer sits ABOVE `~/.vibe/config.toml`,
so for the fields above editing config.toml changes nothing -- override
the env var instead.

## MCP servers

byre's MCP servers reach vibe through `VIBE_MCP_SERVERS` (merged by name
with any already set, and with `mcp_servers` in config.toml; byre's entry
wins a name clash). Unlike claude, a vibe stdio MCP server does NOT inherit
the agent's environment: it gets a minimal one (HOME, PATH, SHELL, TERM)
plus only the variables its byre declaration lists (`env = [...]` in the
skill's or config's `[[mcp]]` block), and only those that are set. A
server that needs another variable must declare it. A stdio server that
fails to start is reported nowhere -- no stderr, no log line -- and the
session simply runs without its tools; run its command by hand in
`byre shell` to see why.

## Network

Open: `api.mistral.ai` (inference; also a connectors catalog request at
startup), `console.mistral.ai` (browser sign-in) and `chat.mistral.ai`
(the organisation's managed Vibe config, fetched at every session start
when a Mistral key is set -- closed, centrally enforced settings would be
silently skipped and every launch would stall up to ~6 s on retries; Vibe
Code / teleport, which are opt-in, use it too). Offered, closed by
default: `experiments.mistral.services` (feature flags, also off by env)
and `pypi.org` (update checks, also off by env). A `[[providers]]` entry
in config.toml pointing elsewhere needs its host added to the project
config's `egress`.

## As a reviewer

With the codereview skill installed, `byre-codereview --reviewer vibe`
asks vibe for the second opinion: Mistral's models are a different family
from claude/codex/grok/GLM/MiMo, so it is a genuine second opinion. Pin a
model with `--reviewer vibe:<alias>`, where `<alias>` is a `[[models]]`
alias in this box's `~/.vibe/config.toml` (not a provider model id). That
config can point an alias at any OpenAI-compatible endpoint, so check it
when independence matters. The reviewer runs without `--trust`, so a
repository's own `.vibe/` config, hooks and skills do not load into it —
unless the folder is persistently trusted in `~/.vibe/trusted_folders.toml`
(an interactive "trust" answer for it, or for a directory above it when
nothing nearer is marked untrusted: vibe takes the closest decision), which
the script warns about.
