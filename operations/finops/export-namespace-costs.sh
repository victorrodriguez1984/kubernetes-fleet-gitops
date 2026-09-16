#!/bin/bash
set -euo pipefail

#
# Export multi-cluster namespace-level cost showback dataset
# Combines OpenCost API data with Kubernetes namespace labels (GitOps metadata)
#
# Usage:
#   export-namespace-costs.sh [window] [output-format] [cluster-context]
#
# Arguments:
#   window: OpenCost window (1d, 7d, 30d), default 30d
#   output-format: csv or json, default csv
#   cluster-context: kubectl context to query (default: hub)
#
# Prerequisites:
#   - OpenCost API exposed via HTTPRoute (https://finops.kyndemo.live)
#   - kubectl configured with access to cluster
#   - yq installed (brew install yq)
#   - jq installed (brew install jq)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WINDOW="${1:-30d}"
OUTPUT_FORMAT="${2:-csv}"
CLUSTER_CONTEXT="${3:-hub}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTPUT_FILE="$SCRIPT_DIR/reports/namespace-showback_${WINDOW}_${TIMESTAMP}.${OUTPUT_FORMAT}"

# OpenCost API endpoint (via HTTPRoute)
OPENCOST_API="${OPENCOST_API:-https://finops.kyndemo.live}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Ensure reports directory exists
mkdir -p "$SCRIPT_DIR/reports"

echo -e "${YELLOW}[INFO]${NC} Generating namespace showback dataset"
echo -e "${YELLOW}[INFO]${NC}   Window: $WINDOW, Format: $OUTPUT_FORMAT, Cluster: $CLUSTER_CONTEXT"

# ============================================================================
# 1. Query OpenCost API for namespace-level allocation data
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Querying OpenCost API: $OPENCOST_API/allocation?aggregate=namespace"

COSTS_JSON=$(curl -sk "${OPENCOST_API}/allocation?window=${WINDOW}&aggregate=namespace" 2>&1) || {
  echo -e "${RED}[ERROR]${NC} Failed to query OpenCost API at: $OPENCOST_API"
  echo "  Ensure the API endpoint is accessible and cluster connectivity is working"
  exit 1
}

# Validate JSON response
if ! echo "$COSTS_JSON" | jq empty 2>/dev/null; then
  echo -e "${RED}[ERROR]${NC} Invalid JSON response from OpenCost API"
  echo "$COSTS_JSON"
  exit 1
fi

# ============================================================================
# 2. Extract namespace costs from API response
# ============================================================================

# OpenCost returns: { "data": [ { "<cluster>/<namespace>": { "totalCost": "0.79", ... }, ... } ] }
COSTS_DATA=$(echo "$COSTS_JSON" | jq '.data[0] // {}')

# ============================================================================
# 3. Get namespace labels from Kubernetes
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Querying Kubernetes namespaces from context: $CLUSTER_CONTEXT"

kubectl config use-context "$CLUSTER_CONTEXT" > /dev/null 2>&1 || {
  echo -e "${RED}[ERROR]${NC} Unable to switch to context: $CLUSTER_CONTEXT"
  exit 1
}

# Get all namespaces with labels as JSON
NAMESPACES_JSON=$(kubectl get namespaces -o json)

# ============================================================================
# 4. Build enriched dataset by merging OpenCost data + namespace labels
# ============================================================================

ENRICHED_DATA='[]'

# Get current cluster ID from context
CURRENT_CLUSTER=$(kubectl config current-context 2>/dev/null || echo "unknown")

