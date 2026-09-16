#!/bin/bash
set -euo pipefail

#
# Export multi-cluster cost showback dataset
# Combines OpenCost API data with cluster-context.yaml metadata
#
# Usage:
#   export-daily-costs.sh [window] [output-format]
#
# Arguments:
#   window: OpenCost window (1d, 7d, 30d), default 30d
#   output-format: csv or json, default csv
#
# Prerequisites:
#   - OpenCost API exposed via HTTPRoute (https://finops.kyndemo.live)
#   - yq installed (brew install yq)
#   - jq installed (brew install jq)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

WINDOW="${1:-30d}"
OUTPUT_FORMAT="${2:-csv}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
OUTPUT_FILE="$SCRIPT_DIR/reports/showback_${WINDOW}_${TIMESTAMP}.${OUTPUT_FORMAT}"

# OpenCost API endpoint (via HTTPRoute)
OPENCOST_API="${OPENCOST_API:-https://finops.kyndemo.live}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Ensure reports directory exists
mkdir -p "$SCRIPT_DIR/reports"

echo -e "${YELLOW}[INFO]${NC} Generating showback dataset (window: $WINDOW, format: $OUTPUT_FORMAT)"

# ============================================================================
# 1. Query OpenCost API for allocation data
# ============================================================================

echo -e "${YELLOW}[INFO]${NC} Querying OpenCost API: $OPENCOST_API/allocation"

COSTS_JSON=$(curl -sk "${OPENCOST_API}/allocation?window=${WINDOW}&aggregate=cluster" 2>&1) || {
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
# 2. Extract cluster costs from API response
# ============================================================================

# OpenCost returns: { "data": { "<cluster-id>": { "totalCost": "0.79", ... }, ... } }
COSTS_DATA=$(echo "$COSTS_JSON" | jq '.data[0] // {}')

# ============================================================================
# 3. Build enriched dataset by reading cluster-context.yaml files
# ============================================================================

ENRICHED_DATA='[]'

# Loop over all cluster directories in non-prod
for cluster_dir in "$REPO_ROOT/clusters/non-prod"/*/; do
  CLUSTER_NAME=$(basename "$cluster_dir")
  CLUSTER_CONTEXT="$cluster_dir/cluster-context.yaml"

  # Skip if cluster-context.yaml doesn't exist
  if [[ ! -f "$CLUSTER_CONTEXT" ]]; then
    echo -e "${YELLOW}[WARN]${NC} No cluster-context.yaml found for $CLUSTER_NAME, skipping"
    continue
  fi

  # Extract cluster metadata
  CLUSTER_ID=$(yq '.data.clusterId' "$CLUSTER_CONTEXT" 2>/dev/null || echo "")
  TENANT=$(yq '.data.tenant' "$CLUSTER_CONTEXT" 2>/dev/null || echo "")
  OWNER=$(yq '.data.technicalOwner' "$CLUSTER_CONTEXT" 2>/dev/null || echo "")
  ENVIRONMENT=$(yq '.data.environment' "$CLUSTER_CONTEXT" 2>/dev/null || echo "")
  PROFILE=$(yq '.data.clusterProfile' "$CLUSTER_CONTEXT" 2>/dev/null || echo "")
  LIFECYCLE=$(yq '.data.lifecycleState' "$CLUSTER_CONTEXT" 2>/dev/null || echo "")
  ALLOCATION_REF=$(yq '.data.financialAllocationRef' "$CLUSTER_CONTEXT" 2>/dev/null || echo "")

  # Extract cost data from OpenCost (if available)
  # Use .[] to access nested object by key (handles cluster IDs with hyphens)
  COST_ENTRY=$(echo "$COSTS_DATA" | jq ".\"$CLUSTER_ID\" // {}" 2>/dev/null || echo "{}")
  TOTAL_COST=$(echo "$COST_ENTRY" | jq -r '.totalCost // "0"' 2>/dev/null || echo "0")
  CPU_COST=$(echo "$COST_ENTRY" | jq -r '.cpuCost // "0"' 2>/dev/null || echo "0")
  RAM_COST=$(echo "$COST_ENTRY" | jq -r '.ramCost // "0"' 2>/dev/null || echo "0")
  STORAGE_COST=$(echo "$COST_ENTRY" | jq -r '.storageCost // "0"' 2>/dev/null || echo "0")
  GPU_COST=$(echo "$COST_ENTRY" | jq -r '.gpuCost // "0"' 2>/dev/null || echo "0")

  # Build JSON row
  ROW=$(jq -n \
    --arg cluster_id "$CLUSTER_ID" \
    --arg cluster_name "$CLUSTER_NAME" \
    --arg tenant "$TENANT" \
    --arg owner "$OWNER" \
    --arg environment "$ENVIRONMENT" \
    --arg profile "$PROFILE" \
    --arg lifecycle "$LIFECYCLE" \
    --arg allocation_ref "$ALLOCATION_REF" \
    --arg total_cost "$TOTAL_COST" \
    --arg cpu_cost "$CPU_COST" \
    --arg ram_cost "$RAM_COST" \
    --arg storage_cost "$STORAGE_COST" \
    --arg gpu_cost "$GPU_COST" \
    --arg report_date "$REPORT_DATE" \
    '{
      report_date: $report_date,
      cluster_id: $cluster_id,
      cluster_name: $cluster_name,
      tenant: $tenant,
      owner: $owner,
      environment: $environment,
      profile: $profile,
      lifecycle: $lifecycle,
      allocation_ref: $allocation_ref,
      total_cost: ($total_cost | tonumber),
      cpu_cost: ($cpu_cost | tonumber),
      ram_cost: ($ram_cost | tonumber),
      storage_cost: ($storage_cost | tonumber),
      gpu_cost: ($gpu_cost | tonumber)
    }')

  ENRICHED_DATA=$(echo "$ENRICHED_DATA" | jq --argjson row "$ROW" '. += [$row]')
done

# ============================================================================
# 4. Output in requested format
# ============================================================================

case "$OUTPUT_FORMAT" in
  json)
    echo "$ENRICHED_DATA" | jq '.' > "$OUTPUT_FILE"
    echo -e "${GREEN}[SUCCESS]${NC} JSON report written to: $OUTPUT_FILE"
    ;;
  csv)
    # CSV header
    echo "report_date,cluster_id,cluster_name,tenant,owner,environment,profile,lifecycle,allocation_ref,total_cost,cpu_cost,ram_cost,storage_cost,gpu_cost" > "$OUTPUT_FILE"

    # CSV rows
    echo "$ENRICHED_DATA" | jq -r '.[] | 
      [.report_date, .cluster_id, .cluster_name, .tenant, .owner, .environment, .profile, .lifecycle, .allocation_ref, .total_cost, .cpu_cost, .ram_cost, .storage_cost, .gpu_cost] | 
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
# 5. Summary
# ============================================================================

ROW_COUNT=$(echo "$ENRICHED_DATA" | jq 'length')
TOTAL_COST=$(echo "$ENRICHED_DATA" | jq '[.[].total_cost] | add // 0' | xargs printf "%.2f")

echo -e "${GREEN}[INFO]${NC} Summary:"
echo "  Clusters: $ROW_COUNT"
echo "  Total Cost (${WINDOW}): €${TOTAL_COST}"
echo "  Output: $OUTPUT_FILE"
