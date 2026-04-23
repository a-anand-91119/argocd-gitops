# ArgoCD App-of-Apps: Bootstrap, Backfill, and Sync-Wave Orchestration

## Context

27 ArgoCD Applications were hand-created through the UI against the
repo `ssh://git@gitlab.notyouraverage.dev:8443/a.anand.91119/argocd-gitops.git`.
Nothing is declarative:

* If the `argocd` namespace is lost, every Application disappears.
* New services (mariadb-operator, mariadb-mixpost, mixpost) ship as
  manifests but have no matching `Application` custom resource yet.
* There is no ordering contract — sealed-secrets, namespaces, operators,
  clusters, and apps all reconcile independently and happen to work by luck
  of past sync order.

This plan introduces the **app-of-apps** pattern. A single "root"
`Application` watches `zeus-k8s/argocd/applications/` and spawns one child
`Application` per file. After bootstrap:

* Onboarding a service = one YAML in `zeus-k8s/argocd/applications/` + git push.
* Full cluster rebuild = `kubectl apply -f zeus-k8s/argocd/root.yml` and walk
  away.
* Sync-waves give a predictable deploy order for cold starts and CRD
  dependencies.

An alternative — `ApplicationSet` with a directory generator — was rejected
because the repo mixes Helm wrappers, Kustomize, and raw-directory folders
with per-app variance (`directory.recurse`, `syncOptions.CreateNamespace`,
`syncOptions.ServerSideApply`). A single `ApplicationSet` template cannot
express those differences cleanly.

## Ground truth (extracted from the live cluster)

### Common spec across all 27 apps

| Field | Value |
|---|---|
| `spec.project` | `zeus-kubernetes` |
| `spec.source.repoURL` | `ssh://git@gitlab.notyouraverage.dev:8443/a.anand.91119/argocd-gitops.git` |
| `spec.source.targetRevision` | `HEAD` |
| `spec.destination.server` | `https://kubernetes.default.svc` |
| `spec.syncPolicy.automated` | `{ prune: true, selfHeal: true }` |

### Per-app matrix

| name | path (under `zeus-k8s/`) | recurse | destNs | syncOptions | type |
|---|---|---|---|---|---|
| asynchronous-http-server | spring-projects/asynchronous-http-server | – | spring-projects | – | Directory |
| calico-monitoring | calico-monitoring | – | calico-monitoring | CreateNamespace=true | Directory |
| calico-system | calico-system | – | calico-system | CreateNamespace=true | Directory |
| cloudflare-ingress | ingress/cloudflare | – | cloudflare-ingress | – | Helm |
| cloudflare-tunnel | cloudflare-tunnel | – | cloudflare-tunnel | – | Directory |
| cnpg-image-catalogs | databases/image-catalogs | true | postgres | CreateNamespace=true | Directory |
| cnpg-operator | databases/operators/cnpg | – | cnpg-system | ServerSideApply=true | Helm |
| cnpg-timescaledb | databases/timescaledb | – | timescaledb | – | Directory |
| gitlab-runners-nyad | gitlab-runners/nyad | – | gitlab-runner-nyad | – | Helm |
| gitlab-runners-saas-aa | gitlab-runners/saas-aa | – | gitlab-runner-saas-aa | CreateNamespace=true | Helm |
| gitlab-runners-sass-nm *(typo)* | gitlab-runners/saas-nm | – | gitlab-runner-saas-nm | CreateNamespace=true | Helm |
| grpc-stats-aggregator | spring-projects/grpc-stats-aggregator | – | spring-projects | – | Directory |
| ingresses | ingress/ingresses | true | – | – | Directory |
| kafka-ui | dev-tools/kafka-ui | – | dev-tools | ServerSideApply=true | Helm |
| keda | kedas | – | keda | ServerSideApply=true | Helm |
| localstack | localstack | – | localstack | CreateNamespace=true | Helm |
| metrics-server | metrics-server | – | kube-system | – | Helm |
| namespaces | namespaces | – | – | – | Directory |
| newt | newt | – | newt | – | Directory |
| postgres | databases/postgres/postgres-17 | true | postgres | CreateNamespace=true | Directory |
| prometheus | monitoring/prometheus | – | monitoring | ServerSideApply=true | Helm |
| prometheus-kafka-exporter | monitoring/kafka-exporter | – | monitoring | – | Helm |
| sealed-secrets | sealed-secrets | – | kube-system | – | Helm |
| secrets | secrets | true | – | – | Directory |
| stackgres | databases/operators/stackgres | – | stackgres | CreateNamespace=true | Helm |
| valkey | databases/valkey | – | valkey | CreateNamespace=true | Helm |
| vault | vault | – | vault | CreateNamespace=true, ServerSideApply=true | Helm |

