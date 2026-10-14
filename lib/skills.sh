# Personal skills: one subdirectory per skill, each with a SKILL.md.
# Mounted read-only over the agent's skills directory so the agent cannot
# rewrite its own skills (they would otherwise persist in its home volume
# across sessions and repos). Project skills in <repo>/.claude/skills need
# nothing: the repo is mounted.
# Sets SKILLS_SRC (empty if there is no skills directory) and GRAPHIFY_PI.

skills_prepare() {
  local image_id graphify_tmp
  SKILLS_DIR="${AB_SKILLS_DIR:-$SCRIPT_DIR/skills}"

  # graphify skill, taken from the image so it always matches the graphify CLI
  # there: `graphify install` into a scratch home, then
  #   <skills>/graphify               Claude Code's variant (shared skills dir)
  #   vendor/graphify/pi/graphify     pi's variant, mounted over the shared one
  # Refreshed when the image changes (its ID is recorded next to the skill), so a
  # rebuild with a new GRAPHIFY_VERSION brings the matching skill. A
  # <skills>/graphify that agentbox did not install is left alone.
  GRAPHIFY_STAMP="$SKILLS_DIR/graphify/.agentbox-image"
  GRAPHIFY_PI="$SCRIPT_DIR/vendor/graphify/pi"
  image_id="$(podman image inspect -f '{{.Id}}' "$IMAGE")"
  if [[ -e "$SKILLS_DIR/graphify" && ! -f "$GRAPHIFY_STAMP" ]]; then
    echo "agentbox: warning: $SKILLS_DIR/graphify was not installed by agentbox; not updating it" >&2
  elif [[ "$(cat "$GRAPHIFY_STAMP" 2>/dev/null)" != "$image_id" || ! -d "$GRAPHIFY_PI/graphify" ]]; then
    graphify_tmp="$(mktemp -d)"
    if podman run --rm --network none --userns="$USERNS" -e HOME=/out \
         -v "$graphify_tmp:/out:z" --entrypoint sh "$IMAGE" -c \
         'cd / && graphify install --platform claude && graphify install --platform pi' >/dev/null 2>&1 \
       && [[ -f "$graphify_tmp/.claude/skills/graphify/SKILL.md" \
             && -f "$graphify_tmp/.pi/agent/skills/graphify/SKILL.md" ]]; then
      mkdir -p "$SKILLS_DIR" "$GRAPHIFY_PI"
      rm -rf -- "$SKILLS_DIR/graphify" "$GRAPHIFY_PI/graphify"
      cp -R -- "$graphify_tmp/.claude/skills/graphify" "$SKILLS_DIR/graphify"
      cp -R -- "$graphify_tmp/.pi/agent/skills/graphify" "$GRAPHIFY_PI/graphify"
      echo "$image_id" > "$GRAPHIFY_STAMP"
      echo "agentbox: installed the graphify skill $(cat "$SKILLS_DIR/graphify/.graphify_version" 2>/dev/null) from the image" >&2
    else
      echo "agentbox: warning: could not extract the graphify skill from the image" >&2
    fi
    rm -rf -- "$graphify_tmp"
  fi

  SKILLS_SRC=""
  if [[ -d "$SKILLS_DIR" ]]; then
    SKILLS_SRC="$(realpath -e -- "$SKILLS_DIR")"
  fi
}
