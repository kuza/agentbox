# Local services (AB_SERVICES): your own dev containers (databases, queues)
# the agent may use, e.g. "redis rabbitmq postgres". Each is attached to
# ab-services, a separate --internal network the session joins, and is
# reachable by container name (redis:6379), and started if it is stopped.
# Kept apart from ab-internal so these containers cannot reach the MCP/LLM
# sidecars, and the session gets no route to the host or the internet through
# them. Attachment is persistent;
# undo with: podman network disconnect ab-services <name>.
# Only rootless Podman containers of the same user can be attached.
# Sets SERVICE_NET, the session's extra network arguments.

services_attach() {
  local services svc mode
  SERVICE_NET=()
  if [[ -n "${AB_SERVICES:-}" ]]; then
    podman network exists ab-services || podman network create --internal ab-services >/dev/null
    read -ra services <<< "${AB_SERVICES//,/ }"
    for svc in "${services[@]}"; do
      if ! podman container exists "$svc"; then
        echo "agentbox: warning: AB_SERVICES: no container '$svc' (rootless podman of this user), skipped" >&2
        continue
      fi
      # Containers started without --network use pasta/slirp4netns (rootless
      # default) and cannot join any network later; they must be recreated
      # on a bridge network (README, Local services).
      mode="$(podman inspect --format '{{.HostConfig.NetworkMode}}' "$svc")"
      if [[ "$mode" == pasta* || "$mode" == slirp4netns* || "$mode" == host || "$mode" == none ]]; then
        echo "agentbox: warning: '$svc' uses network mode '$mode' and cannot be attached;" \
             "recreate it with --network podman (see README, Local services)" >&2
        continue
      fi
      if ! podman inspect --format '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}' "$svc" \
           | grep -qw ab-services; then
        podman network connect ab-services "$svc" \
          || echo "agentbox: warning: could not attach '$svc' to ab-services" >&2
      fi
      # A stopped service is started; it is left running after the session.
      if [[ "$(podman inspect --format '{{.State.Running}}' "$svc")" != true ]]; then
        echo "agentbox: starting '$svc'" >&2
        podman start "$svc" >/dev/null \
          || echo "agentbox: warning: could not start '$svc'" >&2
      fi
    done
    SERVICE_NET=(--network ab-services)
  fi
}
