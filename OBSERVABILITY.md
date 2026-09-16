# Observability Hub-Spoke — Prometheus Federation & OpenCost

Documents the multi-cluster observability architecture implemented for the fleet:
a central **hub** that receives metrics from **spokes** via `remote_write`, and
**OpenCost** deployed in dual mode (hub + spoke) for per-cluster cost visibility.

## Topology

| Role | Cluster | Flux branch | Status |
|---|---|---|---|
| Hub (control-plane) | `azr-cru-0001-k01` | `flux` | ✅ Running |
| Spoke (resource-plane) | `azr-dev-0011-k01` | `flux` | ✅ Running |
| Spoke (resource-plane) | `azr-dev-0055-k01` | `flux` | ✅ Running |

```mermaid
graph TB
    subgraph Spoke1["Spoke 1: azr-dev-0011-k01"]
        direction LR
        SP1[Prometheus Agent<br/>v27.12.1 --agent]
        OC1[OpenCost<br/>opencost-promless]
        SP1 -.->|scrapes| OC1
    end

    subgraph Spoke2["Spoke 2: azr-dev-0055-k01"]
        direction LR
        SP2[Prometheus Agent<br/>v27.12.1 --agent]
        OC2[OpenCost<br/>opencost-promless]
        SP2 -.->|scrapes| OC2
    end

    subgraph Hub["Hub: azr-cru-0001-k01"]
        direction TB
        GW["🚪 KGateway HTTPRoute<br/><PROMETHEUS_DOMAIN><br/>Port 443 - IP allowlist"]
        HP["📊 kube-prometheus-stack<br/>v90.0.0<br/>enableRemoteWriteReceiver"]
        GF["🎨 Grafana<br/>3 datasources<br/>1 hub + 2 remote"]
        OC_H["💰 OpenCost<br/>(hub metrics)"]
        GW -->|receives| HP
        HP -->|stores| HP
        HP -->|renders| GF
        HP -.->|scrapes| OC_H
    end

    SP1 -->|remote_write HTTPS<br/>cluster_id=azr-dev-0011-k01| GW
    OC1 -->|queries HTTPS| GW
    
    SP2 -->|remote_write HTTPS<br/>cluster_id=azr-dev-0055-k01| GW
    OC2 -->|queries HTTPS| GW
    
    GF -.->|multi-cluster view<br/>cluster_id filter| Hub
    
    style Spoke1 fill:#e1f5ff
    style Spoke2 fill:#e1f5ff
    style Hub fill:#fff3e0
```

## 1. Prometheus federation (hub receives metrics from the spoke)

**Hub** (`apps/overlays/control-plane/prometheus/helmrelease.yaml`):
chart `kube-prometheus-stack` v90.0.0, with:
- `prometheusSpec.enableRemoteWriteReceiver: true` — enables the `/api/v1/write` endpoint to accept remote_write.
- `retention: 24h`, 10Gi PVC.
- Grafana bundled, datasource manually provisioned pointing to `http://prometheus-kube-prometheus-prometheus:9090`.
- Exposed externally via KGateway (`k8s/monitoring/prometheus-httproute.yaml`): `HTTPRoute` on Gateway `pe-gatewayapi`, hostname `<PROMETHEUS_DOMAIN>` → Service `kube-prometheus-stack-prometheus:9090`. LB external IP: `<HUB_LB_IP>`.

