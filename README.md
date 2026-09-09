# Platform Fleet POC - Flux v2 & Cluster Onboarding

This is a Proof of Concept (POC) for **automated, GitOps-based Kubernetes fleet management** using Flux CD v2. One Git repository (this one, branch-based) is the single source of truth for what runs on every cluster in the fleet; each cluster continuously pulls and reconciles its own desired state from Git - nobody ever runs `kubectl apply` by hand against a cluster.

## Why GitOps / why Flux

- **Pull-based, not push-based**: clusters pull their config from Git on an interval (no CI system needs network access *into* the cluster, which is a much smaller attack surface than a push-based pipeline with cluster credentials).
- **Git is the audit log**: every change to any cluster's state is a commit, reviewable via PR, revertible via `git revert`.
- **Self-healing**: if someone manually changes something in-cluster (drift), Flux reconciles it back to what Git says on the next interval.
- **Multi-cluster at scale**: one repo, one bootstrap script, N clusters - each cluster only reads its own `clusters/<prod|non-prod>/<name>/` folder.

## What Flux actually installs (the pods you'll see)

`flux bootstrap` installs these controllers as Deployments (1 pod each) in the namespace you choose (here: `flux-kpc`):

| Controller | What it watches | What it does |
|---|---|---|
| `source-controller` | `GitRepository`, `HelmRepository`, `Bucket` CRs | Clones/polls the Git repo (or Helm repo/bucket) on `spec.interval`, produces a versioned artifact (tarball) other controllers consume. This is the only controller that ever talks to GitHub. |
| `kustomize-controller` | `Kustomization` CRs | Takes the artifact from a `GitRepository`, runs `kustomize build` on `spec.path`, and applies the resulting manifests to the cluster. Supports `dependsOn` (e.g. `apps` waits for `infrastructure`) and `prune: true` (deletes resources removed from Git). |
| `helm-controller` | `HelmRelease` CRs | Installs/upgrades Helm charts sourced from a `HelmRepository`/`GitRepository`. Not used yet in this POC (no `HelmRelease` objects defined), but installed by default. |
| `notification-controller` | `Alert`/`Provider`/`Receiver` CRs | Sends reconciliation events to external systems (Slack, webhooks) and can receive push-triggered reconciliation requests. Not configured yet, installed by default. |

Check what's actually running at any time:
```bash
kubectl get pods -n flux-kpc
kubectl get gitrepositories,kustomizations -n flux-kpc -o wide
```

### How self-management works (the `flux-kpc` folder)

`flux bootstrap` also commits a `clusters/<prod|non-prod>/<name>/flux-kpc/` folder back into this repo containing:
- `gotk-components.yaml` - the controllers themselves (CRDs, RBAC, Deployments) - this is what gets swapped out on a Flux version upgrade.
- `gotk-sync.yaml` - a `GitRepository` + `Kustomization` (both named after the namespace, e.g. `flux-kpc`) that make Flux track and re-apply **this same repo** going forward - including its own future upgrades. This is why bootstrap only needs to run once; after that, Flux manages itself via Git.

These files are marked "DO NOT EDIT" because `flux bootstrap` regenerates them - but they're plain Kubernetes manifests, so hand-editing (e.g. fixing `spec.path` after a directory rename) is safe when needed; the next real bootstrap run will just regenerate them from the same inputs.

## Repository layout

### Folder structure

