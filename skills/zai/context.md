# Z.AI through Codex (byre skill)

`zai` launches the Codex CLI with an isolated configuration for Z.AI's GLM
Coding Plan. Use it anywhere you would use `codex`, including `zai exec ...`.
It requires `codex` on `PATH`; enable byre's built-in Codex skill alongside
this package when Codex is not already part of the box.

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
