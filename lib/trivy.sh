# Trivy (AB_TRIVY=1): the scanner in the image (WITH_TRIVY=1 build argument)
# and its vulnerability database in the ab-trivy volume.
#
# The database comes as an OCI image from mirror.gcr.io or ghcr.io. The
# session cannot reach those (a registry also takes uploads): like the agent
# update, a short-lived container with internet access and no repository
# fetches it, at most every UPDATE_EVERY seconds (AB_UPDATE=1 forces it),
# with telemetry off: that container is not behind squid. The
# session gets the volume read-only, with every download switched off; the
# misconfiguration checks are the ones built into the binary, and the Java
# database is not used.
#
# Sourced by run.sh. Provides trivy_update and TRIVY_ARGS (session arguments).

TRIVY_CACHE=/home/node/.cache/trivy

trivy_update() {
  local stamp="${XDG_CACHE_HOME:-$HOME/.cache}/agentbox.trivy.updated"
  TRIVY_ARGS=()
  [[ "${AB_TRIVY:-}" == 1 ]] || return 0
  if [[ "${AB_UPDATE:-}" == 1 || ! -f "$stamp" ]] \
     || (( $(date +%s) - $(stat -c %Y "$stamp") > UPDATE_EVERY )); then
    echo "agentbox: updating the Trivy database..." >&2
    if podman run --rm --network ab-egress --userns="$USERNS" \
         -v ab-trivy:"$TRIVY_CACHE" --entrypoint trivy "$IMAGE" \
         image --download-db-only --no-progress --cache-dir "$TRIVY_CACHE" \
               --disable-telemetry --skip-version-check >&2; then
      mkdir -p "$(dirname "$stamp")"
      touch "$stamp"
    elif ! podman run --rm --network none --entrypoint sh "$IMAGE" -c 'command -v trivy' >/dev/null 2>&1; then
      echo "error: AB_TRIVY=1, but the agentbox image has no Trivy; rebuild it: AB_UPGRADE=1 agentbox" >&2
      exit 1
    else
      echo "agentbox: warning: Trivy database update failed, using the one there is" >&2
    fi
  fi
  # memory: no scan cache written into the read-only volume.
  TRIVY_ARGS=(
    -v "ab-trivy:$TRIVY_CACHE:ro"
    -e "TRIVY_CACHE_DIR=$TRIVY_CACHE"
    -e TRIVY_CACHE_BACKEND=memory
    -e TRIVY_SKIP_DB_UPDATE=true
    -e TRIVY_SKIP_JAVA_DB_UPDATE=true
    -e TRIVY_SKIP_CHECK_UPDATE=true
    -e TRIVY_SKIP_VERSION_CHECK=true
    -e TRIVY_SKIP_VEX_REPO_UPDATE=true
    -e TRIVY_DISABLE_TELEMETRY=true
    -e TRIVY_DISABLE_VEX_NOTICE=true
  )
}
