# Images: building agentbox's own, and removing the versions a pull or a
# rebuild replaced. podman keeps a replaced image as "<none>", so every
# upgrade would otherwise leave gigabytes behind.
#
# Sourced by run.sh and check-updates.sh. Needs SCRIPT_DIR; build_image also
# IMAGE and BUILD_ARGS.

RETIRED_IMAGES="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/retired-images"

# The image is built from an empty context directory: the Containerfile
# copies nothing in, and the agentbox directory holds config.env, env/
# (passwords) and skills/, which a build has no reason to receive. A COPY
# added later fails instead of silently taking them along.
# --layers=false: no intermediate image per build step, which would stay
# behind after every rebuild; a failed build starts over from the beginning.
build_image() {  # [podman build options...]
  local ctx rc=0
  ctx="$(mktemp -d)"
  podman build --layers=false "$@" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
    -t "$IMAGE" -f "$SCRIPT_DIR/Containerfile" "$ctx" || rc=$?
  rmdir -- "$ctx"
  return "$rc"
}

# Call before a pull or build that may replace <image>: records its current
# ID for images_cleanup.
image_retire() {  # <image>
  local id
  id="$(podman image inspect -f '{{.Id}}' "$1" 2>/dev/null)" || return 0
  mkdir -p "$(dirname "$RETIRED_IMAGES")"
  printf '%s %s\n' "$1" "$id" >> "$RETIRED_IMAGES"
}

# Removes the recorded images that were replaced. Run after the sidecars are
# recreated. podman refuses to remove an image a container still uses (an
# open session on the old agentbox image); such an image stays recorded and
# goes on a later start. An image that was not replaced (the pull brought
# nothing new) is dropped from the list and kept.
images_cleanup() {
  local img id keep=()
  [[ -s "$RETIRED_IMAGES" ]] || return 0
  while read -r img id; do
    [[ -n "$id" ]] || continue
    [[ "$(podman image inspect -f '{{.Id}}' "$img" 2>/dev/null)" == "$id" ]] && continue
    podman image exists "$id" || continue
    podman rmi "$id" >/dev/null 2>&1 || keep+=("$img $id")
  done < "$RETIRED_IMAGES"
  if (( ${#keep[@]} )); then
    printf '%s\n' "${keep[@]}" > "$RETIRED_IMAGES"
  else
    : > "$RETIRED_IMAGES"
  fi
}
