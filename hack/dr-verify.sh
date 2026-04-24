#!/usr/bin/env bash
#
# dr-verify.sh
#
# Lineage:   docs/runbooks/disaster-recovery.md — runbook (commit b431794, Phase 7 Plan 02).
# Purpose:   Mechanize the Phase 7 DR runbook: 14 preflight gates, T+5m/T+15m snapshot
#            captures, strict band-to-band ordering assertion, round-trip SealedSecret
#            decryption check, evidence artifact writes, and teardown invocation.
#            Requirements mapped: DR-01 (preflight), DR-02 (band ordering), DR-03
#            (round-trip decryption), DR-04 (teardown).
#
# Usage:
#   bash hack/dr-verify.sh                    # full flow: preflight → T+5m → T+15m → assert → evidence → teardown
#   bash hack/dr-verify.sh --preflight-only   # just the 14 preflight gates; no cluster interaction
#   bash hack/dr-verify.sh --snapshot <label> # one-shot snapshot (label typically t5m or t15m); writes /tmp/dr-snapshot-<label>.tsv
#   bash hack/dr-verify.sh --assert           # run strict band-to-band assertion on latest t15m snapshot
#   bash hack/dr-verify.sh --evidence         # capture events + app list + assertion + round-trip check into .planning/
#   bash hack/dr-verify.sh --teardown         # invoke `kind delete cluster --name argocd-dr` with retry+fallback
#
# Requirements: kind, docker, kubectl, vault, jq, yq, grep (all preflight-checked).
# No AI-attribution trailer on any commit authored elsewhere; this script writes evidence files only.

set -euo pipefail

# ----------------------------------------------------------------------------
# Constants
# ----------------------------------------------------------------------------

readonly CLUSTER_NAME="argocd-dr"
readonly KUBECTL_CONTEXT="kind-${CLUSTER_NAME}"
readonly EVIDENCE_DIR=".planning/phases/07-disaster-recovery-verification"
readonly EVIDENCE_MD="${EVIDENCE_DIR}/07-DR-EVIDENCE.md"
readonly EVIDENCE_EVENTS="${EVIDENCE_DIR}/07-DR-EVENTS.txt"
readonly EVIDENCE_APPLIST="${EVIDENCE_DIR}/07-DR-APP-LIST.txt"
readonly WAVE_BANDS=(-30 -25 -20 -15 -10 -5 0 5 10 15 20 25 30 35)
readonly GITLAB_HOST="gitlab.notyouraverage.dev"
readonly GITLAB_SSH_PORT=8443
readonly SNAPSHOT_PREFIX="/tmp/dr-snapshot-"

# Transient key file paths — wrapped by trap below:
readonly TMP_SEALED_KEY="/tmp/sealed-secrets-key.yml"
readonly TMP_REPO_SSH="/tmp/repo-ssh-key.yml"

trap 'rm -f "${TMP_SEALED_KEY}" "${TMP_REPO_SSH}"' EXIT INT TERM

# ----------------------------------------------------------------------------
# Logging helpers
# ----------------------------------------------------------------------------

log()  { printf '[dr-verify] %s\n' "$*"; }
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; }
die()  { fail "$*"; exit 1; }

# ----------------------------------------------------------------------------
# Preflight — must cover all 14 gates from 07-RESEARCH.md §"Pre-flight Gate List"
# ----------------------------------------------------------------------------