```
platform-fleet-poc/
├── clusters-config.yaml        # Central config: WHAT + WHEN + WHICH VERSION per cluster
├── onboard-clusters.sh         # Reads clusters-config.yaml, runs `flux bootstrap` per cluster
├── catalog/                    # Source of truth for "validated" (see Catalog hierarchy below)
│   ├── flux.yaml               # kind: flux  - Flux version per group
│   ├── prometheus.yaml         # kind: helm  - kube-prometheus-stack chart version per group
│   ├── opencost.yaml           # kind: helm  - OpenCost chart version per group
│   ├── podinfo.yaml            # kind: image - Container image tag per group
│   ├── whoami.yaml             # kind: image - Container image tag per group
│   ├── promote-flux-release.sh # git-commit-only: catalog -> gotk-components.yaml
│   └── promote-app-release.sh  # git-commit-only: catalog -> apps/base/<app>/images
├── clusters/                   # Per-cluster Flux entry points (self-management folders)
│   ├── non-prod/
│   │   └── azr-cru-0001-k01/   # Cluster instance: declares group + sku
│   │       ├── infrastructure.yaml  # Kustomization: points to infra/overlays/<group>-<sku>
│   │       ├── k8s-apps.yaml        # Kustomization: points to apps/overlays/<group>-<sku>
│   │       └── flux-kpc/            # (DO NOT EDIT) Flux self-management: gotk-*, gotk-sync.yaml
│   └── prod/                   # prod clusters (none onboarded yet)
├── infrastructure/             # Cluster infrastructure Kustomizations
│   ├── base/                   # Universal layer: namespaces, RBAC, add-ons
│   │   └── namespaces.yaml
│   ├── overlays/               # Per-group Kustomizations
│   │   ├── control-plane/          # Group overlay + group-specific namespaces + HelmRepositories
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespaces.yaml
│   │   │   └── sources/
│   │   │       └── sources.yaml (HelmRepositories: prometheus-community, opencost)
│   │   ├── control-plane-sku1/     # Sizing profile: pass-through to control-plane
│   │   └── control-plane-sku2/     # Sizing profile: worked example (higher resources)
│   └── sources/                # Shared HelmRepository/GitRepository definitions
└── apps/                       # Application Kustomizations
    ├── base/                   # Universal app catalog
    │   ├── whoami/
    │   ├── podinfo/
    │   └── external-secrets-operator/
    └── overlays/               # Per-group app Kustomizations
        ├── control-plane/          # Group overlay: which apps + HelmReleases
        │   ├── kustomization.yaml
        │   ├── prometheus/
        │   │   └── helmrelease.yaml  # Prometheus 90.0.0
        │   └── opencost/
        │       └── helmrelease.yaml  # OpenCost 2.5.30
        ├── control-plane-sku1/     # Sizing profile: pass-through to control-plane
        └── control-plane-sku2/     # Sizing profile: increased replicas (whoami: 5)
```

### Reference flow

```mermaid
graph TD
    A["clusters/non-prod/azr-cru-0001-k01/"] 
    B["infrastructure.yaml"]
    C["k8s-apps.yaml"]
    D["overlays/control-plane/"]
    E["overlays/control-plane/"]
    F["base/ + sources/"]
    G["HelmRelease: Prometheus<br/>HelmRelease: OpenCost"]
    
    A --> B
    A --> C
    B --> D
    D --> F
    C --> E
    E --> G
    C -->|dependsOn| B
    
    style A fill:#ff9800
    style B fill:#2196F3
    style C fill:#2196F3
    style D fill:#4CAF50
    style E fill:#4CAF50
    style G fill:#9C27B0
```

Each cluster's `infrastructure.yaml` and `k8s-apps.yaml` Kustomizations point `sourceRef: flux-kpc` and `path:` at their group-sku overlay (`infrastructure/overlays/<group>-<sku>` / `apps/overlays/<group>-<sku>`). `k8s-apps` has `dependsOn: [infrastructure]`, so apps wait for infrastructure to be healthy before applying.

## Architecture decisions

### Kustomization Dependency Graph

```mermaid
graph TD
    A["clusters/non-prod/azr-cru-0001-k01/"] 
    
    A --> B["infrastructure.yaml"]
    A --> C["k8s-apps.yaml"]
    
    B --> D["infrastructure/overlays/control-plane/"]
    B --> E["infrastructure/sources/"]
    
    D --> F["infrastructure/base/"]
    D --> G["kustomization.yaml<br/>resources:<br/>- ../base<br/>- ../sources"]
    
    E --> H["HelmRepository<br/>prometheus-community<br/>opencost"]
    
    C --> I["apps/overlays/control-plane/"]
    
    I --> J["apps/base/"]
    I --> K["kustomization.yaml<br/>resources:<br/>- prometheus<br/>- opencost"]
    
    K --> L["Prometheus 90.0.0<br/>HelmRelease"]
    K --> M["OpenCost 2.5.30<br/>HelmRelease<br/>dependsOn: infrastructure"]
    
    L --> N["kube-prometheus-stack"]
    M --> N
    
    style A fill:#ff9800
    style B fill:#2196F3
    style C fill:#2196F3
    style D fill:#4CAF50
    style I fill:#4CAF50
    style L fill:#9C27B0
    style M fill:#9C27B0
    style N fill:#f44336
```

