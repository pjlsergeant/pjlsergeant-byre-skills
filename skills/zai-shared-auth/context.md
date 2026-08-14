## Shared Z.AI API key (zai-shared-auth)

This box can authenticate the `zai` command from a machine-wide key stored at
`~/.byre-identity/zai/api-key`. The key is exported as `ZAI_API_KEY` at launch
and in login shells, but only when the box does not already have an explicit
per-project `ZAI_API_KEY`.

An expired or incorrect key can misleadingly appear as five Codex reconnects
followed by `stream closed before response.completed`: the Z.AI Responses
endpoint may return a JSON `{"code":401,...}` body where Codex expects an SSE
stream. To rotate the shared key, run
`rm ~/.byre-identity/zai/api-key` from `byre shell`, then exit that shell
immediately: its environment still contains the old exported value. Relaunch
byre and enter the replacement at the first-run prompt. The later environment
hook loads that new file for the agent launched in the same run.

The shared file must remain a non-symlink regular file with mode `0600`. This
procedure changes the machine-scoped key used by every opted-in project. If the
project explicitly supplies `ZAI_API_KEY`, the prompt is skipped and that value
takes precedence; rotate it at its project or host source instead.