Source type is auto-detected by ArgoCD from folder contents — child
Applications do **not** need to declare it.

### AppProject note

`zeus-kubernetes` has a `syncWindow` of `allow` for `1m` every minute
(`schedule: '* * * * *'`, `timeZone: Asia/Kolkata`). It is permanently open
in practice; document but do not touch.

## Sync-wave plan

Wave numbers are integers in the annotation
`argocd.argoproj.io/sync-wave`. Lower wave syncs first **within the same
parent sync** (the root Application's sync, in our case). After a child
Application is created, its own resources reconcile independently — waves
only coordinate the *creation/ordering of the children themselves*.

Rules:

1. Leave gaps between groups (5) so future insertions don't cascade renumbering.
2. Anything that installs a CRD must sync before anything that references the
   CRD.
3. Anything that creates a namespace must sync before anything that lands in
   that namespace (unless the child uses `CreateNamespace=true`).
4. Anything that publishes secrets must sync before anything that mounts them.

### Waves

| wave | applications | reason |
|---|---|---|
| **-30** | sealed-secrets | Installs `SealedSecret` CRD + controller. Must exist before anything in `secrets/`. |
| **-25** | namespaces | Creates every target namespace so downstream apps can land without `CreateNamespace=true`. |
| **-20** | secrets | `SealedSecret` objects that other apps consume (DB creds, registry tokens, tunnel tokens). Depends on namespaces + SealedSecret CRD. |
| **-15** | cnpg-operator, stackgres, mariadb-operator, keda | CRDs required by downstream clusters/scalers. |
| **-10** | calico-system, calico-monitoring, metrics-server | Node/cluster-wide infra that other pods depend on (metrics, CNI extras). |
| **-5** | cloudflare-tunnel, newt | Outbound tunnels — safer to be up before apps behind them come online. |
| **0** | vault | Consumes secrets; exposes its own service other apps may depend on. |
| **5** | cnpg-image-catalogs | PostgreSQL `ImageCatalog` CRs referenced by `Cluster` CRs. |
| **10** | postgres, cnpg-timescaledb, valkey, mariadb-mixpost | Database clusters. Depend on operators + image catalogs. |
| **15** | prometheus, prometheus-kafka-exporter, localstack | Stateful middleware that depends on CRDs from keda/cnpg. |
| **20** | kafka-ui, cloudflare-ingress | Ingress-adjacent apps that need backends listening. |
| **25** | gitlab-runners-nyad, gitlab-runners-saas-aa, gitlab-runners-saas-nm | Need registry secrets + S3 creds. |
| **30** | asynchronous-http-server, grpc-stats-aggregator, mixpost | Application layer. |
| **35** | ingresses | Last — only publish routes once backends are healthy. |

No Application sits at the implicit default (wave 0 without annotation) after
the migration — every child gets an explicit wave so reasoning is closed.

## Design: child Application template

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: <APP_NAME>
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "<WAVE>"
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: zeus-kubernetes
  source:
    repoURL: ssh://git@gitlab.notyouraverage.dev:8443/a.anand.91119/argocd-gitops.git
    targetRevision: HEAD
    path: zeus-k8s/<PATH>
    # include only when path has subdirs:
    # directory:
    #   recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: <DEST_NAMESPACE>   # omit for cluster-scoped aggregators
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    # include only when historically present (see matrix):
    # syncOptions:
    #   - CreateNamespace=true
    #   - ServerSideApply=true
    retry:
      limit: 5
      backoff:
        duration: 10s
        factor: 2
        maxDuration: 3m
```

Deltas vs current cluster state:

* **`finalizers`** — new. Enables `--cascade=foreground` delete semantics; no
  runtime effect until the Application is deleted.
* **`syncPolicy.retry`** — new. Most existing apps already accept this at
  request time (seen in `operationState.operation.retry.limit: 5`); putting
  it in spec makes the behaviour deterministic.
* **`annotations.argocd.argoproj.io/sync-wave`** — new.

These deltas are intentional and uniform across all children. Drift detection
in Phase 1 validates that no *substantive* spec field changes.

## Design: root Application

```yaml
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-options: ApplyOutOfSyncOnly=true
    # NO finalizer — we never want cascade delete on root
spec:
  project: zeus-kubernetes
  source:
    repoURL: ssh://git@gitlab.notyouraverage.dev:8443/a.anand.91119/argocd-gitops.git
    targetRevision: HEAD
    path: zeus-k8s/argocd/applications
    directory:
      recurse: false   # children are flat files
      exclude: "_*.yml"
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ApplyOutOfSyncOnly=true
    retry:
      limit: 3
      backoff:
        duration: 30s
        factor: 2
        maxDuration: 5m
```

The `exclude: "_*.yml"` pattern lets us keep template/documentation files in
the applications folder without them being synced as Applications.

## Folder layout (final)

```
zeus-k8s/argocd/
├── README.md                        # quickstart for the pattern
├── root.yml                         # bootstrap Application (applied manually once)
├── projects/
│   └── zeus-kubernetes.yml          # AppProject export (applied manually if lost)
└── applications/
    ├── _TEMPLATE.yml                # excluded by root's `exclude: "_*.yml"`
    ├── <app-name>.yml × 30          # one file per managed Application
    └── ...

docs/plans/
└── argocd-app-of-apps.md            # this file
```

---

## Phase 1 — Pre-flight (read-only, non-mutating)

Goal: capture current cluster state as the source of truth for diffing.

1. Snapshot every existing Application:
   ```bash
   mkdir -p /tmp/argocd-pre/apps /tmp/argocd-pre/projects
   for app in $(kubectl -n argocd get app -o name); do
     kubectl -n argocd get "$app" -o yaml \
       | yq 'del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields)' \
       > "/tmp/argocd-pre/apps/$(basename "$app").yml"
   done
   kubectl -n argocd get appproject zeus-kubernetes -o yaml \
     | yq 'del(.status,.metadata.uid,.metadata.resourceVersion,.metadata.generation,.metadata.creationTimestamp,.metadata.managedFields)' \
     > /tmp/argocd-pre/projects/zeus-kubernetes.yml
   ```
2. Snapshot cluster health:
   ```bash
   kubectl -n argocd get app -o wide > /tmp/argocd-pre/health.txt
   ```
3. Confirm sealed-secrets controller + key are healthy and keys are backed up
   (current cluster uses Vault — verify the `sealed-secrets-key` is exportable):
   ```bash
   kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key=active \
     -o jsonpath='{.items[*].metadata.name}'
   ```

Exit criteria: `/tmp/argocd-pre/` contains 27 app yamls + 1 project yaml,
and all apps in `health.txt` are `Synced / Healthy` (or their prior known
state — at least none are unexpectedly failing).

**No git commits in this phase.**

---

## Phase 2 — Scaffold root + AppProject backup (low-risk commits)

Goal: commit the non-child parts of the bootstrap so subsequent phases have
something to reference, without yet activating app-of-apps.

Files to create:

1. `zeus-k8s/argocd/projects/zeus-kubernetes.yml` — copy of `/tmp/argocd-pre/projects/zeus-kubernetes.yml`.
2. `zeus-k8s/argocd/root.yml` — root Application (see Design section).
   Committed but *not yet applied*.
3. `zeus-k8s/argocd/applications/.gitkeep` — so the empty folder tracks in git.
4. `zeus-k8s/argocd/applications/_TEMPLATE.yml` — commented reference;
   filename starts with `_` so it's excluded by root.
5. `zeus-k8s/argocd/README.md` — 30-line quickstart:
   * "Root bootstraps everything. Apply once: `kubectl apply -f zeus-k8s/argocd/root.yml`."
   * "Add a new app: copy `_TEMPLATE.yml` → `<name>.yml`, set `path`/`wave`/`destination`."
   * "Rebuild cluster: re-install ArgoCD, then apply `projects/` + `root.yml`."

Commit as a single PR titled something like `argocd: scaffold app-of-apps root (no-op)`.

Exit criteria: PR merged, nothing deployed, `kubectl -n argocd get app` count
unchanged (still 27).

---

## Phase 3 — Two exemplar backfills + three new Applications

Goal: generate and commit five child Applications that can be diffed
rigorously before we expand to 27. Includes the entire new-work scope
(mariadb-operator, mariadb-mixpost, mixpost).

Files to create under `zeus-k8s/argocd/applications/`:

1. `newt.yml` — wave `-5`, destNs `newt`.
2. `valkey.yml` — wave `10`, destNs `valkey`, `CreateNamespace=true`.
3. `mariadb-operator.yml` — wave `-15`, destNs `mariadb-operator`,
   `ServerSideApply=true`, `CreateNamespace=true` (namespace created by the
   `namespaces` app at wave `-25` so this is belt-and-braces).
4. `mariadb-mixpost.yml` — wave `10`, destNs `mariadb`, `recurse: true`
   (future-proof — today there are no subdirs but the pattern matches
   `postgres`).
5. `mixpost.yml` — wave `30`, destNs `mixpost`.

Rigorous pre-merge validation (for `newt` and `valkey`, which already exist):

```bash
for app in newt valkey; do
  diff <(yq '.spec' /tmp/argocd-pre/apps/$app.yml) \
       <(yq '.spec' zeus-k8s/argocd/applications/$app.yml)
done
```

Expected diffs — only these, nothing else:
* `+ syncPolicy.retry.{limit,backoff}` block (new)
* Identical `source`, `destination`, `automated`, `syncOptions` content.

Exit criteria:
* Five files committed.
* `newt` / `valkey` diff shows only the intended additions.
* Root is still **not applied** — no runtime change.

---

## Phase 4 — Apply root (first mutation)

Goal: activate the bootstrap. Five children come under root's management;
three are brand new.

1. Confirm working-tree-clean + on `main` with the Phase 3 PR merged.
2. One-shot apply:
   ```bash
   kubectl apply -f zeus-k8s/argocd/root.yml
   ```
3. Watch:
   ```bash
   kubectl -n argocd get app -w
   ```
4. Expected outcomes within ~2 minutes:
   * `root` → `Synced / Healthy`.
   * `newt`, `valkey` → **adopted** (same name, namespace, and spec equivalence);
     ArgoCD should report `Synced / Healthy` with no resource diff. If
     `OutOfSync`, compare `kubectl -n argocd get app newt -o yaml` against the
     committed file and reconcile drift before proceeding.
   * `mariadb-operator` → `Progressing` while CRDs install, then `Healthy`.
   * `mariadb-mixpost` → waits for operator CRDs, eventually `Healthy` when
     Galera reaches quorum (can take 3–5 minutes).
   * `mixpost` → `Progressing` until migrations complete, then `Healthy`.

Exit criteria: all 30 Applications (27 + 3 new) are `Synced / Healthy`.

Rollback if this phase goes wrong:
```bash
kubectl -n argocd delete app root --cascade=orphan
```
Children remain but become unmanaged. Pre-existing 27 apps are untouched;
the three new apps can be deleted individually if needed.

---

## Phase 5 — Backfill the remaining 22 Applications

Goal: bring every hand-created Application into git so the cluster is fully
declarative.

Files to create (22 total): one per name in the per-app matrix excluding
`newt`, `valkey`, and the three new ones already in git.

### Backfill script (`hack/backfill-argocd-apps.sh`)

```bash
#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-/tmp/argocd-backfill}"
mkdir -p "$OUT_DIR"

# Already hand-written — never overwrite
SKIP=(newt valkey mariadb-operator mariadb-mixpost mixpost root)

# Sync-wave assignments — must match the Phase 0 table
declare -A WAVE=(
  [sealed-secrets]=-30
  [namespaces]=-25
  [secrets]=-20
  [cnpg-operator]=-15 [stackgres]=-15 [keda]=-15
  [calico-system]=-10 [calico-monitoring]=-10 [metrics-server]=-10
  [cloudflare-tunnel]=-5
  [vault]=0
  [cnpg-image-catalogs]=5
  [postgres]=10 [cnpg-timescaledb]=10
  [prometheus]=15 [prometheus-kafka-exporter]=15 [localstack]=15
  [kafka-ui]=20 [cloudflare-ingress]=20
  [gitlab-runners-nyad]=25 [gitlab-runners-saas-aa]=25 [gitlab-runners-sass-nm]=25
  [asynchronous-http-server]=30 [grpc-stats-aggregator]=30
  [ingresses]=35
)

for app in $(kubectl -n argocd get app -o name | cut -d/ -f2); do
  for s in "${SKIP[@]}"; do [[ "$app" == "$s" ]] && continue 2; done

  wave="${WAVE[$app]:-0}"

  kubectl -n argocd get app "$app" -o json | jq --arg w "$wave" '{
    apiVersion: "argoproj.io/v1alpha1",
    kind: "Application",
    metadata: {
      name: .metadata.name,
      namespace: "argocd",
      annotations: { "argocd.argoproj.io/sync-wave": $w },
      finalizers: ["resources-finalizer.argocd.argoproj.io"]
    },
    spec: (.spec + {
      syncPolicy: (.spec.syncPolicy + {
        retry: { limit: 5, backoff: { duration: "10s", factor: 2, maxDuration: "3m" } }
      })
    })
  }' | yq -P > "$OUT_DIR/$app.yml"
