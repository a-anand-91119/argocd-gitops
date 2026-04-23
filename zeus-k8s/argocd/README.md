# ArgoCD App-of-Apps

## Overview

This directory is the declarative root of the zeus cluster. A single root
`Application` (`root.yml`) watches `zeus-k8s/argocd/applications/` and treats
every `.yml` file there (except `_`-prefixed templates) as a child
`Application`. Children own individual services; the root owns the children.
A full cluster rebuild reduces to two `kubectl apply` calls plus waiting for
sync-wave ordering to play out.

See `docs/plans/argocd-app-of-apps.md` for design rationale and the full risk
register (R1-R14).

## Quickstart

The scaffold in this directory is **committed but not applied** until Phase 4
of the migration. Once activated, a cluster rebuild is:

```bash
# 1. Seed the AppProject (safety boundary for all children)
kubectl apply -f zeus-k8s/argocd/projects/zeus-kubernetes.yml

# 2. Apply the root Application -- children materialize on the next sync
kubectl apply -f zeus-k8s/argocd/root.yml
```

**Before running the above on a wiped cluster:** the active sealed-secrets
private key must be restored to `kube-system` from Vault first, or every
child that unseals a `SealedSecret` will fail. Full procedure: Phase 7 /
DR-03 runbook.

Watch progress:

```bash
argocd app get root
kubectl -n argocd get app -w
```

## Adding an app

1. Copy the template, dropping the leading underscore:

   ```bash
   cp zeus-k8s/argocd/applications/_TEMPLATE.yml \
      zeus-k8s/argocd/applications/<app-name>.yml
   ```

   Filename MUST end in `.yml` (not `.yaml`) -- root's
   `directory.exclude: "_*.yml"` glob is extension-sensitive.

2. Edit the new file: fill `<APP_NAME>`, `<PATH>`, `<DEST_NAMESPACE>`, and
   pick a `<WAVE>` from the bands below. Delete commented blocks you don't
   use.

3. Sync-wave bands (gaps of 5 leave room for future insertions):

   | Wave | Band                       |
   | ---- | -------------------------- |
   | -30  | sealed-secrets             |
   | -25  | namespaces                 |
   | -20  | secrets                    |
   | -15  | operators                  |
   | -10  | infra (storage, networking) |
   | -5   | tunnels                    |
   | 0    | vault                      |
   | +5   | CRs (custom resources)     |
   | +10  | databases                  |
   | +15  | middleware                 |
   | +20  | ingress adjacency          |
   | +25  | runners                    |
   | +30  | apps                       |
   | +35  | ingresses                  |

4. `git commit` + push. Root will sync the new child on its next
   reconciliation cycle.

## Rebuilding the cluster

Cold-start from a wiped cluster (order matters):

1. **Restore the sealed-secrets private key** to `kube-system` from Vault.
   Without this, every child with a `SealedSecret` fails to unseal. See
   Phase 7 / DR-03 runbook for the full procedure.

2. **Recreate the git-repo SSH secret** used by ArgoCD to pull this repo.
   It must carry `argocd.argoproj.io/secret-type: repository`. See Phase 7 /
   DR-01 and DR-02 runbooks.

3. **Apply the AppProject** (safety scope for all children):

   ```bash
   kubectl apply -f zeus-k8s/argocd/projects/zeus-kubernetes.yml
   ```

4. **Apply the root Application:**

   ```bash
   kubectl apply -f zeus-k8s/argocd/root.yml
   ```

5. **Watch sync-waves unspool.** Expect this ordering (roughly):
   `-30 sealed-secrets -> -25 namespaces -> -20 secrets -> -15 operators ->`
   `+5 CRs -> +10 databases -> +30 apps -> +35 ingresses`. Each wave finishes
   before the next begins.

## Troubleshooting

**Root app shows `OutOfSync`:**
Check the last few commits on `main` (`git log --oneline -n 5`). If a child
file was added/edited, root should auto-sync on the next poll. Force a
refresh with `argocd app get root --refresh`. If something is genuinely
broken, inspect `argocd app diff root` for the offending resource.

**A newly-committed child does not appear in the cluster:**
Three common causes, in order of frequency:

- The filename starts with `_`. Root's `exclude: "_*.yml"` skips it.
- The filename ends in `.yaml` instead of `.yml`. The exclude glob is
  extension-sensitive, but so is the include path -- ArgoCD will process
  `.yaml` files too, but if you *copied* `_TEMPLATE.yaml` the underscore
  prefix means it is skipped. Rename to `<name>.yml`.
- The file is in a subdirectory. Root has `directory.recurse: false`.
  Children must be flat under `applications/`.

**Fear of accidentally deleting root (cascade-delete anxiety):**
Always delete with `--cascade=orphan` if you ever need to remove root:

```bash
kubectl -n argocd delete app root --cascade=orphan
```

Root has no `resources-finalizer.argocd.argoproj.io` by design -- a naive
`kubectl delete` without the flag would still leave children orphaned
rather than cascade, but the flag makes the intent explicit. Children
keep running; you can re-apply root to re-adopt them.

**Children not being garbage-collected on delete:**
Unlike root, children DO carry `resources-finalizer.argocd.argoproj.io`
(from `_TEMPLATE.yml`). `kubectl delete app <name>` will block until
ArgoCD cleans up the child's managed resources. If a child is stuck
terminating, check the ArgoCD controller logs -- usually a
still-referenced CR blocking finalization.

## Note on deletion-protection (HRD-04)

`root.yml` carries `argocd.argoproj.io/deletion-protection: "true"`. On ArgoCD
2.14+ this annotation prevents `kubectl delete app root` from succeeding without
explicit override. On this cluster's ArgoCD 2.12.4 the annotation is harmless
metadata; real enforcement requires an upgrade.

Until the 2.14+ upgrade, the primary R2 (cascade-delete) mitigation rests on
`root.yml` deliberately OMITTING the `resources-finalizer` — deleting the root
Application with default `--cascade=foreground` orphans children rather than
destroying them. See the top-of-file comment in `root.yml` and the project
safety section of this README for the full rationale.

On upgrade to 2.14+, additionally consider `sync-options: Delete=confirm` for
belt-and-braces protection.
