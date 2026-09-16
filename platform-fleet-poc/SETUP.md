# Platform Fleet POC - Flux v2 Cluster Onboarding Guide

## Prerequisites

### Local Setup

```bash
# 1. Configure GitHub token as environment variable
export GITHUB_TOKEN=github_pat_xxxxxxxxxxxx

# 2. Ensure you have these tools installed:
# - kubectl
# - flux CLI (script will install if missing)
# - yq (script will install if missing)

# 3. Edit clusters-config.yaml and add your clusters
vi platform-fleet-poc/clusters-config.yaml
```

Real example (as added for the `spoke2` cluster):

```yaml
  - name: azr-dev-0055-k01     # cluster identifier - used for directory naming (clusters/<env>/<name>/)
    enabled: true              # true to include this cluster in scaffold + onboard scripts
    environment: dev           # "prod" -> clusters/prod/, anything else -> clusters/non-prod/
    sku: sku1                  # resolves overlay <group>-<sku> if it exists, else falls back to <group>
    group: resource-plane      # must match a folder under apps/overlays and infrastructure/overlays
    git_ref_type: branch       # always "branch"
    git_ref: flux              # "flux" for non-prod, "flux-prod" for prod
    kubeconfig_context: spoke2 # local kubectl context name (must already exist, see prerequisites above)
    install_flux: true         # bootstrap Flux v2 on this cluster via onboard-clusters.sh
    flux_namespace: flux-kpc   # namespace Flux controllers/GitRepository live in
```

> Before running the scripts below, the `kubeconfig_context` (`spoke2` here) must already
> exist locally and point at the right AKS cluster, e.g.:
> ```bash
> az aks get-credentials --resource-group <rg> --name <aks-cluster-name> --overwrite-existing
> kubectl config rename-context <aks-cluster-name> spoke2
> ```

## Two-Step Workflow

### Step 1: Scaffold Cluster Files

Creates directory structure and manifest templates from `clusters-config.yaml`. Idempotent - only creates files that are missing.

```bash
chmod +x platform-fleet-poc/scaffold-cluster-files.sh

# Scaffold all enabled clusters
./platform-fleet-poc/scaffold-cluster-files.sh

# Or scaffold only one cluster
./platform-fleet-poc/scaffold-cluster-files.sh kind-dev
```

Output:
- Creates `clusters/prod/<cluster>/` or `clusters/non-prod/<cluster>/` (based on environment)
- Generates: `kustomization.yaml`, `infrastructure.yaml`, `k8s-apps.yaml`, `cluster-context.yaml`
- Does NOT touch Kubernetes cluster, does NOT commit or push - this is deliberate,
  not an oversight (see below).

**Before Step 2**: review the generated `k8s-apps.yaml` for that cluster. The
`postBuild.substitute` block (`resource-plane*` overlays only) is filled with
generic defaults from `clusters-config.yaml` - at minimum check/fix
`HUB_PROMETHEUS_WRITE_URL` (the default assumes the hub is reachable on the
cluster's own internal DNS, which is only true if this spoke shares a network
with the hub; if not, use the hub's external endpoint, e.g.
`https://<PROMETHEUS_DOMAIN>/api/v1/write`, same as the other spokes).

Once the generated files look right, commit and push them **before** running
`onboard-clusters.sh`:

```bash
git add platform-fleet-poc/clusters/<prod-or-non-prod>/<cluster-name>/
git commit -m "platform-fleet-poc: scaffold <cluster-name>"
git push
```

> Why isn't this automated by the scaffold script? Two reasons: (1) the script
> is meant to be safely re-runnable/idempotent with zero side effects outside
> the local filesystem - no script should silently push to a shared branch;
> and (2) you almost always need to hand-correct at least one substituted
> value (above) before it's fit to commit - auto-pushing right after
> generation would commit the wrong defaults first.
>
> If you skip this and bootstrap anyway, Flux's root `Kustomization` (created
> directly by `flux bootstrap`, which commits/pushes its own
> `flux-kpc/gotk-*.yaml` files itself) will reconcile successfully but find
> nothing else in the cluster's folder - `infrastructure` and `apps`
> Kustomizations simply won't exist yet until you push them.

### Step 2: Bootstrap Flux

Installs Flux v2 controllers in clusters marked with `install_flux: true`.

```bash
chmod +x platform-fleet-poc/onboard-clusters.sh

# Bootstrap Flux for all enabled clusters
./platform-fleet-poc/onboard-clusters.sh

# Or bootstrap only one cluster
./platform-fleet-poc/onboard-clusters.sh kind-dev
```