done

echo "Wrote $(ls "$OUT_DIR" | wc -l) manifests to $OUT_DIR"
```

### Workflow

1. Run the script:
   ```bash
   ./hack/backfill-argocd-apps.sh /tmp/argocd-backfill
   ```
2. Diff each new file against what's already in git (should be empty — they
   are all new):
   ```bash
   ls /tmp/argocd-backfill | while read f; do
     [[ -f zeus-k8s/argocd/applications/$f ]] && diff -u zeus-k8s/argocd/applications/$f /tmp/argocd-backfill/$f
   done
   ```
3. Diff each new file against the live cluster spec (should only show the
   planned additions):
   ```bash
   for f in /tmp/argocd-backfill/*.yml; do
     name=$(basename "$f" .yml)
     diff <(yq '.spec' /tmp/argocd-pre/apps/$name.yml) <(yq '.spec' "$f")
   done
   ```
4. Copy into repo, commit, push (single PR):
   ```bash
   cp /tmp/argocd-backfill/*.yml zeus-k8s/argocd/applications/
   ```
5. After merge, root syncs → each file matches an existing Application →
   ArgoCD adopts them. Watch for `OutOfSync` flashes and investigate any
   diff.

Exit criteria: `kubectl -n argocd get app` count = 30 (27 existing + 3 new),
all `Synced / Healthy`. Every Application in the cluster has a corresponding
file in `zeus-k8s/argocd/applications/`.

---

## Phase 6 — Hardening

Goal: fix the known debt + add safety rails.

1. **Rename `gitlab-runners-sass-nm` → `gitlab-runners-saas-nm`**:
   * Commit `zeus-k8s/argocd/applications/gitlab-runners-saas-nm.yml`
     (correct spelling) pointing at the same `gitlab-runners/saas-nm` path.
   * Wait for Healthy.
   * Delete the old, misspelled Application:
     ```bash
     kubectl -n argocd delete app gitlab-runners-sass-nm --cascade=orphan
     ```
   * Then delete the old file if it was also committed.
2. **Deletion protection on critical apps**: root itself gets
   `argocd.argoproj.io/deletion-protection: "true"` (supported 2.13+; no-op
   on older but harmless). Add to `root.yml` metadata.
3. **PrunePropagationPolicy**: set `foreground` on apps that manage
   stateful sets (databases, vault) so prune respects graceful shutdown:
   ```yaml
   syncPolicy:
     syncOptions:
       - PrunePropagationPolicy=foreground
   ```
4. **Prune=false on `namespaces`**: Accidentally deleting a file in
   `zeus-k8s/namespaces/` would cause namespace deletion and cascade-kill
   everything in it. Add `syncOptions: [Prune=false]` so namespace removals
   require a manual action. Document this as a deliberate foot-gun removal.
5. **Dry-run CI**: a simple GitLab CI job that runs `argocd app diff --local
   zeus-k8s/argocd/applications/<app>.yml` on every MR, so spec drift is
   caught pre-merge. Optional, can defer.
6. **README.md** at `zeus-k8s/argocd/`: document the pattern, link to this
   plan, explain sync waves, show the template, show the rebuild procedure.

---

## Phase 7 — Disaster recovery verification

Goal: prove the whole thing works cold, without touching prod.

1. Spin up a throwaway kind cluster:
   ```bash
   kind create cluster --name argocd-dr
   ```
2. Install ArgoCD (same version as prod).
3. Register the repo SSH secret.
4. Apply:
   ```bash
   kubectl apply -f zeus-k8s/argocd/projects/zeus-kubernetes.yml
   kubectl apply -f zeus-k8s/argocd/root.yml
   ```
5. Wait. Watch all 30 Applications sync. Most will fail (CRDs, image pulls,
   missing external secrets) — that's fine; what we're verifying is that
   ArgoCD itself creates the correct graph in the correct order.
6. Confirm wave ordering in the ArgoCD UI: `sealed-secrets` syncs before
   `secrets`, operators before CR clusters, etc.
7. Tear down: `kind delete cluster --name argocd-dr`.

Do this once right after Phase 6 so the runbook is tested before an
actual emergency.

---

## Risks and mitigations

### R1. Adoption drift (HIGH impact, MEDIUM likelihood)
*Committing a spec that differs from the live Application will cause
`selfHeal: true` to reconcile the cluster to the committed version on
first sync.*
**Mitigation**: Phase 1 snapshots live state; Phase 3 and Phase 5 include
mandatory pre-merge `diff` against those snapshots. Only the pre-approved
additions (`finalizers`, `retry`, `sync-wave` annotation) may differ.

### R2. Root cascade-delete nukes everything (CATASTROPHIC)
*`kubectl -n argocd delete app root` without `--cascade=orphan` walks the
child graph and deletes every workload in the cluster.*
**Mitigation**:
* Root has no `resources-finalizer` — Kubernetes default orphans children.
* Add `argocd.argoproj.io/deletion-protection: "true"` on root (Phase 6).
* Document the `--cascade=orphan` flag at the top of `root.yml` with a
  comment.

### R3. Sync-wave race at identical waves (LOW impact, LOW likelihood)
*Two children at the same wave can sync in parallel. If one implicitly
depends on the other, a race occurs.*
**Mitigation**: the wave table deliberately separates known dependencies
(operators at -15, CRs at +10). Within a wave, apps are unrelated. If a new
inter-wave dependency is discovered, bump the dependent app's wave by 5.

### R4. AppProject `syncWindow` quirk (LOW impact)
*`1m` allow window every minute in Asia/Kolkata. On the edge of a minute a
sync request may stall briefly.*
**Mitigation**: Document only. No practical effect for GitOps reconcile
loops that already retry.

### R5. SealedSecrets undecryptable after cluster rebuild (CATASTROPHIC)
*If the `sealed-secrets-controller` private key is regenerated on a fresh
cluster, every committed `SealedSecret` becomes undecryptable.*
**Mitigation**:
* Existing process uses Vault to back up `sealed-secrets-key` (see prior
  `vault-unseal-keys` sealed secret and re-sealing history).
* Add a Phase 7 verification step: DR test uses the real sealed-secrets
  private key exported from Vault.
* Document the export/import procedure in `zeus-k8s/argocd/README.md`.

### R6. CRD availability timing (MEDIUM impact, MEDIUM likelihood)
*`mariadb-mixpost` CR at wave 10 requires `MariaDB` CRD from
`mariadb-operator` at wave -15. If the operator's webhook isn't ready when
the CR sync fires, the child fails.*
**Mitigation**:
* Wave gap of 25 is large.
* Child-level `syncPolicy.retry.limit: 5` retries with backoff (up to ~3
  minutes).
* `ServerSideApply=true` on the operator reduces apply errors on large
  CRDs.

### R7. Typo rename orphaning resources (MEDIUM impact)
*`gitlab-runners-sass-nm` → `gitlab-runners-saas-nm`. Both briefly exist
managing the same path → ArgoCD may flap over ownership.*
**Mitigation**: Phase 6 ordering (commit new → wait Healthy → delete old
with `--cascade=orphan`). The managed resources are namespaced Helm
releases; Helm's `ownership` label doesn't conflict with ArgoCD's tracking
annotation by name.

### R8. `namespaces` Application pruning a namespace (CATASTROPHIC)
*Deleting a file in `zeus-k8s/namespaces/` triggers namespace deletion,
which cascades to every resource inside.*
**Mitigation**: Phase 6 adds `syncOptions: [Prune=false]` on the
`namespaces` Application. Namespace removals become manual — deliberate
friction to prevent foot-guns.

### R9. Secrets Application historic failure (LOW impact)
*`secrets` app's `status.operationState` still shows a cached failure for a
pruned `postiz` namespace. Cosmetic only, but confusing.*
**Mitigation**: After Phase 5, force a hard refresh + sync on the
backfilled `secrets` app to clear the cache.

### R10. Git SSH credential loss (HIGH impact, LOW likelihood)
*Cluster rebuild with a new SSH keypair means ArgoCD can't pull the repo.*
**Mitigation**:
* SSH secret stored as a Kubernetes secret labelled
  `argocd.argoproj.io/secret-type=repository`.
* Back up via Vault (existing pattern).
* DR runbook (Phase 7 README) covers restoration.

### R11. Identical Application names across projects (N/A)
Single project, single in-cluster destination. Not a concern here but
flagged in case a second project is added later.

### R12. `ServerSideApply` migration on existing apps (LOW impact)
*Flipping an app to SSA can change field-ownership metadata, occasionally
causing a one-time "churn" sync where labels/annotations shift.*
**Mitigation**: the backfill only preserves existing SSA settings — does
not enable SSA on apps that didn't have it. No state change at the SSA
level.

### R13. CI/runner loops post-rename (LOW impact)
*`gitlab-runners-saas-nm` rename: the runner pods register to GitLab with a
token; renaming the ArgoCD Application doesn't affect the token. No
impact.*

### R14. Image-catalog referential integrity (MEDIUM impact)
*If `cnpg-image-catalogs` is deleted or fails sync, every
`cnpg-postgres-17` and `cnpg-timescaledb-17` Cluster goes `InvalidSpec`.*
**Mitigation**: Wave 5 for catalogs, wave 10 for clusters. In Phase 6, add
`Prune=false` to `cnpg-image-catalogs` as well — safer to manually prune
image catalog entries.

---

## Critical files to create or modify

```
docs/plans/argocd-app-of-apps.md                         (this file)
zeus-k8s/argocd/README.md                                (Phase 2)
zeus-k8s/argocd/root.yml                                 (Phase 2)
zeus-k8s/argocd/projects/zeus-kubernetes.yml             (Phase 2)
zeus-k8s/argocd/applications/.gitkeep                    (Phase 2)
zeus-k8s/argocd/applications/_TEMPLATE.yml               (Phase 2)
zeus-k8s/argocd/applications/newt.yml                    (Phase 3)
zeus-k8s/argocd/applications/valkey.yml                  (Phase 3)
zeus-k8s/argocd/applications/mariadb-operator.yml        (Phase 3)
zeus-k8s/argocd/applications/mariadb-mixpost.yml         (Phase 3)
zeus-k8s/argocd/applications/mixpost.yml                 (Phase 3)
zeus-k8s/argocd/applications/<22 backfilled apps>.yml    (Phase 5)
hack/backfill-argocd-apps.sh                             (Phase 5, optional-commit)
```

No existing files are modified — new scaffolding only.

## Verification checklist

* [ ] Phase 1: 27 live-state app yamls + project yaml captured in `/tmp/argocd-pre/`.
* [ ] Phase 2: `root.yml`, `projects/`, `_TEMPLATE.yml` merged to main. `kubectl -n argocd get app` still shows 27.
* [ ] Phase 3: 5 child yamls merged. `diff` against `/tmp/argocd-pre/apps/` for `newt`/`valkey` shows only approved additions.
* [ ] Phase 4: `kubectl apply -f root.yml` done. `root` Healthy. 30 apps total, all Synced/Healthy.
* [ ] Phase 5: 22 backfilled yamls merged. 30 apps still Synced/Healthy. `grep sync-wave zeus-k8s/argocd/applications/*.yml | wc -l` = 30.
* [ ] Phase 6: misspelled app deleted, `Prune=false` on `namespaces` + `cnpg-image-catalogs`, deletion-protection on root, README in place.
* [ ] Phase 7: kind-based DR test passes. Sync-wave order observed.

## Open decisions for user

These are embedded defaults; override in conversation if different:

1. **Sync wave for `cloudflare-ingress`** — placed at wave 20 (before
   gitlab-runners) because it's a Helm wrapper for cloudflared and may host
   ingress objects. If it pure-ingresses traffic after gitlab-runners are
   up, move to wave 35. *Default*: 20.
2. **`Prune=false` on `namespaces` and `cnpg-image-catalogs`** — adds manual
   friction to namespace/catalog deletion. *Default*: enable; override if
   you want full automation.
3. **`argocd.argoproj.io/deletion-protection` annotation** — ArgoCD 2.13+
   feature. *Default*: add to `root.yml` only; ignore if your version is
   older (annotation is harmless).
4. **Committing `hack/backfill-argocd-apps.sh`** — one-shot script.
   *Default*: commit it anyway so future cluster rebuilds can rerun it.
