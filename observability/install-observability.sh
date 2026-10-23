#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Observability & Logging Stack Deployment (Prometheus, Grafana, Loki, Promtail)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

echo "=========================================================="
echo "Installing Observability, Metrics & Log Aggregation Stack"
echo "=========================================================="

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 1. Add required Helm repositories
echo "[1/6] Adding Prometheus-Community and Grafana Helm repositories..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
helm repo add grafana https://grafana.github.io/helm-charts || true
helm repo update

# 2. Create Observability Namespace
echo "[2/6] Ensuring observability namespace exists..."
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# 3. Deploy kube-prometheus-stack (Prometheus + Grafana + Alertmanager + Node Exporter)
echo "[3/6] Deploying kube-prometheus-stack..."
helm upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
  --namespace observability \
  -f "${SCRIPT_DIR}/prometheus-grafana-values.yaml"

# 4. Deploy Loki and Promtail for centralized log aggregation
echo "[4/6] Deploying Loki and Promtail..."
# Retry the Helm install a few times: the first fetch of the loki-stack chart
# tarball from GitHub reliably hits a transient network timeout in some
# environments ("context deadline exceeded while awaiting headers").
install_loki() {
  helm upgrade --install loki grafana/loki-stack \
    --namespace observability \
    -f "${SCRIPT_DIR}/loki-promtail-values.yaml"
}
install_loki || install_loki || install_loki

# 5. Apply ServiceMonitor and Prometheus Alerting Rules
echo "[5/6] Applying ServiceMonitor and Prometheus Alerts..."
kubectl apply -f "${SCRIPT_DIR}/service-monitor.yaml"
kubectl apply -f "${SCRIPT_DIR}/alerts/prometheus-rules.yaml"

# 6. Import Grafana Dashboard via ConfigMap with label for sidecar auto-import
echo "[6/6] Importing Grafana Dashboard..."
kubectl create configmap memory-app-grafana-dashboard \
  --namespace observability \
  --from-file="${SCRIPT_DIR}/dashboards/memory-app-dashboard.json" \
  --dry-run=client -o yaml | \
  kubectl label -f - --local --dry-run=client -o yaml grafana_dashboard="1" | \
  kubectl apply -f -

echo "=========================================================="
echo "Observability Stack successfully installed!"
echo "Access Grafana:"
echo "  kubectl port-forward svc/kube-prometheus-grafana -n observability 3000:3000"
echo "  Open http://localhost:3000  (Default credentials: admin / prom-operator)"
echo "Access Prometheus:"
echo "  kubectl port-forward svc/kube-prometheus-prometheus -n observability 9090:9090"
echo "  Open http://localhost:9090"
echo "Access Alertmanager:"
echo "  kubectl port-forward svc/kube-prometheus-alertmanager -n observability 9093:9093"
echo "  Open http://localhost:9093"
echo "Access Loki (LogQL):"
echo "  kubectl port-forward svc/loki -n observability 3100:3100"
echo "=========================================================="
