#!/bin/bash

# Platform Fleet POC - Cluster Onboarding Script (Flux v2)
# 
# PURPOSE: first-time Flux v2 bootstrap for every enabled cluster declared in
#          clusters-config.yaml that doesn't have it yet. That's it - one job.
#
# This script reads clusters-config.yaml and, for every cluster with
# enabled: true and install_flux: true:
#   1. Switches to the cluster context
#   2. If Flux is not yet bootstrapped in flux_namespace, runs `flux bootstrap`
#      once, at the version validated for that cluster's `group` in
#      catalog/flux.yaml.
#   3. If Flux is already there, this script does nothing further - it is
#      NOT how Flux gets upgraded (see below).
#
# Upgrading an already-bootstrapped cluster is a DIFFERENT, git-native
# operation and deliberately lives in its own script:
#   catalog/promote-flux-release.sh <group>
# That script never talks to a cluster - it only renders new component
# manifests for the group's validated catalog release and commits them under
# each cluster's flux-kpc/gotk-components.yaml. The upgrade itself is applied
# by each cluster's OWN already-running Flux self-management Kustomization on
# its next reconcile - a pull, not a push. See catalog/flux.yaml.
#
# For install_flux: false, Flux installation is skipped entirely.
#
# USAGE:
#   ./onboard-clusters.sh             # Process every enabled cluster
#   ./onboard-clusters.sh kind-dev    # Process only kind-dev

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/clusters-config.yaml"
CATALOG_FILE="$SCRIPT_DIR/catalog/flux.yaml"
CLUSTER_FILTER="${1:-}"

# Git repository settings (edit this to point to your fleet repo)
# Promotion is branch-only: each cluster's own git_ref (from clusters-config.yaml)
# is used directly as flux bootstrap's --branch, so dev clusters track "flux"
# and prod clusters track "flux-prod" independently.
GIT_URL="https://github.com/victorrodriguez1984/kubernetes-ready"

echo "🚀 Platform Fleet POC - Cluster Onboarding"
echo "==========================================="

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 0. Verify configuration file exists
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Configuration file not found: $CONFIG_FILE${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Configuration file found${NC}"

# 0.1 Verify required tools
echo -e "\n${YELLOW}Verifying required tools...${NC}"
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}❌ kubectl is not installed${NC}"
    exit 1
fi
echo -e "${GREEN}✓ kubectl found${NC}"

if ! command -v flux &> /dev/null; then
    echo -e "${YELLOW}⚠️  flux CLI not found. Installing...${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install fluxcd/tap/flux
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -s https://fluxcd.io/install.sh | sudo bash
    fi
fi
echo -e "${GREEN}✓ flux CLI found${NC}"

if ! command -v yq &> /dev/null; then
    echo -e "${YELLOW}⚠️  yq not found. Installing...${NC}"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        brew install yq
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        curl -sL https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /usr/local/bin/yq
        chmod +x /usr/local/bin/yq
    fi
fi
echo -e "${GREEN}✓ yq found${NC}"

# 0.2 Verify GitHub token
echo -e "\n${YELLOW}Verifying GitHub token...${NC}"
if [ -z "$GITHUB_TOKEN" ]; then
    echo -e "${RED}❌ GITHUB_TOKEN environment variable is not set${NC}"
    echo -e "${YELLOW}Configure the token with:${NC}"
    echo -e "  export GITHUB_TOKEN=<your_token_here>"
    exit 1
fi
echo -e "${GREEN}✓ GITHUB_TOKEN is configured${NC}"

# 1. Read clusters from configuration file
echo -e "\n${BLUE}═══════════════════════════════════════${NC}"
echo -e "${BLUE}Reading clusters configuration...${NC}"
echo -e "${BLUE}═══════════════════════════════════════${NC}\n"

# Get list of enabled clusters
CLUSTERS=$(yq eval '.clusters[] | select(.enabled == true) | .name' "$CONFIG_FILE")

if [ -z "$CLUSTERS" ]; then
    echo -e "${RED}❌ No enabled clusters found in configuration${NC}"
    exit 1
fi

CLUSTER_COUNT=$(echo "$CLUSTERS" | wc -l)
echo -e "${YELLOW}Clusters found: $CLUSTER_COUNT${NC}"
echo "$CLUSTERS" | while read -r cluster; do
    echo -e "  - $cluster"
done
echo ""

# 2. Process each cluster
PROCESSED=0
FAILED=0

