# Disaster recovery runbook

> Authoritative, copy-pasteable DR cold-start procedure for the
> `argocd-gitops` app-of-apps deployment. Every shell line below is literal —
> parameters are `<UPPER_SNAKE_CASE>` placeholders the operator fills in
> once at the top of the shell session. **3am-emergency mindset**: copy line,
> paste, run. Do not paraphrase.
>
> Satisfies DR-01 (cold-start procedure), DR-03 (sealed-secrets key
> export/import), and DR-04 (teardown).

## When to run this

Run this runbook when:

- Rehearsing DR at the end of a hardening phase (end of Phase 6 / this
  runbook is Phase 7's deliverable).
- The sealed-secrets controller key has been rotated and the Vault-backed
  copy needs a round-trip proof against committed SealedSecrets.
- Preparing to upgrade ArgoCD across a major version boundary (rehearse on
  a kind cluster before touching prod).
- Onboarding a new operator who will inherit the runbook — they should walk
  through it end-to-end on kind at least once.

For the summary / index of the app-of-apps architecture, see
`zeus-k8s/argocd/README.md`. For the design rationale and risk register
(R1-R14), see `docs/plans/argocd-app-of-apps.md`. For programmatic
evidence capture invoked from this runbook, see `hack/dr-verify.sh`.

## Preflight (copy into shell; abort on any fail)

Fill the parameter block in ONCE at the top of the shell session. Every
subsequent step reads from these environment variables, so keep the same
terminal open (or re-export them).

```bash
export PROD_KUBECTL_CONTEXT="<your prod context name, e.g. k3s-zeus>"
export VAULT_ADDR="http://192.168.0.201:8200"    # in-cluster Vault, MetalLB LoadBalancer on zeus; reachable on home-lab LAN / VPN / tailscale only
export VAULT_PATH_SEALED_SECRETS="<kv path — see discovery step below, e.g. secret/argocd/sealed-secrets-key>"
export VAULT_PATH_REPO_SSH="<kv path — see discovery step below, e.g. secret/argocd/repo-ssh-key>"
export GITLAB_REPO_URL="ssh://git@gitlab.notyouraverage.dev:8443/a.anand.91119/argocd-gitops.git"
```

Verify local tooling is present:

```bash
# kind + kubectl + jq + yq from core brew:
brew install kind kubectl jq yq
# Vault CLI is not in core brew — use HashiCorp's tap OR direct binary:
#   Option A (tap):    brew tap hashicorp/tap && brew install hashicorp/tap/vault
#   Option B (binary): curl -LO "https://releases.hashicorp.com/vault/1.18.3/vault_1.18.3_darwin_arm64.zip" \
#                       && unzip vault_*.zip && sudo mv vault /usr/local/bin/
# If the tap errors with "Permission denied" on /opt/homebrew/Library/Taps:
#   sudo chown -R "$(whoami):admin" /opt/homebrew/Library/Taps   # then re-run tap+install
# Docker Desktop must be running (GUI) OR colima/orbstack started.
docker info >/dev/null 2>&1 || { echo "FAIL: docker daemon not reachable"; exit 1; }
```

Authenticate to Vault (method depends on your environment):

```bash
vault login <METHOD>    # e.g. -method=oidc, or token=<…>, or userpass
vault token lookup >/dev/null 2>&1 || { echo "FAIL: vault not authenticated"; exit 1; }
```

Discover the KV paths for the sealed-secrets key and repo SSH key
(run once; substitute the results back into `VAULT_PATH_SEALED_SECRETS`
and `VAULT_PATH_REPO_SSH` above):

```bash
# List top-level KV mounts:
vault secrets list -format=json | jq -r 'to_entries[] | select(.value.type=="kv" or .value.type=="kv-v2") | .key'
# Browse likely locations (swap `secret/` for whatever mount your org uses):
vault kv list secret/                    # look for argocd/, sealed-secrets, bitnami-sealed-secrets
vault kv list secret/argocd/ 2>/dev/null # if it exists
# Once you find the sealed-secrets key entry (usually contains `.crt`/`.key` fields or a single `tls.key` blob):
vault kv get secret/argocd/sealed-secrets-key
# Same for repo SSH key (look for `sshPrivateKey`, `ssh-privatekey`, or `identity` fields):
vault kv get secret/argocd/repo-ssh-key
```

Confirm VPN / tailscale is up and gitlab is reachable over SSH:

```bash
ssh -T -o BatchMode=yes -o ConnectTimeout=5 -p 8443 git@gitlab.notyouraverage.dev \
  2>&1 | grep -qE 'Welcome|successfully authenticated' \
  && echo "PASS: gitlab ssh reachable" \
  || { echo "FAIL: check VPN/tailscale + ssh key for gitlab.notyouraverage.dev:8443"; exit 1; }
```

One-command gate (all 14 preflight gates — see `docs/plans/` Phase 7
RESEARCH.md §"Pre-flight Gate List"):

```bash
bash hack/dr-verify.sh --preflight-only
```

Manual fall-back spot-checks (same 14 gates; run each if the script is
unavailable):

```bash
# G01: kind installed
command -v kind >/dev/null && kind version
# G02: docker daemon up
docker info >/dev/null && echo "docker OK"
# G03: kubectl installed
command -v kubectl >/dev/null && kubectl version --client --output=json | jq -r '.clientVersion.gitVersion'
# G04: jq installed
command -v jq >/dev/null && jq --version
# G05: yq installed (pipe-based)
command -v yq >/dev/null && yq --version
# G06: vault CLI installed
command -v vault >/dev/null && vault version
# G07: vault authenticated
vault token lookup >/dev/null && echo "vault OK"
# G08: VAULT_ADDR set
[ -n "$VAULT_ADDR" ] && echo "VAULT_ADDR=$VAULT_ADDR"
# G09: sealed-secrets-key kv path readable
vault kv get "$VAULT_PATH_SEALED_SECRETS" >/dev/null && echo "sealed-secrets kv readable"
# G10: repo-ssh-key kv path readable
vault kv get "$VAULT_PATH_REPO_SSH" >/dev/null && echo "repo-ssh kv readable"
# G11: gitlab ssh reachable (VPN/tailscale on)
ssh -T -o BatchMode=yes -o ConnectTimeout=5 -p 8443 git@gitlab.notyouraverage.dev 2>&1 | grep -q 'authenticated'
# G12: PROD_KUBECTL_CONTEXT set and valid
kubectl --context "$PROD_KUBECTL_CONTEXT" version --output=json | jq -r '.serverVersion.gitVersion'
# G13: no dangling kind cluster named argocd-dr
kind get clusters | grep -qx argocd-dr && { echo "FAIL: argocd-dr already exists; delete before re-running"; exit 1; } || echo "no dangling argocd-dr cluster"
# G14: worktree clean on main (optional but recommended)
git -C "$(git rev-parse --show-toplevel)" status --porcelain | grep -q . && echo "WARN: worktree dirty" || echo "worktree clean"
```

Abort on any `FAIL:` above. Do not proceed to step 1 until every gate is
green.

## 1. Create the kind cluster

The cluster name `argocd-dr` is load-bearing — `hack/dr-verify.sh` matches
it literally and the teardown command in step 8 deletes it by that exact
name. Do not rename.

```bash
set -euo pipefail
PROD_K8S_VER=$(kubectl --context "$PROD_KUBECTL_CONTEXT" version --output=json | jq -r '.serverVersion.gitVersion')
echo "prod K8s version: $PROD_K8S_VER"

# Prefer exact patch; fall back to same-minor latest if image manifest missing:
if docker manifest inspect "kindest/node:${PROD_K8S_VER}" >/dev/null 2>&1; then
  KIND_IMG="kindest/node:${PROD_K8S_VER}"
else
  echo "WARN: exact image kindest/node:${PROD_K8S_VER} not found; fall back to latest patch for minor."
  echo "      Browse https://hub.docker.com/r/kindest/node/tags and pick a tag for the same MAJOR.MINOR."
  exit 1  # operator picks manually, re-runs with KIND_IMG override
fi

kind create cluster --name argocd-dr --image "$KIND_IMG"
[ "$(kubectl config current-context)" = "kind-argocd-dr" ] || kubectl config use-context kind-argocd-dr
kubectl cluster-info
```

If the exact-patch image doesn't exist, the `exit 1` stops the script so the
operator consciously picks a tag. Re-run with `KIND_IMG` already exported
to skip the discovery branch:

```bash
export KIND_IMG="kindest/node:v1.30.4"    # example override
kind create cluster --name argocd-dr --image "$KIND_IMG"
kubectl config use-context kind-argocd-dr
kubectl cluster-info
```

## 2. Install ArgoCD (HA manifest — matches prod)

This mirrors the prod ansible playbook at
`/Users/aanand/IdeaProjects/ansible-playbooks/kubernetes/services/argocd/install-argocd.yml`.
The HA manifest is pinned to the same version (`v2.12.4`) running in prod.
The upstream manifest path is `argocd/refs/tags/v2.12.4/manifests/ha/install.yaml`
on the `argoproj/argo-cd` repository.

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/refs/tags/v2.12.4/manifests/ha/install.yaml
kubectl -n argocd wait --for=condition=Available deploy/argocd-application-controller --timeout=300s || true
kubectl -n argocd wait --for=condition=Available deploy/argocd-server --timeout=300s || true

# Some HA pods (redis-ha members, repo-server replicas) remain Pending on single-node kind.
# This is EXPECTED — health of ArgoCD itself is not the DR gate, graph construction is.
kubectl -n argocd get pods
```

## 3. Restore the sealed-secrets private key from Vault

Prefer the direct-pipe form — the key never lands on disk.

```bash
set -euo pipefail
# Direct pipe — key never lands on disk:
vault kv get -format=yaml "$VAULT_PATH_SEALED_SECRETS" \
  | yq -y '.data.data' \
  | kubectl apply -n kube-system -f -

# Sealed-secrets controller must be restarted AFTER the key is applied so it picks up the imported key
# instead of its self-generated default:
# (Controller is installed by the `sealed-secrets` Application at wave -30 during root apply.
#  If you're restoring BEFORE apply-root, install controller manually first OR defer this restart
#  to step 5.5 after the sealed-secrets app has reconciled.)
```

If the direct-pipe form does not fit your Vault layout (e.g. custom wrapper
around `vault kv get`, different kv schema), use the file+trap fallback.
The `trap ... EXIT INT TERM` idiom is **load-bearing** — the Phase 1 PRE-04
preflight discipline is that a transient key file must be `rm -f`-ed on any
shell exit path (normal, Ctrl-C, SIGTERM).

```bash
set -euo pipefail
trap 'rm -f /tmp/sealed-secrets-key.yml' EXIT INT TERM
vault kv get -format=yaml "$VAULT_PATH_SEALED_SECRETS" | yq -y '.data.data' > /tmp/sealed-secrets-key.yml
kubectl apply -n kube-system -f /tmp/sealed-secrets-key.yml
# trap removes /tmp/sealed-secrets-key.yml on shell exit
```

## 4. Restore the repo SSH key from Vault as an ArgoCD repository secret

The secret label `argocd.argoproj.io/secret-type: repository` is
load-bearing — ArgoCD discovers repo credentials by label, not by name.

```bash
set -euo pipefail
trap 'rm -f /tmp/repo-ssh-key.yml' EXIT INT TERM

# Pull the SSH key from Vault (format depends on how it was stored — adjust yq filter if needed):
vault kv get -format=yaml "$VAULT_PATH_REPO_SSH" | yq -r '.data.data.sshPrivateKey' > /tmp/repo-ssh-key.yml

kubectl -n argocd create secret generic argocd-repo-creds \
  --from-literal=type=git \
  --from-literal=url="$GITLAB_REPO_URL" \
  --from-file=sshPrivateKey=/tmp/repo-ssh-key.yml \
  --dry-run=client -o yaml \
  | yq -y '.metadata.labels += {"argocd.argoproj.io/secret-type": "repository"}' \
  | kubectl apply -f -

kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=repository
```

Expected output: one row named `argocd-repo-creds` with type `Opaque`.

## 5. Apply the AppProject and root Application

Apply in exactly this order — the `AppProject` must exist before the root
`Application` references it. `date -u +%s > /tmp/dr-t0.txt` captures the
wall-clock reference T=0 that step 6's T+5m / T+15m snapshots measure
against.

```bash
kubectl apply -f zeus-k8s/argocd/projects/zeus-kubernetes.yml
kubectl apply -f zeus-k8s/argocd/root.yml

# Capture T=0 for wall-clock reference:
date -u +%s > /tmp/dr-t0.txt
echo "T=0 at $(date -u) (epoch: $(cat /tmp/dr-t0.txt))"
```

### 5.5 Restart sealed-secrets controller (once it exists)

After applying root, the `sealed-secrets` Application at wave -30 installs
the controller. Once the controller is Ready, run a one-time restart so it
picks up the Vault-imported key (if not already restarted in step 3 — the
controller only reads the key at startup):

```bash
kubectl -n kube-system rollout status deploy sealed-secrets-controller --timeout=300s
kubectl -n kube-system rollout restart deploy sealed-secrets-controller
kubectl -n kube-system rollout status deploy sealed-secrets-controller --timeout=120s
```

## 6. Observe sync-wave ordering (T+5m / T+15m)

Two-pass observation: T+5m captures the early-band apps (sealed-secrets,
namespaces, secrets, operators), T+15m captures the late-band apps
(workloads). The assertion enforces strict band-to-band ordering — a wave
-N app must reach its terminal state before a wave -N+1 app starts.

```bash
# Side terminal (leave running):
kubectl -n argocd port-forward svc/argocd-server 8080:443

# At T+5m (approx 5 min after step 5 apply):
bash hack/dr-verify.sh --snapshot t5m

# At T+15m (approx 15 min after step 5 apply):
bash hack/dr-verify.sh --snapshot t15m
bash hack/dr-verify.sh --assert
```

While the side terminal holds the port-forward, the ArgoCD UI is reachable
at `https://localhost:8080` for visual confirmation. Admin password (first
login):

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
```

## 7. Capture evidence + run the round-trip SealedSecret check

```bash
bash hack/dr-verify.sh --evidence