**Flow:**
1. **Flux reads cluster entry point** → `clusters/non-prod/azr-cru-0001-k01/`
2. **Two independent Kustomizations:**
   - `infrastructure.yaml` → deploys base infra + HelmRepositories
   - `k8s-apps.yaml` → waits for infrastructure, then deploys Prometheus + OpenCost
3. **Each points to its overlay** → which composes base + sources
4. **HelmReleases** consume charts from HelmRepositories
5. **OpenCost depends on Prometheus** → Flux health check waits for both Ready

### 1. `group` (control-plane / resource-plane) → WHAT a cluster runs

Every cluster declares a `group` in `clusters-config.yaml`. The group name must match a folder under `infrastructure/overlays/<group>/` and `apps/overlays/<group>/`. This is pure Kustomize overlay composition - no Flux-specific magic, just "which subset of the catalog does this class of cluster get".

### 2. Promotion is branch-only → WHEN a cluster picks up changes
`git_ref_type` is always `branch`; `git_ref` is the branch name a cluster tracks:
- `environment: dev` → `git_ref: flux` (fast-moving, latest commit)
- `environment: prod` → `git_ref: flux-prod` (a separate long-lived branch, only fast-forwarded/merged from `flux` when a change has been validated on dev)

Promoting to prod: `git checkout flux-prod && git merge flux && git push`.

**We evaluated and rejected tag/semver-based promotion.** The original design used a second, hand-authored `GitRepository` (`fleet-source`) pinned to a git tag/semver range, so a cluster would only pick up a manually-promoted, known-good snapshot instead of every commit on a branch. In practice this hit a real, reproducible bug: Flux's `source-controller` (go-git) fails to checkout **annotated** tags (`git tag -a`, the kind `git tag` creates by default) with `unable to checkout tag 'vX.Y.Z': worktree contains unstaged changes` - restarting the controller pod did not fix it. Rather than depend on lightweight tags only (fragile, easy to get wrong) or debug a third-party library bug, we moved the same "promote only when ready" guarantee to branches instead, which Flux supports natively and robustly.

### 3. `clusters/prod/` vs `clusters/non-prod/` → where a cluster's manifests live
Derived automatically from `environment` in `onboard-clusters.sh` (`prod` → `clusters/prod/<name>/`, anything else → `clusters/non-prod/<name>/`). No separate path field to keep in sync - one less place to make a mistake.

### 4. `sku` (sku1 / sku2 / ...) → HOW MUCH a cluster runs, within a group

A `group` (control-plane / resource-plane) says *which* base infra + apps a cluster gets. It doesn't say *how big*. Real fleets rarely have just one flavor of "resource-plane" - some spoke clusters are small dev sandboxes, others need more replicas/resources for load testing, without being a different `group` (they still run the exact same set of apps/infra). `sku` is that second, independent axis, layered *inside* a group:

```
infrastructure/overlays/resource-plane/        # the group overlay - common to every sku
infrastructure/overlays/resource-plane-sku1/   # -> resources: [../resource-plane]  (pass-through)
infrastructure/overlays/resource-plane-sku2/   # -> resources: [../resource-plane]  (+ patches)
```

`clusters-config.yaml` gets a `sku` field alongside `group`; a cluster's `infrastructure.yaml`/`apps.yaml` `path` points at `overlays/<group>-<sku>` instead of just `overlays/<group>`. Two things worth calling out:

