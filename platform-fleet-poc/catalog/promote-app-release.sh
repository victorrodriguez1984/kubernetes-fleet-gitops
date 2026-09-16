#!/bin/bash

# Platform Fleet POC - Application Release Promotion (GitOps trigger)
#
# PURPOSE: generic promotion trigger for any application catalogued under
#          catalog/<app>.yaml, mirroring catalog/promote-flux-release.sh's
#          model but generalized for two kinds of catalog entries:
#
#   kind: helm  -> only a chart `version` is pinned - the HelmRelease +
#                  HelmRepository resolve the actual container image(s)
#                  internally, so there's nothing else to render. No app in
#                  this repo uses this kind yet (no HelmRelease exists) -
#                  reserved for when one is catalogued; see the TODO below.
#   kind: image -> there is no Helm chart in the loop, so the catalog file
#                  itself pins registry + repository + tag, and this script
#                  patches the Kustomize `images:` transformer that
#                  controls the running tag (apps/base/<app>/kustomization.yaml).
#
# Like promote-flux-release.sh, this NEVER touches a live cluster - it only
# edits/commits/pushes a file in this repo. The rollout itself is applied by
# each cluster's own already-running `apps` Kustomization on its next
# reconcile (pull-based), or immediately via:
#   flux reconcile kustomization apps -n <flux_namespace> --with-source
#
# USAGE:
#   ./catalog/promote-app-release.sh <app> <group>
#   e.g. ./catalog/promote-app-release.sh podinfo resource-plane

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP="$1"
GROUP="$2"

if [ -z "$APP" ] || [ -z "$GROUP" ]; then
    echo "Usage: $0 <app> <group>"
    echo "  e.g. $0 podinfo resource-plane"
    exit 1
fi

CATALOG_FILE="$SCRIPT_DIR/$APP.yaml"
BASE_KUSTOMIZATION="$REPO_ROOT/apps/base/$APP/kustomization.yaml"

if [ ! -f "$CATALOG_FILE" ]; then
    echo "❌ No catalog file for app '$APP': $CATALOG_FILE"
    exit 1
fi

if [ ! -f "$BASE_KUSTOMIZATION" ]; then
    echo "❌ apps/base/$APP/kustomization.yaml not found - is '$APP' a valid app?"
    exit 1
fi

KIND=$(yq eval '.kind' "$CATALOG_FILE")
RELEASE=$(yq eval ".validated.\"$GROUP\"" "$CATALOG_FILE")

if [ -z "$RELEASE" ] || [ "$RELEASE" == "null" ]; then
    echo "❌ No validated release for group '$GROUP' in $CATALOG_FILE"
    exit 1
fi

echo "App: $APP | Group: $GROUP | Kind: $KIND | Validated release: $RELEASE"

cd "$REPO_ROOT"

case "$KIND" in
  image)
    REGISTRY=$(yq eval '.registry' "$CATALOG_FILE")
    REPOSITORY=$(yq eval ".releases.\"$RELEASE\".repository" "$CATALOG_FILE")
    TAG=$(yq eval ".releases.\"$RELEASE\".tag" "$CATALOG_FILE")

    if [ -z "$REPOSITORY" ] || [ "$REPOSITORY" == "null" ] || [ -z "$TAG" ] || [ "$TAG" == "null" ]; then
        echo "❌ Release '$RELEASE' in $CATALOG_FILE is missing repository/tag"
        exit 1
    fi

    echo "Target image: $REGISTRY/$REPOSITORY:$TAG"
    echo "(registry is omitted from the manifest/transformer itself when it's the"
    echo " implicit docker.io default - Kustomize's images.name must match the"
    echo " literal image reference already in the manifest, i.e. '$REPOSITORY')"

    CURRENT_TAG=$(yq eval ".images[] | select(.name == \"$REPOSITORY\") | .newTag" "$BASE_KUSTOMIZATION")

    if [ -z "$CURRENT_TAG" ] || [ "$CURRENT_TAG" == "null" ]; then
        echo "❌ No images[] entry with name '$REPOSITORY' in $BASE_KUSTOMIZATION"
        echo "   Add one first (images: [{name: $REPOSITORY, newTag: ...}]) - this"
        echo "   script only patches an existing entry, it never creates one."
        exit 1
    fi

    if [ "$CURRENT_TAG" == "$TAG" ]; then
        echo "✓ apps/base/$APP is already pinned to $TAG - nothing to do."
        exit 0
    fi

    yq eval -i "(.images[] | select(.name == \"$REPOSITORY\") | .newTag) = \"$TAG\"" "$BASE_KUSTOMIZATION"
    ;;
  helm)
    # TODO: once a HelmRelease-based app/add-on is catalogued (kind: helm,
    # only a chart `version` field), patch its
    # spec.chart.spec.version here - e.g.:
    #   yq eval -i ".spec.chart.spec.version = \"$RELEASE_VERSION\"" "$HELMRELEASE_FILE"
    # No such app exists yet, so this is intentionally not implemented.
    echo "❌ kind: helm is not implemented yet (no HelmRelease-based app is catalogued). See TODO in this script."
    exit 1
    ;;
  *)
    echo "❌ Unknown kind '$KIND' in $CATALOG_FILE (expected 'image' or 'helm')"
    exit 1
    ;;
esac

git add "$BASE_KUSTOMIZATION"

if git diff --cached --quiet; then
    echo "No changes to commit."
    exit 0
fi

git commit -m "Promote app '$APP' (group '$GROUP') to $RELEASE ($REPOSITORY:$TAG)"
git push

echo ""
echo "Pushed. To reconcile immediately instead of waiting for the next interval:"
echo "  flux reconcile kustomization apps -n <flux_namespace> --with-source"
