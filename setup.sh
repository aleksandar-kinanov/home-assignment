#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NAME="devops-assignment"
IMAGE_REPO="devops-assignment-app"
IMAGE_TAG="local"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
RELEASE="app"
NAMESPACE="default"

APP_PORT=8080
PROM_PORT=9090
GRAFANA_PORT=3001

log() { printf '\n==> %s\n' "$1"; }

if [ "${1:-}" = "--cleanup" ]; then
  log "Cleanup: removing Kind cluster '$CLUSTER_NAME' (if it exists)"
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    kind delete cluster --name "$CLUSTER_NAME"
  else
    echo "  cluster '$CLUSTER_NAME' does not exist, nothing to delete"
  fi

  log "Cleanup: removing image '$IMAGE' (if it exists)"
  if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker rmi -f "$IMAGE"
  else
    echo "  image '$IMAGE' does not exist, nothing to remove"
  fi

  log "Cleanup complete"
  exit 0
fi

log "Checking required tools"
missing=0
for cmd in docker kind kubectl helm curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "  missing: $cmd" >&2
    missing=1
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "Install the missing tool(s) above and re-run." >&2
  exit 1
fi

log "Creating Kind cluster '$CLUSTER_NAME' (if it doesn't already exist)"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "  cluster '$CLUSTER_NAME' already exists, skipping creation"
else
  kind create cluster --name "$CLUSTER_NAME" --config kind-config.yaml
fi

log "Building app image ($IMAGE)"
docker build -t "$IMAGE" ./app

log "Loading image into Kind"
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

log "Deploying app + monitoring via Helm"
helm upgrade --install "$RELEASE" charts/app \
  --namespace "$NAMESPACE" --create-namespace \
  --set image.repository="$IMAGE_REPO" \
  --set image.tag="$IMAGE_TAG" \
  --wait --timeout 3m

log "Verifying Prometheus is actually scraping the app (not just deployed)"
verified=0
for _ in $(seq 1 30); do
  if response="$(curl -sf "http://localhost:${PROM_PORT}/api/v1/query" \
      --data-urlencode 'query=up{job="app"}' 2>/dev/null)"; then
    if echo "$response" | jq -e '.data.result[0].value[1] == "1"' >/dev/null 2>&1; then
      verified=1
      break
    fi
  fi
  sleep 2
done

if [ "$verified" -ne 1 ]; then
  echo "Prometheus never reported the app scrape target as up." >&2
  echo "Current target state:" >&2
  curl -sf "http://localhost:${PROM_PORT}/api/v1/targets" >&2 || true
  exit 1
fi
echo "  confirmed: Prometheus target up{job=\"app\"} == 1"

log "Everything is up"
cat <<EOF
  App:        http://localhost:${APP_PORT}/          (metrics: http://localhost:${APP_PORT}/metrics)
  Prometheus: http://localhost:${PROM_PORT}/
  Grafana:    http://localhost:${GRAFANA_PORT}/       (admin credentials: charts/app/values.yaml monitoring.grafana.adminUser/adminPassword)

  The "App Overview" dashboard is pre-loaded in Grafana under Dashboards.
EOF
