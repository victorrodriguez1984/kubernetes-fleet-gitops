#!/bin/bash
#
# Promote a validated Flux release (catalog/flux.yaml) to every
# cluster in a given `group` - the GitOps-native way to upgrade Flux on
# clusters that are ALREADY bootstrapped (first-time bootstrap is
# onboard-clusters.sh's job, not this script's).
#
# This script NEVER contacts a cluster. It only renders the new Flux
# component manifests (`flux install --export`, a pure local template
# operation) for the group's validated release and commits them to each
# cluster's own:
#   clusters/<prod|non-prod>/<name>/flux-kpc/gotk-components.yaml
# - the exact path each cluster's already-running Flux self-management
# Kustomization ("flux-kpc") watches in this repo. Once pushed, THAT
# Kustomization applies the upgrade itself on its next reconcile - a pull,
# not a push. The trigger is the git commit, not this script calling
# `flux bootstrap`/`flux uninstall` against a live cluster.
#
# USAGE:
#   ./catalog/promote-flux-release.sh <group>
#
# To see the upgrade land immediately instead of waiting for the next
# reconcile interval, run per affected cluster (same command already used
# to force any other reconciliation in this repo - no special upgrade verb):
#   flux reconcile kustomization flux-kpc -n <flux_namespace> --with-source

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CATALOG_FILE="$SCRIPT_DIR/flux.yaml"
CONFIG_FILE="$SCRIPT_DIR/../clusters-config.yaml"

GROUP="${1:-}"

command -v yq &> /dev/null || { echo "❌ yq is required"; exit 1; }
command -v flux &> /dev/null || { echo "❌ flux CLI is required"; exit 1; }

if [ -z "$GROUP" ]; then
    echo "Usage: $0 <group>"
    echo ""
    echo "Groups with a validated release in catalog/flux.yaml:"
    yq eval '.validated | keys | .[]' "$CATALOG_FILE" | sed 's/^/  - /'
    exit 1
fi

CATALOG_RELEASE=$(yq eval ".validated.\"$GROUP\"" "$CATALOG_FILE")
if [ -z "$CATALOG_RELEASE" ] || [ "$CATALOG_RELEASE" = "null" ]; then
    echo "❌ No validated release for group '$GROUP' in $CATALOG_FILE"
    exit 1
fi

FLUX_VERSION=$(yq eval ".releases.\"$CATALOG_RELEASE\".flux_version" "$CATALOG_FILE")
if [ -z "$FLUX_VERSION" ] || [ "$FLUX_VERSION" = "null" ]; then
    echo "❌ Release '$CATALOG_RELEASE' has no flux_version in $CATALOG_FILE"
    exit 1
fi

echo "Group '$GROUP' -> catalog release '$CATALOG_RELEASE' -> Flux $FLUX_VERSION"
echo ""

CLUSTERS=$(yq eval ".clusters[] | select(.group == \"$GROUP\") | select(.install_flux == true) | .name" "$CONFIG_FILE")
if [ -z "$CLUSTERS" ]; then
    echo "No clusters with install_flux: true found for group '$GROUP' - nothing to do"
    exit 0
fi

CHANGED=0
while read -r CLUSTER_NAME; do
    [ -z "$CLUSTER_NAME" ] && continue

    ENVIRONMENT=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .environment" "$CONFIG_FILE")
    FLUX_NAMESPACE=$(yq eval ".clusters[] | select(.name == \"$CLUSTER_NAME\") | .flux_namespace" "$CONFIG_FILE")
    if [ -z "$FLUX_NAMESPACE" ] || [ "$FLUX_NAMESPACE" = "null" ]; then
        FLUX_NAMESPACE="flux-system"
    fi
    if [ "$ENVIRONMENT" = "prod" ]; then
        PATH_GROUP="prod"
    else
        PATH_GROUP="non-prod"
    fi

    MANIFEST="$REPO_ROOT/platform-fleet-poc/clusters/$PATH_GROUP/$CLUSTER_NAME/flux-kpc/gotk-components.yaml"
    if [ ! -f "$MANIFEST" ]; then
        echo "  - $CLUSTER_NAME: not bootstrapped yet ($MANIFEST missing) - run onboard-clusters.sh first, skipping"
        continue
    fi

    CURRENT_VERSION=$(grep -oE '^# Flux Version: v[0-9]+\.[0-9]+\.[0-9]+' "$MANIFEST" | awk '{print $4}')
    if [ "$CURRENT_VERSION" = "$FLUX_VERSION" ]; then
        echo "  - $CLUSTER_NAME: already at $FLUX_VERSION - skipping"
        continue
    fi

    echo "  - $CLUSTER_NAME: ${CURRENT_VERSION:-unknown} -> $FLUX_VERSION (rendering manifest, no cluster contact)"
    flux install --export --version="$FLUX_VERSION" --namespace="$FLUX_NAMESPACE" > "$MANIFEST"
    git -C "$REPO_ROOT" add "$MANIFEST"
    CHANGED=$((CHANGED + 1))
done <<< "$CLUSTERS"

echo ""
if [ "$CHANGED" -eq 0 ]; then
    echo "✓ Nothing to promote - every cluster in group '$GROUP' is already at $FLUX_VERSION"
    exit 0
fi

git -C "$REPO_ROOT" commit -q -m "Promote group '$GROUP' to Flux $FLUX_VERSION (catalog release $CATALOG_RELEASE)"
git -C "$REPO_ROOT" push

echo "✓ Committed and pushed. Each affected cluster's flux-kpc Kustomization will"
echo "  apply this upgrade on its own next reconcile (pull-based, no --force,"
echo "  no uninstall, no finalizers to fight)."
echo ""
echo "  To trigger it now instead of waiting for the interval:"
echo "    flux reconcile kustomization flux-kpc -n <flux_namespace> --with-source"
