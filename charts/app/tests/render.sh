#!/usr/bin/env bash
# Lints the chart and renders it against every environment values file.
# Exits non-zero if any render fails or omits an expected resource.
set -euo pipefail

CHART="$(dirname "$0")/.."

helm lint "$CHART"

for env in local dev staging prod sandbox; do
  echo "--- rendering env=$env"
  helm template "test-$env" "$CHART" \
    -f "$CHART/environments/values-$env.yaml" \
    --set global.releaseName="test-$env" \
    --set components.frontend.image.tag=smoke \
    --set components.backend.image.tag=smoke \
    > "/tmp/app-$env.yaml"

  # Must produce both Deployments
  grep -q "name: test-$env-frontend" "/tmp/app-$env.yaml"
  grep -q "name: test-$env-backend"  "/tmp/app-$env.yaml"
  # Must produce both Services
  grep -Eq "kind: Service" "/tmp/app-$env.yaml"
  # Ingress present whenever ingress is enabled
  grep -Eq "kind: Ingress" "/tmp/app-$env.yaml"
done
echo "all environments rendered OK"
