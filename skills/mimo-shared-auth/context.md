## Shared MiMo Code login (mimo-shared-auth)

This box's mimo login is machine-wide: `~/.local/share/mimocode/auth.json` is
a symlink to `~/.byre-identity/mimo/auth.json`, one file shared by every
project on this machine that enables mimo-shared-auth. A launch hook
re-asserts the link every time (a dangling link just means nobody has logged
in yet); an existing per-project login is promoted to the shared file when
there is none yet, and a local copy that forked off it is replaced by it.

So the first login in any box logs in every box: run `mimo-login` (it wraps
`mimo auth login -p xiaomi`) in `byre shell`, open the URL it prints in a
browser on the host, authorize, and paste the code back. mimo writes through
the link. `mimo auth whoami` shows the shared login; `mimo auth logout`
removes it from the shared file, which logs every box out.

Only API-key-style entries are meant to be shared: the Xiaomi login stores
one, as does any plain API-key login. An OAuth entry (e.g. ChatGPT through mimo's
generic login) uses a refresh token that boxes race on; the hook warns if
one is in the shared file and leaves it alone. The file holds every
provider's credential, so all of them are shared. The hook refuses to assert
the link (and touches nothing) when the shared path is a symlink or not a
regular file, or the per-project auth.json is not a file or a link. It
needs `pjlsergeant/mimo` 1.2.0+ (whose login hook trusts the shared link);
with an older mimo skill it warns and asserts nothing until that is
upgraded and the box rebuilt.

`~/.byre-identity/mimo/api-key` and `model` are left over from
mimo-shared-auth 1.0, which asked for a pasted key. Nothing reads them; the
hook prints a notice while they exist. Remove them with
`rm ~/.byre-identity/mimo/api-key ~/.byre-identity/mimo/model`.

A project `XIAOMI_API_KEY` is a separate, env-only credential (per project,
not shared). It is a secret: forward it with `env_from_host` (never `[env]`).
Any `XIAOMI_API_KEY` in the box env (env_from_host, or `byre credentials` on
byre 1.12+; older byre exported those after the first-run hooks), or a
`MIMO_MODEL` on another provider, stops the first-run xiaomi login from
being offered. With both present, mimo merges
the env key first and auth.json over it, so for the `xiaomi` provider the
shared login's key wins; a Token Plan (`tp-`) env key is still used, because
`byre-mimo-model` routes it to its regional `xiaomi-token-plan-*` provider,
which the login does not cover.