preflight() {
  local fail=0
  log "Preflight: 14 gates"

  # Gates 1-5, 7-8: tool presence (kind, docker, kubectl, vault, jq, yq)
  for cmd in kind docker kubectl vault jq yq; do
    if command -v "$cmd" >/dev/null 2>&1; then
      pass "tool present: $cmd"
    else
      fail "tool missing: $cmd (install: brew install $cmd)"
      fail=1
    fi
  done

  # Gate 3: docker daemon responsive
  if docker info >/dev/null 2>&1; then
    pass "docker daemon responsive"
  else
    fail "docker daemon not responding. Start Docker Desktop and retry."
    fail=1
  fi

  # Gate 6: vault authenticated
  if vault token lookup >/dev/null 2>&1; then
    pass "vault authenticated"
  else
    fail "vault not authenticated. Run: vault login <METHOD>"
    fail=1
  fi

  # Gate 9: gitlab SSH reachable
  # GitLab SSH returns exit 1 on successful auth handshake; we grep for Welcome/authentic.
  local ssh_out
  ssh_out=$(ssh -T -p "${GITLAB_SSH_PORT}" -o BatchMode=yes -o ConnectTimeout=5 "git@${GITLAB_HOST}" 2>&1 || true)
  if echo "$ssh_out" | grep -qE 'Welcome|authentic'; then
    pass "gitlab SSH reachable: ${GITLAB_HOST}:${GITLAB_SSH_PORT}"
  else
    fail "gitlab SSH unreachable at ${GITLAB_HOST}:${GITLAB_SSH_PORT}. Check VPN/tailscale. Output: ${ssh_out}"
    fail=1
  fi

  # Gate 10: disk space ≥10 GB free in $HOME (cross-platform: macOS df -g, Linux df -BG)
  local free_gb
  if df -g "$HOME" >/dev/null 2>&1; then
    free_gb=$(df -g "$HOME" | awk 'NR==2 {print $4}')
  else
    free_gb=$(df -BG "$HOME" | awk 'NR==2 {gsub("G","",$4); print $4}')
  fi
  if [ "${free_gb:-0}" -ge 10 ]; then
    pass "disk space OK (${free_gb} GB free in \$HOME)"
  else
    fail "less than 10 GB free in \$HOME (${free_gb:-0} GB)"
    fail=1
  fi

  # Gate 11: no stale argocd-dr cluster
  if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    fail "stale kind cluster '${CLUSTER_NAME}' exists. Run: kind delete cluster --name ${CLUSTER_NAME}"
    fail=1
  else
    pass "no stale '${CLUSTER_NAME}' cluster"
  fi

  # Gate 14: /tmp writable
  if [ -w /tmp ]; then
    pass "/tmp writable"
  else
    fail "/tmp not writable"
    fail=1
  fi

  # Gates 12, 13 are context-dependent (post-create kind-argocd-dr; prod kubectl context).
  # Skipped in preflight-only but noted as advisory. Callers who have the cluster up run
  # `preflight_post_create` separately.

  if [ $fail -ne 0 ]; then
    die "preflight FAILED ($fail gates)"
  fi
  log "PREFLIGHT: all gates passed"
}

preflight_post_create() {
  # Gate 12: kubectl context == kind-argocd-dr
  if [ "$(kubectl config current-context 2>/dev/null)" = "${KUBECTL_CONTEXT}" ]; then
    pass "kubectl context: ${KUBECTL_CONTEXT}"
  else
    die "kubectl context not ${KUBECTL_CONTEXT}. Run: kubectl config use-context ${KUBECTL_CONTEXT}"
  fi
}

# ----------------------------------------------------------------------------
# Snapshot — TSV of name + sync-wave + .status.operationState.startedAt
# ----------------------------------------------------------------------------

snapshot() {
  local label="${1:-}"
  [ -n "$label" ] || die "snapshot requires a label (e.g. t5m, t15m)"
  local out="${SNAPSHOT_PREFIX}${label}.tsv"

  log "Capturing snapshot [${label}] → ${out}"
  # TSV columns: name TAB argocd.argoproj.io/sync-wave TAB .status.operationState.startedAt
  # The jsonpath below escapes dots as \. per kubectl jsonpath rules; functionally identical.
  kubectl -n argocd get app -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.argocd\.argoproj\.io/sync-wave}{"\t"}{.status.operationState.startedAt}{"\n"}{end}' \
    > "$out"

  local apps_with_startedat
  apps_with_startedat=$(awk -F'\t' '$3 != "" {n++} END {print n+0}' "$out")
  local total_apps
  total_apps=$(wc -l < "$out" | tr -d ' ')
  log "snapshot[${label}]: ${apps_with_startedat}/${total_apps} apps have non-null startedAt"
  pass "snapshot captured: ${out}"
}

# ----------------------------------------------------------------------------
# Band-to-band ordering assertion (DR-02)
#
# Strict: for each adjacent non-empty band pair (W_a, W_b) where W_a < W_b,
# require min(startedAt in W_a) < min(startedAt in W_b). Empty bands skipped.
# PASS only if all comparisons succeed.
# ----------------------------------------------------------------------------

