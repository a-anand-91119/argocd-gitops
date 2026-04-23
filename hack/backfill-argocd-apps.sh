#!/usr/bin/env bash
#
# backfill-argocd-apps.sh
#
# Lineage:   docs/plans/argocd-app-of-apps.md §Phase 5 (lines 381-432) — source plan template.
# Purpose:   Generate ArgoCD child Application YAMLs for all 31 live apps
#            EXCEPT the 7-item SKIP set, emitting 24 manifests under $OUT_DIR.
#
# SKIP rationale:
#   - newt, valkey       : already adopted in Phase 3 Plan 02 (commit 0762ce1).
#   - mariadb-operator,  : already landed in Phase 3 Plan 02 (commit 0762ce1).
#     mariadb-mixpost,
#     mixpost
#   - root               : app-of-apps root; authored in Phase 2 (commit 0790126 / 0a324fd).
#   - stackgres          : Phase 6 hardening scope (pre-existing offender; do NOT absorb here).
#
# Re-run safety:
#   Idempotent. On every invocation:
#     - $OUT_DIR is created (mkdir -p) and all *.yml inside it removed before generation.
#     - Each per-app write is atomic per target file; no partial output accepted.
#   Running this script does NOT mutate the repository or the cluster. The
#   generated YAMLs are staged under /tmp and must be diff-gated separately
#   before any `cp` into zeus-k8s/argocd/applications/.
#
# NOT auto-copied into repo:
#   The `cp` step into zeus-k8s/argocd/applications/ is a separate, diff-gated
#   operation performed by Plan 02 (the atomic R1 gate). This script only
#   authors manifests in /tmp.
#
# yq version note:
#   Requires kislyuk yq v3.4.3 or compatible. We pass `-y -S` explicitly:
#     -y : emit YAML (v3.4.3 default is JSON, which breaks downstream awk filters)
#     -S : sort object keys alphabetically, matching the shape of newt.yml/valkey.yml.

set -euo pipefail

err() {
  echo "ERROR: $*" >&2
  exit 1
}

# -----------------------------------------------------------------------------
# WAVE table (verbatim from docs/plans/argocd-app-of-apps.md §Phase 5 lines 392-407).
# stackgres kept in the dict so a future un-SKIP never trips default-wave-0 fallback.
# -----------------------------------------------------------------------------
declare -A WAVE=(
  [sealed-secrets]=-30
  [namespaces]=-25
  [secrets]=-20
  [cnpg-operator]=-15
  [keda]=-15
  [stackgres]=-10
  [calico-system]=-10
  [calico-monitoring]=-10
  [metrics-server]=-10
  [cloudflare-tunnel]=-5
  [vault]=0
  [cnpg-image-catalogs]=5
  [postgres]=10
  [cnpg-timescaledb]=10
  [prometheus]=15
  [prometheus-kafka-exporter]=15
  [localstack]=15
  [kafka-ui]=20
  [cloudflare-ingress]=20
  [gitlab-runners-nyad]=25
  [gitlab-runners-saas-aa]=25
  [gitlab-runners-sass-nm]=25
  [asynchronous-http-server]=30
  [grpc-stats-aggregator]=30
  [ingresses]=35
)

# SKIP = phase-3-covered adoptions + phase-3-covered new services + root + phase-6 offender.
SKIP=(newt valkey mariadb-operator mariadb-mixpost mixpost root stackgres)

in_skip() {
  local needle="$1"
  local s
  for s in "${SKIP[@]}"; do
    [ "$s" = "$needle" ] && return 0
  done
  return 1
}

# -----------------------------------------------------------------------------
# Output dir (idempotent reset).
# -----------------------------------------------------------------------------
OUT_DIR="/tmp/argocd-backfill"
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR"/*.yml

# -----------------------------------------------------------------------------
# Per-app generation.
# -----------------------------------------------------------------------------
STRIP='del(.status, .metadata.uid, .metadata.resourceVersion, .metadata.generation, .metadata.creationTimestamp, .metadata.managedFields, .metadata.ownerReferences, .metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"])'

generated=0
for app in $(kubectl -n argocd get app -o jsonpath='{.items[*].metadata.name}'); do
  if in_skip "$app"; then
    continue
  fi

  wave="${WAVE[$app]:-0}"
  out="$OUT_DIR/$app.yml"

  # Pull live state, strip server fields, enforce YAML output + alphabetical key sort,
  # and inject finalizer + sync-wave annotation + managed-by label atop the result.
  kubectl -n argocd get app "$app" -o yaml \
    | yq "$STRIP" \
    | yq -y -S \
        --arg wave "$wave" \
        '.metadata.finalizers = ["resources-finalizer.argocd.argoproj.io"]
         | .metadata.annotations["argocd.argoproj.io/sync-wave"] = $wave
         | .metadata.labels["app.kubernetes.io/managed-by"] = "argocd-gitops-repo"' \
    > "$out"

  # Per-generation blocking guards.
  has_spec=$(yq -r '.spec != null' "$out")
  [ "$has_spec" = "true" ] || { echo "GUARD FAIL: $app (.spec is null)"; exit 1; }

  src_path=$(yq -r '.spec.source.path // ""' "$out")
  if [ -n "$src_path" ] && [ "$src_path" != "null" ]; then
    test -d "$src_path" || { echo "GUARD FAIL: $app (.spec.source.path '$src_path' missing in worktree)"; exit 1; }
  fi

  dest_ns=$(yq -r '.spec.destination.namespace // ""' "$out")
  if [ -z "$dest_ns" ] || [ "$dest_ns" = "null" ]; then
    echo "NOTE: $app has no .spec.destination.namespace (cluster-scoped aggregator — allowed)"
  fi

  generated=$((generated + 1))
done

echo "Wrote $(ls "$OUT_DIR"/*.yml | wc -l | tr -d ' ') manifests to $OUT_DIR (expected 24)"
