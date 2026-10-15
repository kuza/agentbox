# Forwards (AB_FORWARD): TCP services outside the box, such as databases and
# queues on test servers: "db=db.test.example:5432 mq=mq.test.example:5672".
# Each target gets a sidecar running socat on the agentbox image, attached to
# ab-egress (the way out) and to an --internal network the session joins,
# where it answers to the target's name: the agent connects to db:5432.
#
#   config.env                        AB_FORWARD for every session, network
#                                     ab-forward, sidecars ab-fwd-<name>
#   <env dir>/<repo dir name>.conf    AB_FORWARD for that repo's sessions
#                                     only, network ab-fwd-<key>, sidecars
#                                     ab-fwd-<key>-<name>; <key> comes from
#                                     the repo's path
#
# A name may appear once across both lists and AB_SERVICES. A sidecar is
# recreated when its target or the agentbox image changes, and removed once
# it is no longer listed; a repo's sidecars only by a start in that repo.
#
# Sourced by run.sh. Provides forward_init, forward_start, forward_cleanup
# and FORWARD_NET (the session's network arguments), FORWARD_NAMES.

# Reads both lists and checks them. Run after the config passes, before
# anything starts.
forward_init() {
  local repo_conf entry name target seen=" " scope list entries services=" ${AB_SERVICES:-} "
  FWD_NAMES=(); FWD_TARGETS=(); FWD_SCOPES=()
  FORWARD_NAMES=(); FORWARD_NET=()
  FWD_KEY="$(printf '%s' "$REPO" | sha256sum | cut -c1-8)"
  repo_conf="${AB_ENV_DIR:-$USER_ENV_DIR}/$(basename "$REPO").conf"
  FWD_REPO_LIST=""
  if [[ -f "$repo_conf" ]]; then
    echo "agentbox: repo config $repo_conf" >&2
    # Its own AB_FORWARD, not the global one: read in a subshell.
    FWD_REPO_LIST="$(unset AB_FORWARD; load_config "$repo_conf" 1 AB_FORWARD; printf '%s' "${AB_FORWARD:-}")"
  fi
  for scope in global repo; do
    if [[ "$scope" == global ]]; then list="${AB_FORWARD:-}"; else list="$FWD_REPO_LIST"; fi
    read -ra entries <<< "${list//,/ }"
    for entry in ${entries[@]+"${entries[@]}"}; do
      name="${entry%%=*}"; target="${entry#*=}"
      if [[ "$entry" != *=* || ! "$name" =~ ^[a-z][a-z0-9-]*$ || "$name" == ab-* ]]; then
        echo "error: AB_FORWARD ($scope): '$entry': expected name=host:port, the name in lowercase letters, digits and hyphens, not starting with ab-" >&2
        exit 2
      fi
      if [[ "$target" != *:* || "$target" == .* ]]; then
        echo "error: AB_FORWARD ($scope): '$entry': the target must be host:port" >&2
        exit 2
      fi
      egress_check_host "$target" "AB_FORWARD ($scope)"
      if [[ "$seen" == *" $name "* ]]; then
        echo "error: AB_FORWARD: the name '$name' appears more than once (config.env and $repo_conf together)" >&2
        exit 2
      fi
      if [[ "${services//,/ }" == *" $name "* ]]; then
        echo "error: AB_FORWARD: '$name' is also in AB_SERVICES; the session could not tell them apart" >&2
        exit 2
      fi
      seen+="$name "
      FWD_NAMES+=("$name"); FWD_TARGETS+=("${target,,}"); FWD_SCOPES+=("$scope")
      FORWARD_NAMES+=("$name")
    done
  done
  [[ "$seen" == " " ]] && return 0
  [[ -n "${AB_FORWARD:-}" ]] && FORWARD_NET+=(--network ab-forward)
  [[ -n "$FWD_REPO_LIST" ]] && FORWARD_NET+=(--network "ab-fwd-$FWD_KEY")
  return 0
}

fwd_container() {  # <index>
  if [[ "${FWD_SCOPES[$1]}" == global ]]; then
    echo "ab-fwd-${FWD_NAMES[$1]}"
  else
    echo "ab-fwd-$FWD_KEY-${FWD_NAMES[$1]}"
  fi
}

fwd_label() {  # <index>: which start owns the sidecar
  if [[ "${FWD_SCOPES[$1]}" == global ]]; then echo global; else echo "repo-$FWD_KEY"; fi
}

# Creates the networks and starts the sidecars. Run once the image exists.
forward_start() {
  local i c net hash image_id socat_checked=""
  (( ${#FWD_NAMES[@]} )) || return 0
  image_id="$(podman image inspect -f '{{.Id}}' "$IMAGE")"
  for i in "${!FWD_NAMES[@]}"; do
    c="$(fwd_container "$i")"
    if [[ "${FWD_SCOPES[$i]}" == global ]]; then net=ab-forward; else net="ab-fwd-$FWD_KEY"; fi
    podman network exists "$net" || podman network create --internal "$net" >/dev/null
    hash="$(printf '%s\n' "${FWD_NAMES[$i]}" "${FWD_TARGETS[$i]}" "$image_id" | sha256sum | cut -c1-16)"
    if [[ "$(podman inspect -f '{{index .Config.Labels "agentbox.forward-config"}}' "$c" 2>/dev/null)" != "$hash" ]]; then
      podman rm -f -v "$c" >/dev/null 2>&1 || true
    fi
    # socat came into the image with this feature; an older image lacks it.
    if [[ -z "$socat_checked" && ( "${AB_RESTART:-}" == 1 \
          || "$(podman inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" != true ) ]]; then
      if ! podman run --rm --network none --entrypoint sh "$IMAGE" -c 'command -v socat' >/dev/null; then
        echo "error: AB_FORWARD needs socat, which the agentbox image lacks; rebuild it: AB_UPGRADE=1 ./run.sh" >&2
        exit 1
      fi
      socat_checked=1
    fi
    # Root inside the user namespace (your user on the host) only to bind
    # ports below 1024; no other capability, read-only.
    start_sidecar "$c" \
      --network ab-egress --network "$net:alias=${FWD_NAMES[$i]}" \
      --label "agentbox.forward=$(fwd_label "$i")" \
      --label "agentbox.forward-config=$hash" \
      --user=0 --cap-drop=ALL --cap-add=NET_BIND_SERVICE \
      --security-opt=no-new-privileges --read-only \
      --entrypoint=socat "$IMAGE" \
      "TCP-LISTEN:${FWD_TARGETS[$i]##*:},fork,reuseaddr" "TCP:${FWD_TARGETS[$i]}"
  done
}

# Removes forward sidecars that are no longer listed: the global ones, and
# this repo's. Other repos' sidecars are left to their own starts. A repo
# without forwards also loses its network, unless a session still uses it.
forward_cleanup() {
  local i label c wanted=" "
  for i in "${!FWD_NAMES[@]}"; do wanted+="$(fwd_container "$i") "; done
  for label in global "repo-$FWD_KEY"; do
    for c in $(podman ps -a --filter "label=agentbox.forward=$label" --format '{{.Names}}' | awk '{ print $1 }'); do
      [[ "$wanted" == *" $c "* ]] && continue
      podman rm -f -v "$c" >/dev/null && echo "agentbox: removed $c, no longer in AB_FORWARD" >&2
    done
  done
  if [[ -z "$FWD_REPO_LIST" ]] && podman network exists "ab-fwd-$FWD_KEY"; then
    podman network rm "ab-fwd-$FWD_KEY" >/dev/null 2>&1 || true
  fi
}