- **Naming is flat/hyphenated (`resource-plane-sku1`), never nested (`resource-plane/sku1`).** Kustomize's loader refuses to build an overlay that lives inside the very directory it lists as a `resources:` entry - it flags it as a cycle (`cycle detected: candidate root '.../resource-plane' contains visited root '.../resource-plane/sku1'`), verified empirically while building this out. Sku overlays must be siblings of the group overlay, referencing `../<group>`.
- **A sku overlay only ever adds what's different**, using Kustomize's own transformers - e.g. `replicas:` to bump a replica count (see `apps/overlays/resource-plane-sku2`, which bumps `whoami` to 5 replicas vs. the base's 3) - never a copy of the underlying manifest. `resource-plane-sku2` today is a worked example only (no cluster uses it yet); `resource-plane-sku1` is what `kind-dev`/`aks-dev` actually run, and it's a pure pass-through (no differences from the group overlay yet).

This scales the same way `group` does: the number of overlay folders grows with `groups × skus` (a small, fixed set of profiles), never with the number of clusters - N clusters can share one `group`+`sku` combination.

### 5. Version catalog, per group → decoupling in-cluster Flux from the operator's laptop
`flux bootstrap` without `--version` installs whatever toolkit version matches the locally-installed `flux` CLI binary. That means a `brew upgrade flux` on someone's machine, followed by an unrelated re-run of the onboarding script, could silently upgrade a cluster's Flux controllers - including prod - with zero review. Instead of a `flux_version` field hand-copied onto every cluster in `clusters-config.yaml` (one more place to forget to update, and no shared "this is the version we've actually validated" concept), the Flux version lives in one place: [`catalog/flux.yaml`](catalog/flux.yaml). It defines named `releases` (today: just a Flux version, but the shape is a map so a release can grow to bundle more later) and a `validated` map pointing each cluster `group` at the release it's currently pinned to. `onboard-clusters.sh` only ever *reads* this file (to bootstrap a brand-new cluster); it never writes to it and never upgrades an already-bootstrapped cluster.

Upgrading is a separate, explicit act: bump `validated.<group>` in the catalog, then run `catalog/promote-flux-release.sh <group>`. That script never touches a cluster - it re-renders `gotk-components.yaml` locally via `flux install --export` (a pure manifest-templating call, no cluster/network contact) and commits+pushes the result. The actual upgrade happens when each cluster's own already-running `flux-kpc` self-management `Kustomization` reconciles that commit on its normal interval (or immediately via `flux reconcile kustomization flux-kpc -n <namespace> --with-source`) - a pull, not a push. Validate on a non-prod group first, then merge `flux` → `flux-prod` to carry the same validated release to prod groups.

### 6. Per-cluster, self-managed Flux → **we evaluated and rejected hub/spoke (remote cluster) management**

Every onboarded cluster (`kind-dev`, `aks-dev`, and any future one) bootstraps and self-manages **its own** Flux instance - its own `flux-kpc` namespace, its own `GitRepository`, its own `infrastructure`/`apps` `Kustomization`s pulling from this repo. That's why a physical, per-cluster folder under `clusters/<prod|non-prod>/<name>/` is required (see the folder-layout discussion above): each cluster's self-management `Kustomization` has a static `path` baked in at bootstrap time, and there's no cross-cluster templating at the Flux CR level in this model.

**The alternative we looked at**: a hub/spoke ("remote cluster") setup, where Flux is installed **once**, in a hub (`control-plane`) cluster, and that single hub Flux manages every spoke remotely via `Kustomization.spec.kubeConfig.secretRef` pointing at each spoke's kubeconfig. This is a real, supported Flux pattern, and it would remove the per-spoke Flux install + most of the per-cluster folder duplication (many spokes with identical `group`/`sku` could share far more of their definition, generated/templated from one list instead of N bootstrapped instances).

**Why we didn't adopt it (for now)**:
- **It re-introduces exactly the risk GitOps/Flux was chosen to avoid.** The whole rationale in "Why GitOps / why Flux" above is pull-based reconciliation with no external system holding push credentials into a cluster. Hub/spoke flips that for the hub itself: it has to hold live API credentials (kubeconfigs) for *every* spoke, so a compromised hub is a compromised fleet - a much bigger blast radius than today's model, where compromising one cluster's `flux-kpc` only affects that one cluster.
- **Not needed at this scale.** With 1-2 non-prod clusters and no prod cluster onboarded yet, the maintenance pain hub/spoke would solve (N nearly-identical per-cluster folders) isn't real yet - it's cheaper to solve that specific problem by generating the per-cluster boilerplate from `clusters-config.yaml` (see folder-layout discussion) than to change the trust model of the whole fleet.
- **Revisit trigger**: if the fleet grows to a size where per-cluster-folder duplication is genuinely painful even after generating it from the config list, or if there's a real need for centralized fleet operations (e.g. a Rancher/ArgoCD-ApplicationSet-style controller), hub/spoke is the natural next step - and it's exactly the role already reserved conceptually for the `control-plane` group. Not ruled out permanently, just not justified yet.

## Catalog hierarchy - the enterprise control this repo is built around

**The catalog is the only place "validated" / "usable" is decided. Everything else in this repo only ever *points into* the catalog - nothing else is allowed to independently decide what version of anything is good.**

### Decision tree: clusters-config → environment → group → catalog

```mermaid
graph TD
    A["📋 clusters-config.yaml<br/>(cluster inventory)"]
    
    A -->|environment| B{"prod or<br/>non-prod?"}
    B -->|non-prod| BR["🌳 git_ref: flux<br/>(testing branch)"]
    B -->|prod| BP["🌳 git_ref: flux-prod<br/>(stable branch)"]
    
    A -->|group| G{"control-plane or<br/>resource-plane?"}
    G -->|control-plane| OV1["📁 apps/overlays/control-plane/<br/>📁 infra/overlays/control-plane/"]
    G -->|resource-plane| OV2["📁 apps/overlays/resource-plane/<br/>📁 infra/overlays/resource-plane/"]
    
    A -->|sku| S{"sku1 or<br/>sku2?"}
    S -->|sku1| SK1["pass-through<br/>(no changes)"]
    S -->|sku2| SK2["custom sizing<br/>(patches)"]
    
    OV1 -->|all apps read| CAT["📦 catalog/"]
    OV2 -->|all apps read| CAT
    
    CAT -->|control-plane group<br/>gets these versions| CP["flux.yaml validated.control-plane: v2.9.3<br/>prometheus.yaml validated.control-plane: 2026.07.1<br/>opencost.yaml validated.control-plane: 2026.07.1<br/>podinfo.yaml validated.control-plane: v6.14.1<br/>whoami.yaml validated.control-plane: v1.11.0"]
    
    CAT -->|resource-plane group<br/>gets these versions| RP["flux.yaml validated.resource-plane: v2.8.0<br/>prometheus.yaml validated.resource-plane: 2026.06.1<br/>podinfo.yaml validated.resource-plane: v6.13.0<br/>whoami.yaml validated.resource-plane: v1.10.0"]
    
    BR -->|pulls from| NC["clusters/non-prod/<br/>azr-cru-0001-k01"]
    BP -->|pulls from| PC["clusters/prod/<br/>[clusters here]"]
    
    NC --> CP
    PC --> CP
    
    style A fill:#FFECB3
    style B fill:#E1F5FE
    style G fill:#E1F5FE
    style S fill:#E1F5FE
    style BR fill:#BBDEFB
    style BP fill:#FFCCBC
    style CAT fill:#FFF8E1
    style CP fill:#C8E6C9
    style RP fill:#C8E6C9
```

Every catalog file, regardless of what it catalogues, follows the same two-part shape:
- `releases`: every version/image that has ever existed as a candidate (a named, immutable historical record - never delete an entry, a rollback is just pointing `validated` at an older one).
- `validated`: a map of `group -> release id` - the **only** mutable pointer, and the only thing a promotion (`catalog/promote-flux-release.sh` / `catalog/promote-app-release.sh`) ever changes. "Validated" always means *reconciled and all checks green on a non-prod cluster in that group* - never just "someone typed a new version".

What differs between catalog files is only **`kind`** - what a release actually pins, because different delivery mechanisms need different data:

| `kind` | Used by | What a release pins | Why |
|---|---|---|---|
| `flux` | [`catalog/flux.yaml`](catalog/flux.yaml) | `flux_version` + a top-level `registry`/`images` list (repository names only, no tags) | Installed via `flux install`/`flux bootstrap`, which resolves each controller's own image tag internally for the given version (4 controllers, 4 independent tags that don't match `flux_version` 1:1) - hand-pinning those tags here would drift; the resolved tags always live in the committed `gotk-components.yaml` per cluster. |
| `helm` | [`catalog/prometheus.yaml`](catalog/prometheus.yaml), [`catalog/opencost.yaml`](catalog/opencost.yaml) | `chart_name` + `chart_version` + `chart_repo` | A `HelmRelease` + `HelmRepository` resolve the actual container image(s) internally, so pinning one separately here would be redundant - only the chart version needs pinning. Helm chart values are stored per-group in `apps/overlays/<group>/<app>/helmrelease.yaml`. |
| `image` | [`catalog/podinfo.yaml`](catalog/podinfo.yaml), [`catalog/whoami.yaml`](catalog/whoami.yaml) | `registry` + `repository` + `tag` (or `digest`) | Plain Kubernetes `Deployment`, no Helm chart in the loop - the catalog itself is the only record of which container image is actually running. |

