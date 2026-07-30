# sudo

This box grants the `dev` user passwordless sudo: `sudo <cmd>` works, no
password, full root inside the container. Use it for what the unprivileged
user can't do — installing apt packages mid-session, editing system config,
reading root-owned files.

Two notes:

- Hand-installed packages die with the container. If you find yourself
  sudo-installing the same tool twice, it belongs in the box config (`apt`
  or a skill) instead.
- Root in the container is still the container: it grants nothing on the
  host beyond what the box's mounts and network already allow.
