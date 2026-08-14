## Shared Z.AI API key (zai-shared-auth)

This box can authenticate the `zai` command from a machine-wide key stored at
`~/.byre-identity/zai/api-key`. The key is exported as `ZAI_API_KEY` at launch
and in login shells, but only when the box does not already have an explicit
per-project `ZAI_API_KEY`.

To rotate the shared key, replace that file from `byre shell` and relaunch the
box. Keep mode `0600`. Removing it makes boxes fall back to their own configured
key (or fail with Codex's missing-environment-variable message).