### How the catalog works

Each catalog file (`catalog/flux.yaml`, `catalog/prometheus.yaml`, etc.) represents one **cataloged component** (system component, Helm add-on, or app image) and has this shape:

```yaml
kind: flux              # or: helm, image
releases:
  v2.9.3: {version: v2.9.3, ...}           # immutable historical record
  v2.8.0: {version: v2.8.0, ...}           # older versions stay for rollback
validated:
  control-plane: v2.9.3                     # this group runs v2.9.3
  resource-plane: v2.8.0                    # this group runs v2.8.0 (slower adoption)
```

- **`releases:`** — every version that has ever been a candidate (never deleted, enables rollback)
- **`validated:`** — the only mutable pointer; maps each `group` → validated release; promotion bumps this by one line

**Important**: `validated` is per-GROUP, not per-cluster. All clusters in `control-plane` run the same version. All clusters in `resource-plane` run the same version. This is what keeps versions auditable (one line in one file) and prevents version sprawl.

### Catalog contents in this fleet

**System (`kind: flux`)**
- [`catalog/flux.yaml`](catalog/flux.yaml) — Flux CD controller versions (v2.9.3, v2.8.0, ...)

**Helm add-ons (`kind: helm`)**
- [`catalog/prometheus.yaml`](catalog/prometheus.yaml) — kube-prometheus-stack chart version (90.0.0, ...)
- [`catalog/opencost.yaml`](catalog/opencost.yaml) — OpenCost chart version (2.5.30, ...)