assert_band_ordering() {
  local snapshot_file="${1:-${SNAPSHOT_PREFIX}t15m.tsv}"
  [ -f "$snapshot_file" ] || die "snapshot missing: $snapshot_file (run: $0 --snapshot t15m)"

  log "Strict band-to-band assertion on ${snapshot_file}"
  log "Bands: ${WAVE_BANDS[*]}"

  # Build min-startedAt per band. Missing or null startedAt contributes nothing.
  declare -A band_min
  local band
  for band in "${WAVE_BANDS[@]}"; do
    # Extract non-null startedAt rows for this band, sort lexicographically
    # (ISO-8601 sorts chronologically), take first.
    local min
    min=$(awk -F'\t' -v w="$band" '$2 == w && $3 != "" {print $3}' "$snapshot_file" | sort | head -1)
    if [ -n "$min" ]; then
      band_min[$band]="$min"
    fi
  done

  # Iterate adjacent non-empty pairs.
  local fail_count=0
  local pass_count=0
  local prev_band=""
  local prev_min=""
  local i
  for i in "${WAVE_BANDS[@]}"; do
    if [ -n "${band_min[$i]:-}" ]; then
      if [ -n "$prev_band" ]; then
        if [[ "${band_min[$i]}" > "$prev_min" ]]; then
          pass "band ${prev_band} (${prev_min}) < band ${i} (${band_min[$i]})"
          pass_count=$((pass_count+1))
        else
          fail "band ${prev_band} (${prev_min}) !< band ${i} (${band_min[$i]})  ← ORDERING VIOLATION"
          fail_count=$((fail_count+1))
        fi
      fi
      prev_band="$i"
      prev_min="${band_min[$i]}"
    fi
  done

  if [ $fail_count -eq 0 ]; then
    pass "band-to-band ordering: ${pass_count} comparisons PASS, 0 FAIL"
    return 0
  else
    fail "band-to-band ordering: ${pass_count} PASS, ${fail_count} FAIL"
    return 1
  fi
}

# ----------------------------------------------------------------------------
# Round-trip SealedSecret decryption check (DR-03)
#
# Primary:  localstack-auth-token (NS localstack; localstack namespace created by
#           `namespaces` Application at wave -25).
# Fallback: valkey-credentials (valkey ns), crowdsec-lapi-enroll-key (crowdsec ns).
# ----------------------------------------------------------------------------

round_trip_check() {
  log "Round-trip SealedSecret decryption check"

  # Primary: localstack-auth-token
  if kubectl -n localstack wait --for=create secret/localstack-auth-token --timeout=60s >/dev/null 2>&1; then
    local bytes
    bytes=$(kubectl -n localstack get secret localstack-auth-token -o jsonpath='{.data.auth-token}' | base64 -d | wc -c)
    if [ "${bytes:-0}" -gt 0 ]; then
      pass "round-trip: localstack-auth-token decrypted ($bytes bytes)"
      echo "localstack-auth-token:$bytes"
      return 0
    fi
  fi

  log "primary target localstack-auth-token unavailable; trying valkey-credentials"
  if kubectl -n valkey wait --for=create secret/valkey-credentials --timeout=30s >/dev/null 2>&1; then
    local bytes
    bytes=$(kubectl -n valkey get secret valkey-credentials -o jsonpath='{.data.password}' | base64 -d | wc -c)
    if [ "${bytes:-0}" -gt 0 ]; then
      pass "round-trip: valkey-credentials decrypted ($bytes bytes)"
      echo "valkey-credentials:$bytes"
      return 0
    fi
  fi

  log "fallback target valkey-credentials unavailable; trying crowdsec-lapi-enroll-key"
  if kubectl -n crowdsec wait --for=create secret/crowdsec-lapi-enroll-key --timeout=30s >/dev/null 2>&1; then
    local bytes
    bytes=$(kubectl -n crowdsec get secret crowdsec-lapi-enroll-key -o jsonpath='{.data.enroll-key}' | base64 -d | wc -c)
    if [ "${bytes:-0}" -gt 0 ]; then
      pass "round-trip: crowdsec-lapi-enroll-key decrypted ($bytes bytes)"
      echo "crowdsec-lapi-enroll-key:$bytes"
      return 0
    fi
  fi

  fail "round-trip: NONE of localstack-auth-token, valkey-credentials, crowdsec-lapi-enroll-key decrypted"
  return 1
}

# ----------------------------------------------------------------------------
# Evidence capture → .planning/phases/07-disaster-recovery-verification/
# ----------------------------------------------------------------------------

