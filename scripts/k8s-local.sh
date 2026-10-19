#!/usr/bin/env bash
# Run the app on YOUR local Kubernetes cluster (k3s by default, or minikube).
#
#   scripts/k8s-local.sh up        build images, load them, helm install/upgrade
#   scripts/k8s-local.sh status    pods and services
#   scripts/k8s-local.sh logs      follow backend logs
#   scripts/k8s-local.sh urls      where to open it
#   scripts/k8s-local.sh forward   tunnel to localhost:13300 / 18300 (use if 3300/8300 hang)
#   scripts/k8s-local.sh down      remove the app (database data is kept)
#   scripts/k8s-local.sh destroy   remove the app AND the database data
#
# Ports used on this machine: frontend 3300, backend 8300. They avoid 3000, 8000,
# 8001 (Docker stack) and 8080 (Jenkins). Postgres is never published.
set -euo pipefail
cd "$(dirname "$0")/.."

NS="${NS:-biodata}"
RELEASE="${RELEASE:-biodata}"
RUNTIME="${RUNTIME:-k3s}"          # k3s | minikube
CHART="helm/biodata"

# Use the active-config symlink when it exists and KUBECONFIG is not already set.
if [ -z "${KUBECONFIG:-}" ] && [ -e "$HOME/.kube/active-config" ]; then
  export KUBECONFIG="$HOME/.kube/active-config"
fi

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1" >&2; exit 1; }; }

load_image() {
  case "$RUNTIME" in
    k3s)      docker save "$1" | sudo k3s ctr images import - ;;
    minikube) minikube image load "$1" ;;
    *)        echo "RUNTIME must be k3s or minikube (got '$RUNTIME')" >&2; exit 1 ;;
  esac
}

extra_args=()
if [ "$RUNTIME" = "minikube" ]; then
  # minikube has no built-in load balancer: expose fixed node ports instead.
  extra_args+=(--set frontend.service.type=NodePort --set frontend.service.nodePort=30300
               --set backend.service.type=NodePort  --set backend.service.nodePort=30800)
fi

cmd="${1:-}"
case "$cmd" in
  up)
    need docker; need kubectl; need helm
    echo "==> cluster: $(kubectl config current-context)"
    echo "==> building images"
    docker build -t biodata-backend:local  ./backend
    docker build -t biodata-frontend:local ./frontend
    echo "==> loading images into $RUNTIME"
    load_image biodata-backend:local
    load_image biodata-frontend:local
    echo "==> helm upgrade --install"
    helm upgrade --install "$RELEASE" "$CHART" \
      --namespace "$NS" --create-namespace \
      -f "$CHART/values-local.yaml" "${extra_args[@]}" \
      --wait --timeout 5m
    "$0" urls
    ;;
  status)
    need kubectl
    kubectl -n "$NS" get pods,svc
    ;;
  logs)
    need kubectl
    kubectl -n "$NS" logs -f "deploy/${RELEASE}-backend"
    ;;
  urls)
    if [ "$RUNTIME" = "minikube" ]; then
      echo "frontend: $(minikube service "${RELEASE}-frontend" -n "$NS" --url 2>/dev/null | head -1)"
      echo "backend : $(minikube service "${RELEASE}-backend"  -n "$NS" --url 2>/dev/null | head -1)/health"
    else
      echo "frontend: http://localhost:3300"
      echo "backend : http://localhost:8300/health"
      echo "(3300/8300 hang or refuse? run: scripts/k8s-local.sh forward  ->  localhost:13300 / 18300)"
    fi
    ;;
  forward)
    # Direct tunnel to the pods through the Kubernetes API, bypassing the node's
    # load-balancer rules. It uses DIFFERENT local ports (13300/18300) on purpose:
    # 3300/8300 are already claimed by k3s' iptables rules, which can swallow
    # traffic aimed at them even when a listener exists.
    need kubectl
    echo "==> frontend: http://localhost:13300   backend: http://localhost:18300/health   (Ctrl+C to stop)"
    trap 'kill 0' EXIT INT TERM
    kubectl -n "$NS" port-forward "svc/${RELEASE}-frontend" 13300:3300 &
    kubectl -n "$NS" port-forward "svc/${RELEASE}-backend" 18300:8300 &
    wait
    ;;
  down)
    need helm
    helm uninstall "$RELEASE" -n "$NS"
    echo "App removed. Database volume kept; 'up' will reuse it."
    ;;
  destroy)
    need helm; need kubectl
    helm uninstall "$RELEASE" -n "$NS" || true
    kubectl -n "$NS" delete pvc --all
    kubectl delete namespace "$NS" --ignore-not-found
    ;;
  *)
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac