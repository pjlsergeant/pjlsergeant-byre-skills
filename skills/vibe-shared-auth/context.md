## Shared Mistral API key (vibe-shared-auth)

This box can authenticate the `vibe` command from a machine-wide key stored at
`~/.byre-identity/vibe/api-key`. The first launch with this companion enabled
shares the login this project already has: the key `vibe-login` saved in
`~/.vibe/.env` is copied into that file (promoted), and every opted-in project
then uses it. On a fresh machine with no login, an interactive launch asks for
a key; or sign in once with `vibe-login`, and the next launch shares that
login. That holds only while no shared key exists: a fresh `vibe-login` alone
never replaces an existing shared key, which keeps winning and shadows the new
local login (remove the shared file first, below). If two projects launch at
once with different logins, the first to share wins and the other uses it.
The key is exported as `MISTRAL_API_KEY` at launch and in login shells, but
only when the box does not already have an explicit per-project
`MISTRAL_API_KEY`, which still wins. Vibe prefers that environment value over
a key saved in this project's `~/.vibe/.env`.

A wrong or revoked key shows up as `Error: Invalid API key (from env var
MISTRAL_API_KEY)`. To rotate the shared key, run
`rm ~/.byre-identity/vibe/api-key` from `byre shell`, then exit that shell
immediately: its environment still contains the old exported value. Relaunch
byre and enter the replacement at the first-run prompt. The later environment
hook loads that new file for the agent launched in the same run. A relaunch
promotes a `~/.vibe/.env` login again if one exists, so to rotate also remove
the stale `MISTRAL_API_KEY` line from `~/.vibe/.env` (or first log in again
with `vibe-login` after removing the shared file, whose new key is then
promoted).

The shared file must remain a non-symlink regular file with mode `0600`, and
neither `~/.byre-identity` nor its `vibe/` directory may be (or pass through)
a symlink: a key reached that way is neither exported nor overwritten. This
procedure changes the machine-scoped key used by every opted-in project. If the
project explicitly supplies `MISTRAL_API_KEY`, the prompt is skipped and that
value takes precedence; rotate it at its project or host source instead.