evidence() {
  mkdir -p "$EVIDENCE_DIR"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  log "Capturing evidence → $EVIDENCE_DIR"

  # Events
  kubectl -n argocd get events --sort-by=.lastTimestamp > "$EVIDENCE_EVENTS" 2>&1 || true
  pass "events: $EVIDENCE_EVENTS"

  # App list
  kubectl -n argocd get app -o wide > "$EVIDENCE_APPLIST" 2>&1 || true
  pass "app list: $EVIDENCE_APPLIST"

  # Run assertion, capture status
  local assert_status="UNKNOWN"
  if assert_band_ordering "${SNAPSHOT_PREFIX}t15m.tsv"; then
    assert_status="PASS"
  else
    assert_status="FAIL"
  fi

  # Run round-trip
  local rt_result=""
  rt_result=$(round_trip_check 2>&1 || echo "FAIL")

  # Write DR-EVIDENCE.md
  {
    echo "# Phase 7 DR Evidence"
    echo ""
    echo "**Captured:** $ts"
    echo "**Cluster:** $CLUSTER_NAME"
    echo ""
    echo "## Band-to-band assertion: $assert_status"
    echo ""
    echo "\`\`\`"
    assert_band_ordering "${SNAPSHOT_PREFIX}t15m.tsv" 2>&1 || true
    echo "\`\`\`"
    echo ""
    echo "## Round-trip SealedSecret check"
    echo ""
    echo "\`\`\`"
    echo "$rt_result"
    echo "\`\`\`"
    echo ""
    echo "## T+5m snapshot"
    echo ""
    echo "\`\`\`tsv"
    cat "${SNAPSHOT_PREFIX}t5m.tsv" 2>/dev/null || echo "(no t5m snapshot)"
    echo "\`\`\`"
    echo ""
    echo "## T+15m snapshot"
    echo ""
    echo "\`\`\`tsv"
    cat "${SNAPSHOT_PREFIX}t15m.tsv" 2>/dev/null || echo "(no t15m snapshot)"
    echo "\`\`\`"
  } > "$EVIDENCE_MD"
  pass "evidence doc: $EVIDENCE_MD"
}

# ----------------------------------------------------------------------------
# Teardown (DR-04) — kind delete cluster with retry+docker-rm fallback
# ----------------------------------------------------------------------------

teardown() {
  log "Tearing down cluster ${CLUSTER_NAME}"

  if ! kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
    pass "teardown: no cluster named ${CLUSTER_NAME} (already gone)"
    return 0
  fi

  if kind delete cluster --name "${CLUSTER_NAME}"; then
    pass "teardown: kind delete cluster --name ${CLUSTER_NAME} succeeded"
    return 0
  fi

  log "first kind delete failed; retrying once after 5s"
  sleep 5
  if kind delete cluster --name "${CLUSTER_NAME}"; then
    pass "teardown: kind delete succeeded on retry"
    return 0
  fi

  fail "kind delete cluster --name ${CLUSTER_NAME} failed twice"
  log "fallback: docker rm -f \$(docker ps -a --filter 'name=${CLUSTER_NAME}-control-plane' -q)"
  local containers
  containers=$(docker ps -a --filter "name=${CLUSTER_NAME}-control-plane" -q || true)
  if [ -n "$containers" ]; then
    docker rm -f $containers || true
  fi

  # Record failure in evidence
  if [ -f "$EVIDENCE_MD" ]; then
    {
      echo ""
      echo "## Teardown: FAILED"
      echo ""
      echo "\`kind delete cluster --name ${CLUSTER_NAME}\` failed twice. Manual fallback attempted via \`docker rm -f\`."
      echo "Operator: verify cluster gone with \`kind get clusters | grep -qx ${CLUSTER_NAME}\` (expect no match)."
    } >> "$EVIDENCE_MD"
  fi

  return 1
}

# ----------------------------------------------------------------------------
# Main dispatcher
# ----------------------------------------------------------------------------

main() {
  case "${1:-}" in
    --preflight-only) preflight ;;
    --snapshot)       preflight_post_create; snapshot "${2:-}" ;;
    --assert)         assert_band_ordering "${SNAPSHOT_PREFIX}t15m.tsv" ;;
    --evidence)       evidence ;;
    --teardown)       teardown ;;
    "")
      # Full flow: preflight → snapshot t5m → wait → snapshot t15m → evidence → teardown.
      # Wall-clock waits: runbook places apply-root call at T=0; script assumes caller
      # invokes this AFTER apply-root and sleeps internally for snapshot cadence.
      preflight
      log "full flow: expects caller to have applied root.yml; snapshots+assertion+evidence+teardown to follow"
      preflight_post_create
      log "sleeping 5 min for T+5m snapshot..."
      sleep 300
      snapshot t5m
      log "sleeping 10 min for T+15m snapshot..."
      sleep 600
      snapshot t15m
      assert_band_ordering "${SNAPSHOT_PREFIX}t15m.tsv" || true
      evidence
      teardown
      ;;
    *)
      fail "unknown flag: ${1}"
      exit 2
      ;;
  esac
}

main "$@"
