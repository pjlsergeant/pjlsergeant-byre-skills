#!/bin/sh
# claude-skills-pocock firstrun hook — runs as the dev user, every launch, BEFORE
# the agent starts, with the .claude state volume already mounted. Syncs the
# Claude Code skills baked into this image (/etc/byre/claude-skills-pocock/<name>/)
# into the agent's personal skills dir inside that volume ($CLAUDE_CONFIG_DIR/skills).
# Idempotent and best-effort: it must NEVER block the launch.
#
# Unlike the sibling `claude-skills` bundle (which ships a single SKILL.md per
# skill), these upstream skills carry supporting files (references, scripts) beside
# SKILL.md, so this hook syncs each skill's WHOLE directory tree, not just SKILL.md.
#
# Relies on the base `claude` skill: if CLAUDE_CONFIG_DIR is unset (claude isn't
# the agent on this box), there is nowhere to install to, so no-op.
[ -n "${CLAUDE_CONFIG_DIR:-}" ] || exit 0
src=/etc/byre/claude-skills-pocock
[ -d "$src" ] || exit 0
dest="$CLAUDE_CONFIG_DIR/skills"
mkdir -p "$dest" || exit 0

for dir in "$src"/*/; do
  [ -f "${dir}SKILL.md" ] || continue
  name=$(basename "$dir")
  d="$dest/$name"
  # Drop a symlink or non-dir a prior run (or an attacker) may have planted, so we
  # own a real directory and writes cannot be redirected elsewhere.
  if [ -L "$d" ] || { [ -e "$d" ] && [ ! -d "$d" ]; }; then rm -rf "$d"; fi
  # Stage a fresh copy from the image (the source of truth), then swap it into
  # place — never write THROUGH whatever is already there. We replace the whole
  # skill dir each launch so stale files from a removed skill version don't linger.
  tmp="$dest/.$name.tmp.$$"
  rm -rf "$tmp"
  mkdir -p "$tmp" || continue
  if cp -R "$dir." "$tmp/" 2>/dev/null; then
    rm -rf "$d" && mv "$tmp" "$d" 2>/dev/null || rm -rf "$tmp"
  else
    rm -rf "$tmp"
  fi
done
exit 0
