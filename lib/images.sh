# Images: building agentbox's own, and removing the versions a pull or a
# rebuild replaced. podman keeps a replaced image as "<none>", so every
# upgrade would otherwise leave gigabytes behind.
#
# Sourced by run.sh and check-updates.sh. Needs SCRIPT_DIR; building also
# IMAGE, IMG_SQUID and BUILD_ARGS.

RETIRED_IMAGES="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox/retired-images"

# The image is built from an empty context directory: the Containerfile
# copies nothing in, and the agentbox directory holds config.env, env/
# (passwords) and skills/, which a build has no reason to receive. A COPY
# added later fails instead of silently taking them along.
# --layers=false: no intermediate image per build step, which would stay
# behind after every rebuild; a failed build starts over from the beginning.
# Each image carries the label agentbox.build, a fingerprint of its
# Containerfile and build arguments; ensure_images rebuilds an image whose
# fingerprint is not the current one (a changed AB_TRIVY or AB_GO_VERSION, a
# release with a new Containerfile).
build_image() {  # [podman build options...]: the agentbox image
  build_local "$IMAGE" "$SCRIPT_DIR/Containerfile" "$(agentbox_fingerprint)" \
    "$@" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
}

build_squid_image() {  # [podman build options...]: the egress proxy
  build_local "$IMG_SQUID" "$SCRIPT_DIR/Containerfile.squid" "$(squid_fingerprint)" "$@"
}

build_local() {  # <image> <containerfile> <fingerprint> [podman build options...]
  local image="$1" file="$2" fp="$3" ctx rc=0
  shift 3
  ctx="$(mktemp -d)"
  podman build --layers=false "$@" --label "agentbox.build=$fp" -t "$image" -f "$file" "$ctx" || rc=$?
  rmdir -- "$ctx"
  return "$rc"
}

image_fingerprint() {  # <containerfile> [build arguments...]
  { cat -- "$1"; shift; printf '%s\n' "$@"; } | sha256sum | cut -c1-16
}
agentbox_fingerprint() {
  image_fingerprint "$SCRIPT_DIR/Containerfile" ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"}
}
squid_fingerprint() {
  image_fingerprint "$SCRIPT_DIR/Containerfile.squid"
}

# Builds the agentbox and squid images if missing or built from something
# else than now. The replaced image goes at images_cleanup.
ensure_images() {
  image_ensure "$IMAGE" "$(agentbox_fingerprint)" build_image
  image_ensure "$IMG_SQUID" "$(squid_fingerprint)" build_squid_image
}

image_ensure() {  # <image> <fingerprint> <build function>
  if ! podman image exists "$1"; then
    "$3"
  elif [[ -z "$(podman images -q --filter "reference=$1" --filter "label=agentbox.build=$2")" ]]; then
    echo "agentbox: $1 was built from another Containerfile or build settings; rebuilding..." >&2
    image_retire "$1"
    "$3"
  fi
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