# This populates:
#   .planning/phases/07-disaster-recovery-verification/07-DR-EVIDENCE.md   (TSVs + assertion + round-trip result)
#   .planning/phases/07-disaster-recovery-verification/07-DR-EVENTS.txt    (kubectl -n argocd get events)
#   .planning/phases/07-disaster-recovery-verification/07-DR-APP-LIST.txt  (kubectl -n argocd get app -o wide)
```

Round-trip SealedSecret proof — decrypt a committed SealedSecret using the
Vault-restored controller key. If the controller key matches the sealing
key in git, the `Secret` will materialize and its `auth-token` field will
decode to a non-zero number of bytes:

```bash
# Round-trip proof: a committed SealedSecret decrypts to a Secret using the Vault-restored key.
# Primary target: localstack-auth-token (wave -25 namespaces → wave -20 secrets):
kubectl -n localstack wait --for=create secret/localstack-auth-token --timeout=60s \
  && kubectl -n localstack get secret localstack-auth-token \
       -o jsonpath='{.data.auth-token}' | base64 -d | wc -c
# Non-zero byte count ⇒ PASS (Vault key matches committed SealedSecrets' seal)

# Fallbacks if localstack namespace hasn't synced yet:
#   valkey-credentials (NS: valkey)
#   crowdsec-lapi-enroll-key (NS: crowdsec)
```

## 8. Tear down the cluster

The teardown command is **load-bearing** for DR-04: the literal string
`kind delete cluster --name argocd-dr` is the final step of the DR
exercise.

```bash
# After evidence is reviewed:
kind delete cluster --name argocd-dr

