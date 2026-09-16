# FinOps MVP (Contract + Evidence + Correlation)

This MVP separates ownership clearly:

1. Cluster contract (written by Morpheus/intake):
   - Per-cluster ConfigMap YAML in cluster folders (`cluster-context.yaml`).
   - Represents approved governance context.

2. Cost evidence (produced by OpenCost):
   - Allocation and asset cost metrics from OpenCost API.
   - No business workflow history stored in OpenCost.

3. Correlation layer (evaluation):
   - Script joins OpenCost evidence + cluster contract.
   - Produces showback CSV for reporting.

## Files

- `../apps/overlays/control-plane/opencost/helmrelease.yaml`: single source of pricing policy in `values.opencost.customPricing.costModel`.
- `generate-showback.py`: simple report generator.

## Run

1. Port-forward OpenCost API:

   kubectl -n finops-opencost port-forward svc/opencost 9003:9003

2. Generate report for one cluster contract:

   python3 platform-fleet-poc/finops/generate-showback.py \
     --cluster-context platform-fleet-poc/clusters/non-prod/azr-cru-0001-k01/cluster-context.yaml \
     --opencost-url http://localhost:9003 \
     --window 7d \
     --out /tmp/showback-azr.csv

3. Generated datasets:

   - `showback-azr.csv`: per-namespace cost rows with minimal business context.
   - `cluster-inventory.csv`: one row with cluster governance context.
   - `showback-client.csv`: compact view for service/finance stakeholders.

## Next steps

- Replace `tbd` fields in each `cluster-context.yaml` from Morpheus intake outputs.
- Add schema validation in CI for cluster-context and pricing-model.
- Add a scheduled job to generate and publish showback CSV.

## Lightweight dashboard (open source)

1. Install dependencies:

   /Users/victorrodriguez/.pyenv/versions/3.13.4/bin/python -m pip install -r platform-fleet-poc/finops/requirements-dashboard.txt

2. Launch dashboard:

   /Users/victorrodriguez/.pyenv/versions/3.13.4/bin/python -m streamlit run platform-fleet-poc/finops/dashboard.py

3. Open URL shown by Streamlit (usually http://localhost:8501).

The dashboard reads `platform-fleet-poc/finops/showback-azr.csv` by default and shows:

- Total cost and split by CPU, RAM, PV, and network.
- Top namespaces by total cost.
- Raw CSV table for audit.