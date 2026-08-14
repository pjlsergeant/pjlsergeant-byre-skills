# Z.AI through Codex (byre skill)

`zai` launches the Codex CLI with an isolated configuration for Z.AI's GLM
Coding Plan. Use it anywhere you would use `codex`, including `zai exec ...`.
Byre's built-in Codex skill is mandatory for both command and agent use; it
supplies the executable and the launch adapter, not merely a `codex` on PATH.

The package is also a selectable byre agent. Use this project configuration:

```toml
agent = "pjlsergeant/zai"
skills = ["codex"]
```

The built-in Codex skill is an explicit prerequisite: it supplies the Codex
executable and byre's Codex launch adapter. The adapter preserves byre's MCP
and developer-context injection; `zai` supplies only the isolated home and
Z.AI provider configuration.

The prerequisite is byre's full Codex skill, so a fresh box also runs its
ordinary OpenAI device-login hook before launching Z.AI. That login is not used
by `zai`, which overrides `CODEX_HOME` for the agent process. Complete it if you
also want ordinary Codex in the box, or press Ctrl-C to skip it. The extra
`.codex` state volume and OpenAI egress declarations are accepted residuals of
reusing the built-in skill until byre offers an auth-free Codex runtime layer.

For a machine-wide API key shared across opted-in projects, install
`pjlsergeant/zai-shared-auth`; byre offers it as this agent's shared-auth
companion during onboarding.

Set `ZAI_API_KEY` to the key from Z.AI's API-key page. The key is read from the
environment for each request; it is never written into the image or Codex
configuration. In `byre.config`, the usual host-forwarding form is:

```toml
env_from_host = { ZAI_API_KEY = "env:ZAI_API_KEY" }
```

## Isolation

The launcher reuses the box's existing `codex` executable, deliberately leaves
`HOME` unchanged, and sets only its child Codex process's `CODEX_HOME` to
`/home/dev/.zai-codex-home`. That directory is
a dedicated per-project state volume containing Z.AI's config, sessions,
history, logs, and any other Codex state. Ordinary `codex` continues to use
its own `CODEX_HOME`; Claude, Grok, Gemini, OpenCode, and programs launched by
Codex continue to see the normal `/home/dev` home directory.

The first invocation seeds `config.toml` only when it is absent. You can edit
that isolated file or `models.json` to change the GLM model or other Codex
preferences; rebuilds do not overwrite them. The shipped catalog follows
Z.AI's Codex guide and defaults to `glm-5.3` at maximum reasoning effort over
Z.AI's OpenAI Responses endpoint.