# Verify gone:
kind get clusters | grep -qx argocd-dr && echo "FAIL: cluster still exists" || echo "PASS: cluster deleted"

# Fallback if `kind delete` hangs or fails:
#   docker rm -f $(docker ps -a --filter 'name=argocd-dr-control-plane' -q)
```

Also clean up any transient files the operator may have manually created
outside the `trap`-protected paths:

```bash
rm -f /tmp/dr-t0.txt /tmp/sealed-secrets-key.yml /tmp/repo-ssh-key.yml
```

## Appendix: Expected failures (acceptable non-green apps on DR)

On a fresh kind cluster, the following apps are **expected** to be
non-green. Do NOT treat these as DR halt triggers. See
`.planning/phases/07-disaster-recovery-verification/07-CONTEXT.md` for the
authoritative list and the reasoning behind each entry.

- `asynchronous-http-server`, `grpc-stats-aggregator`, `mixpost` — app layer, need databases
- `calico-system`, `calico-monitoring` — kind uses kindnet, not calico
- `cloudflare-ingress`, `cloudflare-tunnel`, `newt` — external tokens not on DR
- `cnpg-operator`, `cnpg-image-catalogs`, `cnpg-timescaledb`, `postgres` — CNPG needs PVC storage + registries
- `gitlab-runners-nyad`, `gitlab-runners-saas-aa`, `gitlab-runners-saas-nm` — registry + S3 creds
- `ingresses` — needs cloudflare-ingress upstream
- `kafka-ui` — needs kafka which needs stackgres
- `keda`, `mariadb-operator` — operators install CRDs; CRs don't
- `localstack`, `metrics-server` — may work; tolerate failure
- `mariadb-mixpost`, `valkey` — need databases/storage
- `prometheus`, `prometheus-kafka-exporter` — CRDs + monitoring backends
- `stackgres` — known-failing even on prod
- `vault` — needs init + unseal + external storage

**Must-be-Healthy trio** — unexpected failure of any of these = halt the
exercise:

- `sealed-secrets`
- `namespaces`
- `secrets`

## Appendix: Unexpected-failure halt protocol

If any of the must-be-Healthy trio (`sealed-secrets`, `namespaces`,
`secrets`) fails, OR any non-expected-fail app is unhealthy at T+15m, halt
the exercise. Mirror the Phase 4 halt-and-recover pattern:

1. **Option A — fix in-flight + resume assertion.** Low-friction cases
   only: image pull error (re-login to registry), transient network flake
   (re-sync), missing CRD (apply operator manually, resume). After fix:
   `bash hack/dr-verify.sh --snapshot t15m-retry && bash hack/dr-verify.sh --assert`.
2. **Option B — amend expected-fails list + re-run.** The failing app has
   a structural dependency on DR-unreachable infrastructure (e.g. external
   S3 bucket, prod-only secret). Add to
   `.planning/phases/07-disaster-recovery-verification/07-CONTEXT.md`
   Expected-Fails with a one-line reason, re-run the assertion.
3. **Option C — abort DR + file Phase 8 follow-up.** The failure exposes a
   real bug in the app-of-apps graph (wrong sync-wave, missing dependency,
   broken manifest). Capture the evidence bundle via
   `bash hack/dr-verify.sh --evidence --halt`, tear down, and file a
   Phase 8 hardening issue.

**Where to look first** when triaging:

- Controller logs — `kubectl -n kube-system logs deploy/sealed-secrets-controller --tail=200`
- Sealed-secrets key fingerprint — confirm the Vault-imported key's
  `tls.crt` fingerprint matches the one that originally sealed the
  committed SealedSecrets.
- ArgoCD application controller events — `kubectl -n argocd get events --sort-by=.lastTimestamp | tail -50`
- Image-pull errors — `kubectl get events --all-namespaces --field-selector reason=Failed | grep -i pull`