# NOTE: fed via a here-string (<<<) at the bottom of the loop, not a pipe -
# a pipe would run the whole loop in a subshell, silently discarding the
# PROCESSED/FAILED counters (that was a real bug: the summary always printed
# "Clusters processed: 0" regardless of how many clusters actually ran).
while read -r CLUSTER_NAME; do
    [ -z "$CLUSTER_NAME" ] && continue
    # Skip if there's a filter and it doesn't match
    if [ -n "$CLUSTER_FILTER" ] && [ "$CLUSTER_FILTER" != "$CLUSTER_NAME" ]; then
        continue
    fi

    echo -e "${BLUE}════════════════════════════════════════${NC}"
    echo -e "${BLUE}Processing cluster: $CLUSTER_NAME${NC}"
    echo -e "${BLUE}════════════════════════════════════════${NC}\n"

    # Get cluster configuration
    KUBECONFIG_CONTEXT=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .kubeconfig_context" "$CONFIG_FILE")
    INSTALL_FLUX=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .install_flux" "$CONFIG_FILE")
    FLUX_NAMESPACE=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .flux_namespace" "$CONFIG_FILE")
    ENVIRONMENT=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .environment" "$CONFIG_FILE")
    GIT_REF=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .git_ref" "$CONFIG_FILE")
    GROUP=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .group" "$CONFIG_FILE")

    # Default to flux-system if not specified
    if [ -z "$FLUX_NAMESPACE" ] || [ "$FLUX_NAMESPACE" = "null" ]; then
        FLUX_NAMESPACE="flux-system"
    fi

    # Default to branch "flux" if not specified (backwards compatible)
    if [ -z "$GIT_REF" ] || [ "$GIT_REF" = "null" ]; then
        GIT_REF="flux"
    fi

    # Resolve the Flux version from the group's validated catalog release
    # (catalog/flux.yaml) instead of a per-cluster field - every
    # cluster in the same group always bootstraps at the same, centrally
    # validated release. Refuse to proceed rather than silently falling back
    # to "latest" (whatever the local `flux` CLI binary happens to be).
    if [ -z "$GROUP" ] || [ "$GROUP" = "null" ]; then
        echo -e "${RED}❌ group is not set for $CLUSTER_NAME in clusters-config.yaml - cannot resolve a Flux version from the catalog.${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi

    CATALOG_RELEASE=$(yq eval ".validated.\"$GROUP\"" "$CATALOG_FILE")
    if [ -z "$CATALOG_RELEASE" ] || [ "$CATALOG_RELEASE" = "null" ]; then
        echo -e "${RED}❌ No validated release for group '$GROUP' in catalog/flux.yaml${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi

    FLUX_VERSION=$(yq eval ".releases.\"$CATALOG_RELEASE\".flux_version" "$CATALOG_FILE")
    if [ -z "$FLUX_VERSION" ] || [ "$FLUX_VERSION" = "null" ]; then
        echo -e "${RED}❌ Release '$CATALOG_RELEASE' (group '$GROUP') has no flux_version in catalog/flux.yaml${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi

    # environment decides the top-level clusters/ folder: prod -> clusters/prod/,
    # anything else (dev, etc.) -> clusters/non-prod/
    if [ "$ENVIRONMENT" = "prod" ]; then
        PATH_GROUP="prod"
    else
        PATH_GROUP="non-prod"
    fi

    echo -e "${YELLOW}Context: $KUBECONFIG_CONTEXT${NC}"
    echo -e "${YELLOW}Flux Namespace: $FLUX_NAMESPACE${NC}"
    echo -e "${YELLOW}Install Flux: $INSTALL_FLUX${NC}"
    echo -e "${YELLOW}Flux version (catalog release $CATALOG_RELEASE, group $GROUP): $FLUX_VERSION${NC}"
    echo -e "${YELLOW}Fleet promotion branch: $GIT_REF (clusters/$PATH_GROUP/$CLUSTER_NAME)${NC}"
    echo ""

    # Change kubectl context
    echo -e "${YELLOW}Switching to context: $KUBECONFIG_CONTEXT${NC}"
    if ! kubectl config use-context "$KUBECONFIG_CONTEXT" &> /dev/null; then
        echo -e "${RED}❌ Cannot switch to context: $KUBECONFIG_CONTEXT${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi
    echo -e "${GREEN}✓ Context switched${NC}"

    # Verify connection
    echo -e "${YELLOW}Verifying cluster connection...${NC}"
    if ! kubectl cluster-info &> /dev/null; then
        echo -e "${RED}❌ No connection to cluster${NC}"
        FAILED=$((FAILED + 1))
        continue
    fi
    CLUSTER_INFO=$(kubectl cluster-info | head -1)
    echo -e "${GREEN}✓ Connected: $CLUSTER_INFO${NC}"

    # Process Flux installation if enabled - FIRST-TIME BOOTSTRAP ONLY.
    # If Flux is already there, this script does nothing else: it is not
    # responsible for upgrades. See catalog/promote-flux-release.sh for that.
    if [ "$INSTALL_FLUX" = "true" ]; then
        echo -e "\n${YELLOW}Checking Flux v2 installation in namespace $FLUX_NAMESPACE...${NC}"
        FLUX_INSTALLED=$(kubectl get namespace "$FLUX_NAMESPACE" &>/dev/null && echo "true" || echo "false")

        if [ "$FLUX_INSTALLED" = "true" ]; then
            echo -e "${GREEN}✓ Flux v2 is already installed in $FLUX_NAMESPACE - nothing to do${NC}"
            echo -e "${YELLOW}  (to upgrade it, bump catalog/flux.yaml and run catalog/promote-flux-release.sh $GROUP)${NC}"
        else
            # Bootstrap Flux v2 using generic git (avoids GitHub API repo-creation checks
            # that require organization admin permissions - repo already exists).
            # --branch is per-cluster (GIT_REF): dev clusters track "flux", prod
            # clusters track "flux-prod" - each fully independent.
            # --version pins the exact toolkit release to bootstrap with, resolved
            # from catalog/flux.yaml via this cluster's `group` - decoupled
            # from whatever `flux` CLI binary happens to be on this machine.
            # --path is per-cluster: Flux's own GitRepository+Kustomization ("flux-kpc")
            # will sync everything under clusters/$PATH_GROUP/$CLUSTER_NAME/ (flux-kpc
            # itself, infrastructure.yaml and apps.yaml), standard Flux multi-cluster layout.
            # --token-auth is required so the resulting GitRepository uses the HTTPS
            # token for ongoing sync - without it, flux still generates an SSH deploy
            # key for the GitRepository even though bootstrap itself used HTTPS.
            echo -e "${YELLOW}Bootstrapping Flux $FLUX_VERSION in namespace $FLUX_NAMESPACE...${NC}"
            if flux bootstrap git \
                --url="$GIT_URL" \
                --branch="$GIT_REF" \
                --version="$FLUX_VERSION" \
                --path="platform-fleet-poc/clusters/$PATH_GROUP/$CLUSTER_NAME" \
                --namespace="$FLUX_NAMESPACE" \
                --username=git \
                --password="$GITHUB_TOKEN" \
                --token-auth \
                --silent; then
                echo -e "${GREEN}✓ Flux v2 installed and bootstrapped${NC}"
            else
                echo -e "${RED}❌ Error installing Flux v2${NC}"
                FAILED=$((FAILED + 1))
                continue
            fi

            # Wait for Flux controllers
            echo -e "${YELLOW}Waiting for Flux v2 controllers in $FLUX_NAMESPACE...${NC}"
            for i in {1..60}; do
                SOURCE_READY=$(kubectl get deployment -n "$FLUX_NAMESPACE" source-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                KUSTOMIZE_READY=$(kubectl get deployment -n "$FLUX_NAMESPACE" kustomize-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
                
                if [ "$SOURCE_READY" = "1" ] && [ "$KUSTOMIZE_READY" = "1" ]; then
                    echo -e "${GREEN}✓ Flux v2 controllers ready${NC}"
                    break
                fi
                if [ $i -eq 60 ]; then
                    echo -e "${YELLOW}⚠️  Controllers still initializing (this is normal, proceeding...)${NC}"
                fi
                sleep 2
            done
        fi

        # Cluster resources (infrastructure + apps) are reconciled automatically by
        # Flux itself via the GitOps Kustomizations committed under clusters/$CLUSTER_NAME/
        # (infrastructure.yaml, apps.yaml) — no manual kubectl apply needed.
        echo -e "\n${GREEN}✓ Flux will reconcile infrastructure + apps for $CLUSTER_NAME from git${NC}"

        # Summary
        echo -e "\n${GREEN}✅ Cluster $CLUSTER_NAME completed${NC}"
        echo -e "${YELLOW}Next steps:${NC}"
        echo -e "  Check Flux: ${GREEN}kubectl get kustomizations -n $FLUX_NAMESPACE${NC}"
        echo -e "  Check resources: ${GREEN}kubectl get all -n apps${NC}"
    else
        echo -e "${YELLOW}⚠️  install_flux = false for $CLUSTER_NAME${NC}"
        echo -e "${YELLOW}Flux will not be installed on this cluster${NC}"
        echo -e "${YELLOW}To enable Flux: edit clusters-config.yaml and set install_flux: true${NC}"
    fi

    PROCESSED=$((PROCESSED + 1))
    echo ""
done <<< "$CLUSTERS"

echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "${GREEN}✅ Processing completed${NC}"
echo -e "${BLUE}════════════════════════════════════════${NC}"
echo -e "Clusters processed: $PROCESSED"
if [ $FAILED -gt 0 ]; then
    echo -e "${RED}Clusters with errors: $FAILED${NC}"
fi
