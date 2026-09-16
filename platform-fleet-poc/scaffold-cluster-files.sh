#!/bin/bash

# Platform Fleet POC - Cluster Scaffold Script
#
# PURPOSE: Create cluster directory structure and base manifests from clusters-config.yaml.
# DOES NOT bootstrap Flux - that's onboard-clusters.sh's job.
#
# USAGE:
#   ./scaffold-cluster-files.sh             # Scaffold all enabled clusters
#   ./scaffold-cluster-files.sh kind-dev    # Scaffold only kind-dev

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/clusters-config.yaml"
CLUSTER_FILTER="${1:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi

CLUSTERS=$(yq eval '.clusters[] | select(.enabled == true) | .name' "$CONFIG_FILE")

if [ -z "$CLUSTERS" ]; then
    echo -e "${RED}❌ No enabled clusters found${NC}"
    exit 1
fi

while read -r CLUSTER_NAME; do
    [ -z "$CLUSTER_NAME" ] && continue
    [ -n "$CLUSTER_FILTER" ] && [ "$CLUSTER_FILTER" != "$CLUSTER_NAME" ] && continue

    echo -e "${YELLOW}Scaffolding $CLUSTER_NAME...${NC}"

    GROUP=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .group" "$CONFIG_FILE")
    SKU=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .sku" "$CONFIG_FILE")
    ENVIRONMENT=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .environment" "$CONFIG_FILE")
    FLUX_NAMESPACE=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .flux_namespace" "$CONFIG_FILE")
    INSTALL_FLUX=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .install_flux" "$CONFIG_FILE")

    [ -z "$FLUX_NAMESPACE" ] || [ "$FLUX_NAMESPACE" = "null" ] && FLUX_NAMESPACE="flux-kpc"

    # Resolve overlay: prefer <group>-<sku> if both overlays exist
    OVERLAY="$GROUP"
    if [ -n "$SKU" ] && [ "$SKU" != "null" ]; then
        CANDIDATE="${GROUP}-${SKU}"
        if [ -d "$SCRIPT_DIR/apps/overlays/$CANDIDATE" ] && [ -d "$SCRIPT_DIR/infrastructure/overlays/$CANDIDATE" ]; then
            OVERLAY="$CANDIDATE"
        fi
    fi

    # Path: prod -> clusters/prod, else -> clusters/non-prod
    [ "$ENVIRONMENT" = "prod" ] && PATH_GROUP="prod" || PATH_GROUP="non-prod"

    CLUSTER_DIR="$SCRIPT_DIR/clusters/$PATH_GROUP/$CLUSTER_NAME"
    mkdir -p "$CLUSTER_DIR"

    TODAY=$(date -u +%Y-%m-%dT00:00:00Z)

    # Create kustomization.yaml if missing
    if [ ! -f "$CLUSTER_DIR/kustomization.yaml" ]; then
        cat > "$CLUSTER_DIR/kustomization.yaml" <<YAML
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
YAML
        [ "$INSTALL_FLUX" = "true" ] && echo "  - $FLUX_NAMESPACE" >> "$CLUSTER_DIR/kustomization.yaml"
        cat >> "$CLUSTER_DIR/kustomization.yaml" <<YAML
  - infrastructure.yaml
  - k8s-apps.yaml
  - cluster-context.yaml
YAML
        echo -e "${GREEN}✓ kustomization.yaml${NC}"
    fi

    # Create infrastructure.yaml if missing
    if [ ! -f "$CLUSTER_DIR/infrastructure.yaml" ]; then
        cat > "$CLUSTER_DIR/infrastructure.yaml" <<YAML
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: infrastructure
  namespace: $FLUX_NAMESPACE
spec:
  interval: 10m0s
  sourceRef:
    kind: GitRepository
    name: $FLUX_NAMESPACE
  path: ./platform-fleet-poc/infrastructure/overlays/$OVERLAY
  prune: true
  wait: true
YAML
        echo -e "${GREEN}✓ infrastructure.yaml${NC}"
    fi

    # Create k8s-apps.yaml if missing
    if [ ! -f "$CLUSTER_DIR/k8s-apps.yaml" ]; then
        {
            cat <<YAML
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: apps
  namespace: $FLUX_NAMESPACE
spec:
  interval: 10m0s
  sourceRef:
    kind: GitRepository
    name: $FLUX_NAMESPACE
  path: ./platform-fleet-poc/apps/overlays/$OVERLAY
YAML
            # Add postBuild substitutions only for resource-plane overlays
            if [[ "$OVERLAY" == resource-plane* ]]; then
                cat <<YAML
  postBuild:
    substitute:
      SPOKE_CLUSTER_ID: $CLUSTER_NAME
      SPOKE_ENVIRONMENT: $ENVIRONMENT
      HUB_PROMETHEUS_WRITE_URL: http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write
YAML
            fi
            cat <<YAML
  prune: true
  wait: true
  dependsOn:
    - name: infrastructure
YAML
        } > "$CLUSTER_DIR/k8s-apps.yaml"
        echo -e "${GREEN}✓ k8s-apps.yaml${NC}"
    fi

    # Create cluster-context.yaml if missing
    if [ ! -f "$CLUSTER_DIR/cluster-context.yaml" ]; then
        cat > "$CLUSTER_DIR/cluster-context.yaml" <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-context
  namespace: $FLUX_NAMESPACE
  labels:
    app.kubernetes.io/name: cluster-context
    app.kubernetes.io/component: inventory
    app.kubernetes.io/managed-by: fluxcd
    finops.mbcp.io/cluster-id: $CLUSTER_NAME
    finops.mbcp.io/environment: $ENVIRONMENT
    finops.mbcp.io/profile: $OVERLAY
  annotations:
    finops.mbcp.io/latest-change-id: pending-from-morpheus
    finops.mbcp.io/latest-change-type: bootstrap
    finops.mbcp.io/latest-change-date: "$TODAY"
data:
  requestId: pending-from-morpheus
  clusterId: $CLUSTER_NAME
  clusterProfile: $OVERLAY
  tenant: tbd
  environment: $ENVIRONMENT
  technicalOwner: tbd
  financialAllocationRef: tbd
  requestedWorkerCapacity: tbd
  exceptionId: none
  lifecycleState: active
YAML
        echo -e "${GREEN}✓ cluster-context.yaml${NC}"
    fi

    echo -e "${GREEN}✅ $CLUSTER_NAME${NC}"
    echo ""
done <<< "$CLUSTERS"
