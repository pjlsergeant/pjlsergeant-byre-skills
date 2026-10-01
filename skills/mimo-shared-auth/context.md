## Shared Xiaomi MiMo key and model (mimo-shared-auth)

This box can authenticate the `mimo` command from a machine-wide key stored at
`~/.byre-identity/mimo/api-key`, and pick its default model from
`~/.byre-identity/mimo/model`. They are exported as `XIAOMI_API_KEY` and
`MIMO_MODEL` at launch and in login shells. The shared key is exported unless
the project sets `XIAOMI_API_KEY`; the shared model only alongside the shared
key (a project that brings its own key gets detection, or its own
`MIMO_MODEL`), and a project `MIMO_MODEL` always wins.

A Token Plan key (it starts `tp-`) works only with a model on its regional
provider, `xiaomi-token-plan-{cn,ams,sgp}/<model>`; with mimo's default
`xiaomi/*` model a perfectly valid key is refused with 401 "Invalid API Key".
When such a key is pasted, the first-run prompt detects its region (with
`byre-mimo-model`, from the mimo skill) and offers the result, e.g.
`xiaomi-token-plan-sgp/mimo-v2.6-pro`, as the Enter default; that is what
gets stored. Even with no stored model, the mimo launcher detects the region
itself, so the model file is an override, not a requirement. A 401 with a
good key means the stored model (or `MIMO_MODEL`) names the wrong provider:
`env -u MIMO_MODEL byre-mimo-model --no-cache` shows what detection picks.

To fix only the model of a Token Plan key that 401s, run
`rm ~/.byre-identity/mimo/model` from `byre shell`: the next launch keeps the
stored key and prompts for the model alone, with the detected one as the
Enter default. A `tp-` key with no stored model is asked for one at each
interactive launch; a platform key is not (an empty model is valid for it),
so to change its model, rotate the key or set `MIMO_MODEL`.

To rotate the shared key, run `rm ~/.byre-identity/mimo/api-key`, which
re-prompts for both (the stored model is offered as the Enter default unless
you remove it too). After either `rm`, exit that shell immediately, since its
environment still holds the old values, then relaunch byre and answer the
first-run prompt; the later environment hook loads the new files for the
agent launched in the same run.

The shared files must remain non-symlink regular files with mode `0600`. This
procedure changes the machine-scoped key and model used by every opted-in
project. If the project explicitly supplies `XIAOMI_API_KEY`, the prompt is
skipped and that value takes precedence; rotate it at its project or host
source instead.