**Container images (`kind: image`)**
- [`catalog/podinfo.yaml`](catalog/podinfo.yaml) — Podinfo image tag (v6.14.1, v6.13.0, ...)
- [`catalog/whoami.yaml`](catalog/whoami.yaml) — Whoami image tag (v1.11.0, v1.10.0, ...)

**Deployment method** (Kustomize + Helm)
- Image apps: `apps/base/{podinfo,whoami}` → Kustomize overlays consume catalog image tags via `images:` transformer
- Helm apps: `apps/overlays/{control-plane,resource-plane}/{prometheus,opencost}` → HelmRelease `spec.chart.spec.version` reads from catalog

### How versions flow: Catalog → Branch → Cluster

1. **Bump catalog** (e.g., `catalog/prometheus.yaml`)
   ```yaml
   validated:
     control-plane: 2026.07.1  # ← new release, ready for testing
   ```

2. **Commit to `flux` branch** (non-prod testing)
   - Non-prod clusters pull changes from `flux` branch
   - Prometheus HelmRelease reconciles with new version 2026.07.1
   - Validate that it works (status checks, dashboards, etc.)

3. **Merge `flux` → `flux-prod`** (promote to prod)
   - `git checkout flux-prod && git merge flux && git push`
   - Prod clusters pull from `flux-prod` branch
   - Prod Prometheus clusters upgrade to 2026.07.1

4. **Rollback** (if needed)
   - `git revert <commit>` in `flux-prod`
   - Prod clusters automatically reconcile to previous version
   - No manual cluster operations needed

**Does this scale?** Yes, for the dimension that actually matters: the number of *independently-versioned things*, not the number of clusters. One file per app/thing keeps release history in its own small, low-conflict diff, and a cluster's actual version is still just one pointer lookup (`validated.<group>`) regardless of how many clusters share that group.

## Future needs (known gaps, out of scope for this POC/HLD)

This POC intentionally stops at "enough to prove the GitOps + catalog control model end-to-end with public images". The following are real gaps for anything beyond that, called out explicitly so they aren't mistaken for oversights:

