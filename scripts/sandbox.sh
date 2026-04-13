#!/usr/bin/env bash
# Usage: ./scripts/sandbox.sh <release-name> [--destroy]
# Spins up or tears down a full-stack sandbox on minikube.
set -euo pipefail

RELEASE="${1:?release name required (e.g. pr-123)}"
NAMESPACE="app-${RELEASE}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHART_DIR="$REPO_ROOT/charts/app"

if [[ "${2:-}" == "--destroy" ]]; then
  echo "Destroying sandbox $RELEASE..."
  helm uninstall "$RELEASE" -n "$NAMESPACE" 2>/dev/null || true
  kubectl delete namespace "$NAMESPACE" --ignore-not-found
  echo "Destroyed."
  exit 0
fi

# Ensure we're pointed at minikube
if ! minikube status >/dev/null 2>&1; then
  echo "minikube is not running. Run: minikube start" >&2
  exit 1
fi

# Build directly into minikube's Docker daemon so imagePullPolicy: Never works
eval "$(minikube docker-env)"

echo "Building images with tag=$RELEASE..."
docker build -t "app-frontend:${RELEASE}" "$REPO_ROOT/apps/frontend"
docker build -t "app-backend:${RELEASE}"  "$REPO_ROOT/apps/backend"

echo "Installing chart..."
helm upgrade --install "$RELEASE" "$CHART_DIR" \
  --namespace "$NAMESPACE" --create-namespace \
  -f "$CHART_DIR/environments/values-local.yaml" \
  --set global.releaseName="$RELEASE" \
  --set components.frontend.image.tag="$RELEASE" \
  --set components.backend.image.tag="$RELEASE" \
  --wait --timeout 3m

MINIKUBE_IP="$(minikube ip)"
echo ""
echo "Sandbox ready:"
echo "  Frontend: http://${RELEASE}.sandbox.local"
echo "  Backend:  http://api-${RELEASE}.sandbox.local"
echo ""
echo "If not already done, add to /etc/hosts:"
echo "  ${MINIKUBE_IP}  ${RELEASE}.sandbox.local api-${RELEASE}.sandbox.local"