**Spoke** (`apps/base/prometheus-agent/helmrelease.yaml`, shared base reused by every spoke):
chart `prometheus` v27.12.1 in **Agent mode** (`--agent`, no local TSDB, no query API):
- `hostAliases` pins `<PROMETHEUS_DOMAIN>` → `<HUB_LB_IP>` (hub's LB IP) — POC workaround to avoid relying on public DNS.
- `global.external_labels`: `cluster_id=${SPOKE_CLUSTER_ID}`, `environment=${SPOKE_ENVIRONMENT}` — stamped onto everything this agent ships via remote_write. Each spoke sets its own `SPOKE_CLUSTER_ID` via Flux `postBuild.substitute` in its `k8s-apps.yaml`.
- `remoteWrite` to `${HUB_PROMETHEUS_WRITE_URL}` (`https://<PROMETHEUS_DOMAIN>/api/v1/write`), TLS `insecure_skip_verify: true`, with `write_relabel_configs` keeping only `up|node_.*|container_.*|kube_.*|kubelet_.*|prometheus_remote_storage_.*` (reduces volume).
- Own scrape jobs: `prometheus` (self), `kubernetes-nodes` / `kubernetes-nodes-cadvisor` (via apiserver proxy), and `kubernetes-service-endpoints` — this last one **auto-discovers any Service annotated with `prometheus.io/scrape=true`**, which is how OpenCost gets scraped without needing a `ServiceMonitor`.

**Onboarded spokes:**

| Cluster | Name | Status | Details |
|---|---|---|---|
| `azr-dev-0011-k01` | spoke | ✅ Running | Victor's spoke, ~1.3M samples/min via remote_write, 0 failures |
| `azr-dev-0055-k01` | spoke2 | ✅ Running | Second spoke (2026-09-16), Prometheus Agent + OpenCost operational |
| `azr-dev-0012-k01` | — | 🔲 Pending | Jonathan's spoke, not yet onboarded |

## 2. OpenCost — dual mode

- **Hub**: OpenCost integrated, queries the hub's local Prometheus.
- **Spoke** (`apps/base/opencost-promless/helmrelease.yaml`, shared base reused by every spoke): standalone OpenCost (`opencost` chart v2.5.30, no UI), queries the **hub's** Prometheus over HTTPS (`opencost.prometheus.external.url: https://<PROMETHEUS_DOMAIN>`).
  - `exporter.defaultClusterId: ${SPOKE_CLUSTER_ID}` + `PROM_CLUSTER_ID_LABEL: cluster_id` — OpenCost adds `cluster_id` as a **real label on its own emitted metrics** at the application level (does not depend on Prometheus `externalLabels`). Same per-spoke `SPOKE_CLUSTER_ID` substitution as the Prometheus agent.
  - `hostAliases` (same DNS workaround as the agent) injected via `postRenderers.kustomize.patches` on the `Deployment`.
  - `prometheus.io/scrape|port|path` annotations injected via `postRenderers.kustomize.patches` on the `Service` — the chart's `values.serviceAnnotations` field does **not** actually apply them to the rendered Service (chart limitation/bug), hence the post-render patch workaround.

**Verified state:** Both spokes (`azr-dev-0011-k01` and `azr-dev-0055-k01`) are sending metrics and cost data to the hub:
- Prometheus remote_write: `prometheus_remote_storage_samples_failed_total=0` for both
- OpenCost: `up{service="opencost-promless",cluster_id="..."}=1` for each spoke
- Grafana: All three clusters visible in multi-cluster dashboards (OpenCost Overview, OpenCost Namespace)
- Network: Both spokes' egress IPs (`<SPOKE2_EGRESS_IP>` for spoke2) added to hub's Gateway allowlist (`pe-gatewayapi`) to permit HTTPS traffic to `<PROMETHEUS_DOMAIN>`

## 3. Known limitation: Grafana can't see the hub's own metrics by `cluster_id`

**Symptom:** in Grafana (datasource = hub's Prometheus), a panel/filter on `cluster_id="azr-cru-0001-k01"` returns no data for the hub's own kube-state-metrics/node-exporter/kubelet metrics. OpenCost, however, correctly distinguishes both clusters.

**Root cause:** Prometheus `externalLabels` are **only applied to metrics leaving** that instance (remote_write, federation, Alertmanager) — **not** to metrics that same instance scrapes and queries locally.

- Hub's native metrics → scraped and queried locally → never go through remote_write → **no `cluster_id`**.
- Spoke's metrics → the agent stamps `cluster_id` **before** shipping them → arrive at the hub already labeled.
- OpenCost → adds `cluster_id` as a real metric label at the application level, regardless of who scrapes it → works the same on both clusters.

**Status:** root cause diagnosed. A previous attempt (`metricRelabelings` on ServiceMonitors) was lost to an accidental `git reset --hard` + `push --force`, and per user confirmation it never showed results in Grafana anyway — that commit was **not** restored.

**Fix applied (new commit, Option A — hardcoded value):** `metricRelabelings` added directly on the hub's `kube-state-metrics` and `prometheus-node-exporter` ServiceMonitors (`apps/overlays/control-plane/prometheus/helmrelease.yaml`), using the CRD's correct camelCase fields (`targetLabel`/`replacement`/`action` — likely why the old attempt silently failed, if it used snake_case):
```yaml
metricRelabelings:
  - targetLabel: cluster_id
    replacement: azr-cru-0001-k01
    action: replace
```
Pending verification directly against Prometheus (`up{cluster_id="azr-cru-0001-k01"}`) after Flux reconciles, before checking Grafana.

## 4. Network Security — IP Allowlist on Gateway

Spokes must route their remote_write and OpenCost queries through the hub's external Gateway (`<PROMETHEUS_DOMAIN>`, IP `<HUB_LB_IP>`). Azure's LoadBalancer service requires explicit IP allowlisting for external traffic.

**Gateway resource:** `k8s/kgateway/main.tf`, `kubernetes_manifest.kgateway_gateway`:
- `spec.infrastructure.annotations["service.beta.kubernetes.io/azure-allowed-ip-ranges"]`: comma-separated list of CIDRs
- Includes Kyndryl VPN CIDR blocks (GlobalProtect), plus per-spoke egress IPs (when spokes are in separate networks/regions)

**Spoke egress IPs (must be added to allowlist):**
- `spoke` (`azr-dev-0011-k01`): `<SPOKE1_EGRESS_IP_1>`, `<SPOKE1_EGRESS_IP_2>`, `<SPOKE1_EGRESS_CIDR>` (added via manual Gateway patch, 2026-09-15)
- `spoke2` (`azr-dev-0055-k01`): `<SPOKE2_EGRESS_IP>` (added via manual Gateway patch, 2026-09-16)

> **Note:** These are currently **live patches** on the `Gateway` resource (not in Terraform source). To make permanent, add to `k8s/kgateway/variables.tf` `allowed_cidrs_vpn` list. For now, patches persist across kgateway controller reconciles (controller propagates Gateway `spec.infrastructure.annotations` → Service `metadata.annotations`).

**How to find a new spoke's egress IP:**
```bash
kubectl run net-debug --rm -it --image=nicolaka/netshoot -- curl ifconfig.me
# Returns: XX.XX.XX.XXX
# Add as XX.XX.XX.XXX/32 to Gateway allowlist
```

## File references

- Hub Prometheus: [platform-fleet-poc/apps/overlays/control-plane/prometheus/helmrelease.yaml](apps/overlays/control-plane/prometheus/helmrelease.yaml)
- Hub HTTPRoute: [k8s/monitoring/prometheus-httproute.yaml](../k8s/monitoring/prometheus-httproute.yaml)
- Spoke Prometheus Agent: [platform-fleet-poc/apps/base/prometheus-agent/helmrelease.yaml](apps/base/prometheus-agent/helmrelease.yaml)
- Spoke OpenCost: [platform-fleet-poc/apps/base/opencost-promless/helmrelease.yaml](apps/base/opencost-promless/helmrelease.yaml)

## Spoke Onboarding Checklist

When onboarding a new spoke cluster, follow these steps **in order** to ensure observability is correctly integrated:

### 1. **Local kubectl context setup** (prerequisite)
```bash
az aks get-credentials --resource-group <rg> --name <aks-cluster> --overwrite-existing
kubectl config rename-context <aks-cluster> <spoke-alias>  # e.g., spoke2
```

### 2. **Add to clusters-config.yaml**
Edit [platform-fleet-poc/clusters-config.yaml](clusters-config.yaml):
```yaml
  - name: azr-dev-0055-k01
    enabled: true
    environment: dev
    sku: sku1
    group: resource-plane
    git_ref_type: branch
    git_ref: flux
    kubeconfig_context: spoke2
    install_flux: true
    flux_namespace: flux-kpc
```

### 3. **Scaffold cluster files**
```bash
cd platform-fleet-poc
./scaffold-cluster-files.sh azr-dev-0055-k01
```
**Edit generated `clusters/non-prod/azr-dev-0055-k01/k8s-apps.yaml`:**
- Fix `HUB_PROMETHEUS_WRITE_URL` (must be external hub URL if spoke is in different network): `https://<PROMETHEUS_DOMAIN>/api/v1/write`
- Verify `SPOKE_CLUSTER_ID` and `SPOKE_ENVIRONMENT` match your cluster's identity

### 4. **Commit & push scaffold**
```bash
git add platform-fleet-poc/clusters/non-prod/azr-dev-0055-k01/
git commit -m "platform-fleet-poc: scaffold azr-dev-0055-k01"
git push origin flux
```

### 5. **Bootstrap Flux**
```bash
export GITHUB_TOKEN=$(gh auth token --hostname github.com --user victorrodriguez1984)
./onboard-clusters.sh azr-dev-0055-k01
```
Flux controller installs, creates `GitRepository` + root `Kustomization` for the cluster.

### 6. **Find spoke's egress IP** (if in different network from hub)
On the spoke cluster:
```bash
kubectl run net-debug --rm -it --image=nicolaka/netshoot -- curl ifconfig.me
# Record the output IP (e.g., 20.237.40.112)
```

### 7. **Add spoke's IP to hub's Gateway allowlist**
On the hub cluster, patch the `Gateway` resource:
```bash
kubectl config use-context hub
CURRENT=$(kubectl get gateway pe-gatewayapi -n gatewayapi -o jsonpath='{.spec.infrastructure.annotations.service\.beta\.kubernetes\.io/azure-allowed-ip-ranges}')
NEW="${CURRENT},<SPOKE2_EGRESS_IP>"
kubectl patch gateway pe-gatewayapi -n gatewayapi --type merge -p "{\"spec\":{\"infrastructure\":{\"annotations\":{\"service.beta.kubernetes.io/azure-allowed-ip-ranges\":\"${NEW}\"}}}}"
```
The kgateway controller propagates this to the LoadBalancer Service automatically (takes ~1-2 min).

### 8. **Verify data flow**
Back on the spoke:
```bash
kubectl config use-context spoke2
# Wait for Prometheus Agent and OpenCost pods to be Running
kubectl get pods -n monitoring -n finops
# Test hub connectivity from spoke
kubectl run net-debug --rm -it --image=nicolaka/netshoot -- curl -I https://<PROMETHEUS_DOMAIN>/
```

On the hub:
```bash
kubectl config use-context hub
# Check that spoke's metrics arrive
kubectl exec -n monitoring prometheus-kube-prometheus-stack-prometheus-0 -- \
  promtool query instant 'up{cluster_id="azr-dev-0055-k01"}'
```

### 9. **Verify in Grafana**
- Cluster dropdown in OpenCost dashboards should list the new spoke
- Namespace filtering should show spoke's namespaces
- Cost data should appear within ~2-3 minutes

**Done!** The spoke is fully integrated and contributing metrics/cost data to the hub.

## 4. FinOps Framework: 4-Layer Cost Governance Architecture

This platform implements a **4-layer FinOps model** aligned with **cloud financial operations maturity**:

```mermaid
graph TB
    subgraph L1["Layer 1: INFORM — Cost Visibility"]
        I1["OpenCost API<br/>/allocation endpoint<br/>cluster | namespace"]
        I2["Daily Showback Reports<br/>Cluster-level CSV<br/>Namespace-level CSV"]
        I3["Grafana Dashboards<br/>Cost by resource<br/>Multi-cluster view"]
    end

    subgraph L2["Layer 2: OPTIMIZE — Efficiency Analysis"]
        O1["Cost trends<br/>30d | 7d | 1d windows<br/>per cluster"]
        O2["Efficiency metrics<br/>CPU usage ÷ request<br/>RAM efficiency ratio"]
        O3["Anomaly detection<br/>Spike detection<br/>Wasted resource ID"]
    end

    subgraph L3["Layer 3: OPERATE — Governance & Control"]
        OP1["Namespace labels<br/>application-id<br/>owner, cost-center<br/>service-id"]
        OP2["cluster-context.yaml<br/>Cluster metadata<br/>tenant, environment<br/>allocation-ref"]
        OP3["Budget enforcement<br/>Cost baseline tracking<br/>Release gate checks"]
    end

    subgraph L4["Layer 4: GOVERNANCE CROSS — Audit & Compliance"]
        G1["Cost attribution audit<br/>ownership coverage %<br/>label compliance"]
        G2["Chargeback automation<br/>Showback → Finance<br/>GitOps trace"]
        G3["FinOps taxonomy<br/>Cluster tagging<br/>Cost center mapping<br/>Audit trail"]
    end

    I1 --> O1
    I2 --> O2
    I3 --> O3
    
    O1 --> OP1
    O2 --> OP2
    O3 --> OP3
    
    OP1 --> G1
    OP2 --> G2
    OP3 --> G3
    
    style L1 fill:#c8e6c9
    style L2 fill:#fff9c4
    style L3 fill:#ffe0b2
    style L4 fill:#ffccbc
```

### Layer 1: INFORM — Cost Visibility

**Goal:** Enable teams to **see** what they're spending.

| Component | Purpose | Enterprise Use | Status |
|---|---|---|---|
| **OpenCost API** | Real-time allocation queries | BI/DP tools consume `/allocation?aggregate=cluster\|namespace` | ✅ Multi-cluster enabled |
| **Cluster-level Showback** | `export-daily-costs.sh` → CSV/JSON | Ops team, budget tracking, chargeback input | ✅ €11.90 (30d) tested |
| **Namespace-level Showback** | `export-namespace-costs.sh` → CSV/JSON | Workload owners, namespace cost breakdown | ✅ 27.7% labeled (5/18 ns) |
| **Grafana Dashboards** | Multi-cluster unified view | NOC/SRE cost dashboard, real-time trend | ✅ All 3 clusters visible |

**Example: Inform Layer in Action**
```bash
# Finance BI consumes this nightly
curl -s "https://finops.kyndemo.live/allocation?window=30d&aggregate=cluster" | jq '.data[0] | keys'
# Returns: ["azr-cru-0001-k01", "azr-dev-0011-k01", "azr-dev-0055-k01"]

# Shows cost per cluster for BI/PowerBI reporting
./operations/finops/export-daily-costs.sh 30d csv
# Output: cluster_id,tenant,owner,total_cost,cpu_cost,ram_cost,…
```

---

### Layer 2: OPTIMIZE — Efficiency Analysis

**Goal:** Answer **"Where are we wasting money?"** and **"How do we right-size?"**

| Component | Purpose | Enterprise Use | Example Metric |
|---|---|---|---|
| **Cost trend analysis** | Compare 30d vs 7d vs 1d | Capacity planning, spike detection | CPU cost grew 15% WoW → investigate |
| **Efficiency ratios** | Usage ÷ Request or Limit | Resource utilization audit | CPU efficiency 2.6% → over-provisioned |
| **Pod-level breakdown** | OpenCost: per-namespace, per-pod granularity | Workload-team cost accountability | Frontend pod: €0.08/day (too high?) |
| **Cost baselines** | Track month-to-month changes | Budget vs. actual, variance analysis | Expected €12/mo → actual €14/mo → review |

**Optimization Workflow:**
```yaml
# 1. Identify high-cost namespaces (Layer 1)
export-namespace-costs.sh 30d csv hub | sort -t',' -k8 -rn | head

# 2. Filter by efficiency (Layer 2)
# → kube-system: €3.40, but efficiency ratio low
# → monitoring: €0.58, but CPU efficiency good (label coverage perfect)

# 3. Action (Layer 3 & 4): Right-size monitoring, but keep kube-system as-is (critical path)
```

---

### Layer 3: OPERATE — Governance & Control

**Goal:** **Enforce policy** so cost stays predictable.

**Governance Artifacts (GitOps-managed):**

1. **Namespace Labels** (`infrastructure/base/namespaces.yaml`)
   ```yaml
   labels:
     application-id: observability  # What is this for? (platform, workload, observability, …)
     service-id: PROM001             # Service identifier (ITSM catalog link)
     owner: platform-team            # Responsible team
     cost-center: OPS001             # Finance cost center
   ```
   - **Impact:** Enables cost attribution & chargeback.
   - **Ownership Coverage:** Track % of namespaces with all 4 labels.
   - **Current State:** 27.7% (5/18 on hub) — remaining 13 namespaces (kube-system, gatewayapi, etc.) are system/unowned.

2. **Cluster Identity** (`clusters/non-prod/<cluster>/cluster-context.yaml`)
   ```yaml
   clusterId: azr-cru-0001-k01
   tenant: tbd                       # Which tenant/customer?
   technicalOwner: platform-team     # On-call team
   environment: non-prod             # non-prod | prod
   clusterProfile: control-plane     # control-plane | resource-plane-sku1
   lifecycleState: active            # active | retiring | …
   financialAllocationRef: tbd       # P&L center, chargeback key
   ```
   - **Enriches showback data** with context (tenant, owner, P&L ref).
   - **Single source of truth** for cluster metadata across cost, operations, and billing.

3. **Release Gating (Proposed)**
   - Before promoting to `flux-prod`, validate showback consistency:
     ```bash
     # Check: all new namespaces have required labels
     kubectl get ns -o json | jq '.items[] | select(.metadata.labels.owner == null)'
     # If count > 0 → BLOCK release, require labeling
     ```

**Cost Control Enforcement:**
```bash
# Annually or per-release:
# 1. Audit label coverage
./operations/finops/export-namespace-costs.sh 30d csv hub | awk -F',' '
  $4 == "tbd" || $5 == "tbd" || $6 == "tbd" {print $3 " MISSING LABELS"}
'

# 2. Update cluster-context.yaml if tenant changed
# 3. Commit & push to flux → costs re-attributed on next showback

# 4. Finance reconciles BI query against showback reports
```

---

### Layer 4: GOVERNANCE CROSS — Audit & Compliance

**Goal:** Achieve **auditability**, **chargeback accuracy**, and **FinOps taxonomy alignment**.

| Capability | How Achieved | Enterprise Benefit | Status |
|---|---|---|---|
| **Cost Attribution Audit** | Compare label coverage % with showback cost coverage % | Ensure 100% of €$ is attributed to an owner/team | 27.7% on hub (5/18 ns labeled) |
| **Chargeback Automation** | Showback CSV → Finance BI/ERP nightly pipeline | No manual cost allocation; full audit trail | ✅ CSV ready for export |
| **FinOps Taxonomy Compliance** | cluster-context.yaml enforces cluster fields (tenant, environment, P&L) | Align with FinOps Foundation tagging standard | ✅ Schema defined |
| **Git-backed Audit Trail** | Every change (label, cluster-context, allocation-ref) → committed to Git | Full compliance: who changed cost allocation, when, why | ✅ Flux-managed |
| **Cost Variance Tracking** | Showback reports versioned in Git (or separate reports bucket) | Historical cost data for forensics/trends | ✅ reports/ directory |

**Audit Example: "Who is responsible for the 27% unlabeled cost?"**
```bash
# 1. Query showback: sum of "tbd" rows = €1.57 of €5.66 = 27.7%
./operations/finops/export-namespace-costs.sh 30d csv hub | grep tbd | awk -F',' '{sum+=$8} END {print "Unlabeled cost: €" sum}'

# 2. Identify unlabeled namespaces
kubectl get ns -L application-id,owner,cost-center,service-id | grep -E "^(kube-|gateway|flux|default|dev|humanitec|traefik|test|whoami)" | grep tbd

# 3. Assign labels in infrastructure/overlays/control-plane/namespaces.yaml
# 4. Commit & push → Flux reconciles → showback re-runs next day with 100% coverage

# 5. Audit trail: `git log --oneline infrastructure/overlays/control-plane/namespaces.yaml`
#    → Shows label assignment date, author, commit message = chargeback justification
```

---

## 5. Showback Datasets

Two complementary daily cost exports for financial reporting:

### Cluster-Level Showback

**File:** `operations/finops/showback_30d_*.csv`

**Columns:**
```
cluster_id, cluster_name, tenant, owner, environment, profile, lifecycle, 
allocation_ref, total_cost, cpu_cost, ram_cost, storage_cost, gpu_cost
```

**Example Output (30 days):**
```
azr-cru-0001-k01, azr-cru-0001-k01, tbd, tbd, non-prod, control-plane, active, tbd, 2.19, 1.28, 0.54, 0, 0
azr-dev-0011-k01, azr-dev-0011-k01, tbd, tbd, pro, resource-plane-sku1, active, tbd, 8.52, 4.49, 2.74, 0, 0
azr-dev-0055-k01, azr-dev-0055-k01, tbd, tbd, dev, resource-plane-sku1, active, tbd, 1.04, 0.66, 0.31, 0, 0
```

**Use Case:** Budget tracking, chargeback by cluster group, capacity planning.

### Namespace-Level Showback

**File:** `operations/finops/namespace-showback_30d_*.csv`

**Columns:**
```
report_date, cluster, namespace, application_id, owner, cost_center, service_id,
total_cost, cpu_cost, ram_cost, storage_cost, gpu_cost
```

**Example Output (hub, 30 days):**
```
2026-09-16T..., hub, apps, platform, platform-team, OPS001, K8S-APPS, 0.26, 0.22, 0.03, 0, 0
2026-09-16T..., hub, monitoring, observability, platform-team, OPS001, PROM001, 0.58, 0.15, 0.29, 0, 0
2026-09-16T..., hub, kube-system, tbd, tbd, tbd, tbd, 3.40, 2.46, 0.94, 0, 0
2026-09-16T..., hub, finops-opencost, finops, platform-team, OPS001, FINOPS001, 0.06, 0.02, 0.02, 0, 0
```

**Ownership Coverage:** 5/18 namespaces (27.7%) fully labeled with application-id + owner + cost-center.

**Use Case:** Workload-team cost accountability, chargeback by application, cost anomaly detection per namespace.

### Usage

```bash
cd operations/finops

# Cluster showback (30 days, CSV)
./export-daily-costs.sh 30d csv
# Output: ./reports/showback_30d_<timestamp>.csv

# Namespace showback (7 days, JSON for BI tools)
./export-namespace-costs.sh 7d json hub
# Output: ./reports/namespace-showback_7d_<timestamp>.json

# Check coverage
grep tbd ./reports/namespace-showback_*.csv | wc -l  # Count unlabeled
```

---

## 6. Integration with Enterprise FinOps Processes

### Data Flow: Platform → Finance

```
OpenCost API (hub)
    ↓
export-daily-costs.sh (Layer 1: Inform)
    ↓
showback_30d_*.csv (Layer 2: cluster costs visible)
    ↓
Finance BI (PowerBI / Tableau)  ← consume CSV nightly via scheduled sync
    ↓
Cost dashboards, chargeback reports, P&L allocation
    ↓
Accounting closes P&L
    ↓
(Layer 4) Git audit trail proves who owned what, when
```

### Roadmap for Enterprise Adoption

| Phase | Capability | Effort | Impact |
|---|---|---|---|
| **Phase 0 (Done)** | Multi-cluster observability + OpenCost API | 2w | Can export costs |
| **Phase 1 (Done)** | Showback datasets (cluster + namespace) | 1w | Finance can report |
| **Phase 2 (Next)** | Namespace label enforcement (release gate) | 1w | 100% cost attribution |
| **Phase 3 (Future)** | FinOps taxonomy alignment + P&L mapping | 2w | Full chargeback automation |
| **Phase 4 (Future)** | Anomaly alerts + optimization recommendations | 3w | Proactive cost management |