- **Private registry credentials (`imagePullSecrets`)**: every image today is public (Docker Hub) - nothing in this repo pulls a secret to authenticate to a registry yet. Once a private/internal registry is in the picture, the natural extension is an optional field per `kind: image` catalog entry (e.g. `pullSecret: <k8s-secret-name>`), referenced by the app's `Deployment.spec.imagePullSecrets` (or centrally via the namespace's default `ServiceAccount`). The secret itself shouldn't be committed to Git in any form - this is exactly what the already-placeholder [`apps/base/external-secrets-operator`](apps/base/external-secrets-operator) is for (sync it from a real secret store rather than hand-creating `kubectl create secret docker-registry`), so wiring registry credentials through should piggy-back on that once it's built out, not invent a second mechanism.
- **Helm `values` management for `kind: helm` releases**: the catalog pins only `chart_version`; per-group `values` overrides live in `apps/overlays/<group>/<app>/helmrelease.yaml` (current implementation). At real scale, large multi-group deployments might benefit from a `catalog/` entry for `values` alongside chart version - not designed yet, since today's per-overlay storage is clear and conflict-free.
- **Air-gapped / offline delivery (packaging as `.tgz` or mirroring images)**: this POC assumes clusters can reach the public internet (Docker Hub, GHCR, the Flux install source) directly. A disconnected environment would need charts packaged via `helm package` and images mirrored into a reachable registry (e.g. `skopeo`/`crane`/`helm push` to an OCI registry, or a bundling tool like Zarf/Hauler) - the catalog's `registry`/`repository` fields are exactly what such a mirroring step would need to read and rewrite, but no mirroring automation exists today.
- **Catalog schema validation in CI**: still just an idea (see the `kind`/`releases`/`validated` shape above) - a malformed catalog file would currently fail silently or late (inside a promote script) rather than at PR time. A lightweight CI check (`yq`/JSON-schema per `kind`) should validate every `catalog/**/*.yaml` before merge.
- **Registry-watching automation**: `releases` entries are hand-typed today. At real scale, a tool that watches the registry (Flux's own `ImageRepository`/`ImagePolicy`/`ImageUpdateAutomation` controllers, or Renovate) should propose new `releases` as PRs when a new image/chart version is published - a human should only ever move the `validated` pointer, never hand-type a tag or digest.



```bash
# 1. Set GitHub token (needs repo read/write on victorrodriguez1984/kubernetes-ready)
export GITHUB_TOKEN=your_token

# 2. Edit cluster configuration (enable clusters, set group/environment/git_ref/flux_version)
vi platform-fleet-poc/clusters-config.yaml

# 3. Run onboarding script (installs Flux v2 via bootstrap, idempotent)
./platform-fleet-poc/onboard-clusters.sh                  # all enabled clusters
./platform-fleet-poc/onboard-clusters.sh kind-dev          # just one cluster
./platform-fleet-poc/onboard-clusters.sh kind-dev --force  # force reinstall
```

See [SETUP.md](SETUP.md) for more detailed step-by-step instructions (note: predates the `environment`/branch-promotion/`flux_version` fields described above - `clusters-config.yaml`'s own header comments are the source of truth for the current schema).

## Verification

```bash
kubectl get gitrepositories,kustomizations -n flux-kpc -o wide   # all should be READY: True
kubectl get pods -n flux-kpc                                     # 4 controller pods running
flux check                                                        # controller health + version
```

## Troubleshooting

Use this order by default: run non-disruptive checks first, then controlled reconcile actions, and only then disruptive recovery actions if needed.

### Non-disruptive checks

```bash
# Cluster and Flux health
kubectl get ns
kubectl get pods -A
kubectl get pods -n flux-kpc
kubectl get gitrepositories,kustomizations -n flux-kpc -o wide
kubectl get kustomizations -n flux-kpc -o wide
kubectl get helmreleases -A
flux check

# Object details and last errors
kubectl describe kustomization apps -n flux-kpc | tail -30
kubectl describe kustomization infrastructure -n flux-kpc | grep "revision:\|Applied" | head -3
kubectl describe gitrepository flux-kpc -n flux-kpc | grep -i "commit\|revision"

# Controller and workload logs
kubectl logs -n flux-kpc deployment/kustomize-controller --tail=50 | grep -i "apps\|error"
kubectl logs -n flux-kpc deployment/source-controller --tail=20
kubectl logs -n finops-opencost -l app=opencost --tail=30

# Helm/chart inspection (render/values only)
helm show values opencost/opencost --version 2.5.30
helm template opencost opencost/opencost --version 2.5.30 -n finops-opencost --values -

# Git state correlation
git log --oneline -5
git rev-parse HEAD
```

### Controlled reconcile actions (low impact, but can trigger changes)

```bash
# Force immediate reconcile from source
flux reconcile kustomization apps -n flux-kpc --with-source
flux reconcile kustomization infrastructure -n flux-kpc --with-source

# Restart source pull loop without deleting resources
kubectl -n flux-kpc patch gitrepository flux-kpc -p '{"spec":{"suspend":true}}' --type merge
kubectl -n flux-kpc patch gitrepository flux-kpc -p '{"spec":{"suspend":false}}' --type merge

# Temporarily pause/resume apps reconciliation
kubectl -n flux-kpc patch kustomization apps -p '{"spec":{"suspend":true}}' --type merge
kubectl -n flux-kpc patch kustomization apps -p '{"spec":{"suspend":false}}' --type merge
```

### Disruptive actions (last resort)

```bash
# Deletes/recreates reconciliation objects
kubectl delete kustomization apps -n flux-kpc
kubectl delete kustomization apps -n flux-kpc --force --grace-period=0
kubectl patch kustomization apps -n flux-kpc -p '{"metadata":{"finalizers":[]}}' --type merge

# Helm/OpenCost direct interventions (outside desired-state flow)
kubectl delete helmrelease opencost -n finops-opencost
helm uninstall opencost -n finops-opencost
helm install opencost opencost/opencost -n finops-opencost --create-namespace
helm upgrade opencost opencost/opencost -n finops-opencost

# Workload restarts / imperative patching
kubectl delete pods -n finops-opencost --all
kubectl patch deployment opencost -n finops-opencost --type json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/env/1/value","value":"http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090"}]'
kubectl edit deployment opencost -n finops-opencost
```

### Safety notes

- Prefer Git changes + Flux reconcile over direct `kubectl edit/patch` on managed resources.
- If you use disruptive commands, capture `kubectl get ... -o wide` and `kubectl describe ...` before/after to preserve incident context.
- After recovery, align live state back to Git to avoid drift on next reconcile.

## Governance

- **Ownership**: [`.github/CODEOWNERS`](../.github/CODEOWNERS) documents which paths belong to which owner. Currently everyone maps to a single owner (no team split yet), but the granularity (per-cluster, per-overlay, shared `base/`) is already in place so splitting review responsibility later is a one-line change per row.
- **Promotion is branch-only**: every cluster's `git_ref_type` is `branch`; dev clusters track the `flux` branch, prod clusters track the `flux-prod` branch (`clusters-config.yaml`'s `git_ref` field). Promoting to prod means merging/fast-forwarding `flux` into `flux-prod` (`git checkout flux-prod && git merge flux && git push`) once changes are validated on dev - see the comments at the top of `clusters-config.yaml` for the full mechanism.
- **Folder layout**: `clusters/non-prod/<name>/` for dev-type clusters, `clusters/prod/<name>/` for prod-type clusters - derived automatically from each cluster's `environment` field, see `onboard-clusters.sh`.
- **Branch protection** on `flux-prod` (restricting direct pushes, requiring PR review before merge) is the recommended way to gate prod promotion once ready to enforce it - check repo Settings > Branches. Note: the classic tag-protection/rulesets API 403'd for this repo ("Upgrade to GitHub Pro or make this repository public") - branch protection rules may have the same private-repo/free-plan restriction, so verify availability before relying on it; until confirmed, promotion discipline is by convention/CODEOWNERS review only.


- **Ownership**: [`.github/CODEOWNERS`](../.github/CODEOWNERS) documents which paths belong to which owner. Currently everyone maps to a single owner (no team split yet), but the granularity (per-cluster, per-overlay, shared `base/`) is already in place so splitting review responsibility later is a one-line change per row.
- **Promotion is branch-only**: every cluster's `git_ref_type` is `branch`; dev clusters track the `flux` branch, prod clusters track the `flux-prod` branch (`clusters-config.yaml`'s `git_ref` field). Promoting to prod means merging/fast-forwarding `flux` into `flux-prod` (`git checkout flux-prod && git merge flux && git push`) once changes are validated on dev - see the comments at the top of `clusters-config.yaml` for the full mechanism.
- **Folder layout**: `clusters/non-prod/<name>/` for dev-type clusters, `clusters/prod/<name>/` for prod-type clusters - derived automatically from each cluster's `environment` field, see `onboard-clusters.sh`.
- **Branch protection** on `flux-prod` (restricting direct pushes, requiring PR review before merge) is the recommended way to gate prod promotion once ready to enforce it - check repo Settings > Branches. Note: the classic tag-protection/rulesets API 403'd for this repo ("Upgrade to GitHub Pro or make this repository public") - branch protection rules may have the same private-repo/free-plan restriction, so verify availability before relying on it; until confirmed, promotion discipline is by convention/CODEOWNERS review only.