# Loop over all namespaces
while IFS= read -r ns_name; do
  # Extract labels from namespace
  NS_LABELS=$(kubectl get namespace "$ns_name" -o json 2>/dev/null || echo '{}')
  
  APPLICATION_ID=$(echo "$NS_LABELS" | jq -r '.metadata.labels."application-id" // "tbd"')
  OWNER=$(echo "$NS_LABELS" | jq -r '.metadata.labels.owner // "tbd"')
  COST_CENTER=$(echo "$NS_LABELS" | jq -r '.metadata.labels."cost-center" // "tbd"')
  SERVICE_ID=$(echo "$NS_LABELS" | jq -r '.metadata.labels."service-id" // "tbd"')
  
  # Extract cost data from OpenCost
  # Key format: "cluster/namespace" or just "namespace" depending on OpenCost version
  COST_KEY="${CURRENT_CLUSTER}/${ns_name}"
  COST_ENTRY=$(echo "$COSTS_DATA" | jq ".\"$COST_KEY\" // .\"$ns_name\" // {}" 2>/dev/null || echo "{}")
  
  TOTAL_COST=$(echo "$COST_ENTRY" | jq -r '.totalCost // "0"' 2>/dev/null || echo "0")
  CPU_COST=$(echo "$COST_ENTRY" | jq -r '.cpuCost // "0"' 2>/dev/null || echo "0")
  RAM_COST=$(echo "$COST_ENTRY" | jq -r '.ramCost // "0"' 2>/dev/null || echo "0")
  STORAGE_COST=$(echo "$COST_ENTRY" | jq -r '.storageCost // "0"' 2>/dev/null || echo "0")
  GPU_COST=$(echo "$COST_ENTRY" | jq -r '.gpuCost // "0"' 2>/dev/null || echo "0")

  # Build JSON row
  ROW=$(jq -n \
    --arg report_date "$REPORT_DATE" \
    --arg cluster "$CURRENT_CLUSTER" \
    --arg namespace "$ns_name" \
    --arg application_id "$APPLICATION_ID" \
    --arg owner "$OWNER" \
    --arg cost_center "$COST_CENTER" \
    --arg service_id "$SERVICE_ID" \
    --arg total_cost "$TOTAL_COST" \
    --arg cpu_cost "$CPU_COST" \
    --arg ram_cost "$RAM_COST" \
    --arg storage_cost "$STORAGE_COST" \
    --arg gpu_cost "$GPU_COST" \
    '{
      report_date: $report_date,
      cluster: $cluster,
      namespace: $namespace,
      application_id: $application_id,
      owner: $owner,
      cost_center: $cost_center,
      service_id: $service_id,
      total_cost: ($total_cost | tonumber),
      cpu_cost: ($cpu_cost | tonumber),
      ram_cost: ($ram_cost | tonumber),
      storage_cost: ($storage_cost | tonumber),
      gpu_cost: ($gpu_cost | tonumber)
    }')

  ENRICHED_DATA=$(echo "$ENRICHED_DATA" | jq --argjson row "$ROW" '. += [$row]')
done < <(echo "$NAMESPACES_JSON" | jq -r '.items[].metadata.name')

# ============================================================================
# 5. Output in requested format
# ============================================================================

case "$OUTPUT_FORMAT" in
  json)
    echo "$ENRICHED_DATA" | jq '.' > "$OUTPUT_FILE"
    echo -e "${GREEN}[SUCCESS]${NC} JSON report written to: $OUTPUT_FILE"
    ;;
  csv)
    # CSV header
    echo "report_date,cluster,namespace,application_id,owner,cost_center,service_id,total_cost,cpu_cost,ram_cost,storage_cost,gpu_cost" > "$OUTPUT_FILE"

    # CSV rows
    echo "$ENRICHED_DATA" | jq -r '.[] | 
      [.report_date, .cluster, .namespace, .application_id, .owner, .cost_center, .service_id, .total_cost, .cpu_cost, .ram_cost, .storage_cost, .gpu_cost] | 
      @csv' >> "$OUTPUT_FILE"

    echo -e "${GREEN}[SUCCESS]${NC} CSV report written to: $OUTPUT_FILE"
    ;;
  *)
    echo -e "${RED}[ERROR]${NC} Unknown output format: $OUTPUT_FORMAT"
    echo "Supported formats: json, csv"
    exit 1
    ;;
esac

# ============================================================================
# 6. Summary
# ============================================================================

ROW_COUNT=$(echo "$ENRICHED_DATA" | jq 'length')
TOTAL_COST=$(echo "$ENRICHED_DATA" | jq '[.[].total_cost] | add // 0' | xargs printf "%.2f")

echo -e "${GREEN}[INFO]${NC} Summary:"
echo "  Namespaces: $ROW_COUNT"
echo "  Total Cost (${WINDOW}): €${TOTAL_COST}"
echo "  Output: $OUTPUT_FILE"

# ============================================================================
# 7. Coverage Report (how many namespaces have proper labels)
# ============================================================================

COVERAGE=$(echo "$ENRICHED_DATA" | jq -r '[.[] | select(.application_id != "tbd" and .owner != "tbd" and .cost_center != "tbd")] | length')
COVERAGE_PCT=$(echo "scale=1; ($COVERAGE * 100) / $ROW_COUNT" | bc)

echo -e "${GREEN}[INFO]${NC} Label Coverage:"
echo "  Labeled Namespaces: $COVERAGE / $ROW_COUNT ($COVERAGE_PCT%)"