The script:
- ✓ Switches kubectl context
- ✓ Verifies if Flux v2 is already installed
- ✓ Installs flux CLI if needed
- ✓ If `install_flux: true`: Bootstraps Flux v2 at the version from `catalog/flux.yaml`
- ✓ Waits for Flux controllers to be ready

## Configuration

Edit `platform-fleet-poc/clusters-config.yaml`:

```yaml
clusters:
  - name: kind-dev
    enabled: true
    kubeconfig_context: kind-flux-fleet-poc
    group: resource-plane
    sku: sku1
    environment: dev
    install_flux: true
    flux_namespace: flux-kpc
    git_ref: flux
```

**Key fields**:
- `name`: Cluster identifier (used for directory naming)
- `enabled`: Set to `true` to include in scaffolding and onboarding
- `group`: App/infra profile (`control-plane`, `resource-plane`, etc.)
- `sku`: Size variant (`sku1`, `sku2`, ...)
- `environment`: `prod` or anything else (maps to `clusters/prod` or `clusters/non-prod`)
- `install_flux`: Set to `true` to bootstrap Flux
- `flux_namespace`: Namespace for Flux controllers (defaults to `flux-kpc`)
- `git_ref`: Branch to track (`flux` for non-prod, `flux-prod` for prod)
- ✓ Waits for Flux v2 controllers to be ready (source-controller, kustomize-controller)
- ✓ Applies cluster resources from `clusters/[cluster-name]/` (baselines, apps, kustomizations)

### Option 2: GitHub Actions

To use the GitHub Actions workflow:

1. Go to **Settings → Secrets and variables → Actions**
2. Add the `KUBECONFIG` secret with your kubeconfig in base64:
   ```bash
   cat ~/.kube/config | base64 | pbcopy  # macOS
   cat ~/.kube/config | base64 -w 0 | xclip -selection clipboard  # Linux
   ```
3. Go to **Actions → Setup Platform Fleet POC**
4. Click **Run workflow**
5. Select cluster (kind-dev or aks-dev)

The workflow will:
   - Install Flux
   - Create secret with GITHUB_TOKEN
   - Apply cluster configuration
   - Verify status

## Verification

After running the script:

```bash
# View namespaces
kubectl get ns

# View Flux controllers
kubectl get deployment -n flux-system

# View Git repositories
kubectl get gitrepository -n flux-system

# View Kustomizations
kubectl get kustomization -n flux-system

# View sync logs
kubectl logs -n flux-system deployment/source-controller -f
```

## Troubleshooting

If something fails:

```bash
# Retry reconciliation
kubectl -n flux-system rollout restart deployment/source-controller

# View error details
kubectl describe gitrepository fleet-repo -n flux-system
kubectl describe kustomization baseline -n flux-system

# View detailed logs
kubectl logs -n flux-system deployment/source-controller -f
kubectl logs -n flux-system deployment/kustomize-controller -f

# Manually switch context
kubectl config use-context kind-flux-fleet-poc
kubectl config use-context aks-stocktrader-victor-test-001
```

## Directory Structure

```
platform-fleet-poc/
├── clusters-config.yaml          # Cluster configuration for onboarding
├── onboard-clusters.sh           # Main onboarding script
├── SETUP.md                      # This guide
├── README.md                     # General documentation
├── clusters/                     # Per-cluster configuration
│   ├── kind-dev/
│   │   ├── cluster.yaml
│   │   ├── kustomization.yaml
│   │   ├── baseline.yaml
│   │   ├── apps.yaml
│   │   └── flux-system/
│   │       ├── git-repository.yaml
│   │       └── kustomization.yaml
│   └── aks-dev/
│       ├── cluster.yaml
│       ├── kustomization.yaml
│       ├── baseline.yaml
│       ├── apps.yaml
│       └── flux-system/
│           ├── git-repository.yaml
│           └── kustomization.yaml
├── catalog/                      # Shared components catalog
│   ├── baselines/
│   │   ├── baseline-v1/
│   │   │   ├── namespaces.yaml
│   │   │   ├── rbac.yaml
│   │   │   └── kustomization.yaml
│   │   └── baseline-v2/
│   │       ├── namespaces.yaml
│   │       ├── rbac.yaml
│   │       └── kustomization.yaml
│   └── apps/
│       └── podinfo/
│           ├── deployment.yaml
│           ├── service.yaml
│           └── kustomization.yaml
```

## Important Notes

- The script automatically detects if Flux is already installed
- For multiple clusters, simply edit `clusters-config.yaml` with `install_flux: true` for desired clusters
- Ensure your kubeconfig has contexts configured correctly
- GitHub token must have read permissions on the repository
- Use `--force` flag only when you need to reinstall Flux completely
- Never commit tokens to git - always use environment variables
