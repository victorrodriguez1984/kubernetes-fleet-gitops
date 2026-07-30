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

# 3. Edit clusters-config.yaml and mark clusters with install_flux: true
vi platform-fleet-poc/clusters-config.yaml

# 4. Run the onboarding script
chmod +x platform-fleet-poc/onboard-clusters.sh
```

## Usage

### Option 1: Local Script (Recommended - Configuration-Based)

The script reads cluster configuration from `clusters-config.yaml` and automatically processes those with `install_flux: true`.

#### 1. Configure Clusters

Edit `platform-fleet-poc/clusters-config.yaml`:

```yaml
clusters:
  - name: kind-dev
    enabled: true
    kubeconfig_context: kind-flux-fleet-poc
    install_flux: true          # ← Set true to install Flux

  - name: aks-dev
    enabled: false
    kubeconfig_context: aks-stocktrader-victor-test-001
    install_flux: false         # ← Set false to skip Flux
```

**Key points**:
- `name`: Cluster identifier (used for directory naming)
- `enabled`: Set to `true` to include in processing
- `kubeconfig_context`: Exact name from `kubectl config get-contexts`
- `install_flux`: Set to `true` ONLY if you want Flux installed

**Important**: This config file ONLY controls Flux installation. Baselines and applications are managed separately in each cluster directory:
- `clusters/[cluster-name]/baseline.yaml` → Controls which baseline version to deploy
- `clusters/[cluster-name]/apps.yaml` → Controls which applications to deploy

**To find your actual kubeconfig contexts:**
```bash
kubectl config get-contexts
```

#### 2. Execute

```bash
export GITHUB_TOKEN=your_token_here

# Process all clusters with install_flux: true
./platform-fleet-poc/onboard-clusters.sh

# Or process only one specific cluster
./platform-fleet-poc/onboard-clusters.sh kind-dev

# Or force reinstallation
./platform-fleet-poc/onboard-clusters.sh kind-dev --force
```

The script automatically for each enabled cluster:
- ✓ Switches kubectl context
- ✓ Verifies if Flux v2 is already installed
- ✓ Installs flux CLI if needed
- ✓ If `install_flux: true`: Installs Flux v2 using `flux bootstrap` (official method)
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
