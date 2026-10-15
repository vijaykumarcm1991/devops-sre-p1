# Task 3: Observability, Logging, & Alerting — Detailed Guide

## 1. Overview & Architecture

Task 3 establishes an end-to-end SRE observability stack covering metrics collection, centralized log aggregation, real-time dashboards, and proactive alerting for application failures and memory leaks.

```
+---------------------------------------------------------------------------------------+
|                               Kubernetes Cluster Workload                             |
|                                                                                       |
|   Pod (memory-app-prod)                                                               |
|   ├── Container: memory-app                                                           |
|   │   ├── Port 8080 (/healthcheck) ────────► Scraped by Prometheus ServiceMonitor     |
|   │   ├── Memory Allocations (100MB->400MB)► Tracked via cgroup container metrics    |
|   │   └── Stdout Logs ─────────────────────► Written to /var/log/pods/                |
+---------------------------------------------------+-----------------------------------+
                                                    │
                   ┌────────────────────────────────┴──────────────────┐
                   ▼                                                   ▼
+--------------------------------------+             +----------------------------------+
|           Prometheus Stack           |             |            Loki Stack            |
|                                      |             |                                  |
|  - Node Exporter (Host CPU/Mem/Disk) |             |  - Promtail DaemonSet            |
|  - Kube-State-Metrics (Pod status)   |             |    (Scrapes /var/log/pods/*)     |
|  - ServiceMonitor (/healthcheck)     |             |  - Loki Storage Engine           |
|  - cgroup container metrics          |             +-----------------+----------------+
+------------------+-------------------+                               │
                   │                                                   │
                   ▼                                                   ▼
+---------------------------------------------------------------------------------------+
|                                    Grafana Dashboard                                  |
|                                                                                       |
|  - Row 1: Node Infrastructure (CPU, Memory, Disk Space)                               |
|  - Row 2: Pod Metrics (Working Set Memory vs 400Mi Limit, CPU per version)            |
|  - Row 3: SRE Health & OOM Stats (OOMKilled Count, Restarts, Health Check Status)      |
|  - Row 4: Centralized Log Stream (Live Promtail/Loki Stream of Memory Check Logs)      |
+------------------------------------------+--------------------------------------------+
                                           │
                                           ▼
+---------------------------------------------------------------------------------------+
|                             Alertmanager & Notification Engine                        |
|                                                                                       |
|  - Rule 1: MemoryAppHealthCheckFailure (critical when pod is unready > 15s)           |
|  - Rule 2: MemoryAppOOMKilled (critical when pod terminates with OOMKilled)           |
|  - Rule 3: MemoryAppApproachingOOM (warning when memory exceeds 85% of 400Mi)         |
|  - Route to: Slack Webhook (#alerts-sre) & Email (sre-team@example.com)               |
+---------------------------------------------------------------------------------------+
```

---

## 2. Metrics Collection (kube-prometheus-stack)

Deployed via Helm using `observability/prometheus-grafana-values.yaml`.

### Components Installed:
1. **Prometheus Operator:** Manages Prometheus, Alertmanager, and ServiceMonitor CRDs.
2. **Prometheus Server:** Collects time-series metrics from Kubernetes cgroups and endpoints.
3. **Node Exporter:** Collects hardware and OS metrics (Node CPU, Memory, Disk).
4. **Kube-State-Metrics:** Listens to the Kubernetes API server and generates metrics about object health (Deployments, Pods, restarts, termination reasons).
5. **ServiceMonitor (`observability/service-monitor.yaml`):**
   - Automatically discovers and scrapes `/healthcheck` on port `8080` of the `memory-app` pods every 10 seconds.

---

## 3. Log Aggregation & Centralized Logging (Loki & Promtail)

The application produces structured logs to stdout:
```
2026-10-15 06:15:01,123 - INFO - Starting HTTP server on port 8080 for health checks...
2026-10-15 06:15:01,124 - INFO - Allocated initial 100MB
2026-10-15 06:15:25,456 - INFO - Memory check. Current memory allocated: ~175MB
2026-10-15 06:16:30,789 - INFO - Memory check. Current memory allocated: ~390MB
```

### Loki & Promtail Architecture (`observability/loki-promtail-values.yaml`):
- **Promtail DaemonSet:** Runs on every node, discovers pod log files under `/var/log/pods/memory-app-prod_*/*/*.log`, extracts timestamp, log level, and pod labels (`app`, `version`, `pod`, `namespace`), and ships them to Loki.
- **Loki Server:** Multi-tenant TSDB-backed indexing engine storing log chunks.
- **LogQL Integration:** Queryable directly within Grafana via:
  ```logql
  {namespace="memory-app-prod", app="memory-app"}
  ```

---

## 4. Grafana Dashboard Architecture

A comprehensive dashboard is provisioned in `observability/dashboards/memory-app-dashboard.json`:

| Panel Title | Query (PromQL / LogQL) | Purpose |
| :--- | :--- | :--- |
| **Node CPU Utilization** | `1 - (avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[1m])))` | Monitors physical/virtual node CPU load |
| **Node Memory Utilization** | `1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)` | Assures node memory is never starved by leaks |
| **Node Disk Space Utilization** | `1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})` | Root partition storage tracking |
| **Pod Working Set Memory vs Limit** | `container_memory_working_set_bytes{namespace="memory-app-prod", container="memory-app"}` vs `kube_pod_container_resource_limits` | Visualizes the linear 100MB->400MB memory ramp and subsequent reset |
| **Pod CPU Utilization** | `rate(container_cpu_usage_seconds_total{namespace="memory-app-prod", container="memory-app"}[1m])` | CPU consumption during memory allocation |
| **OOMKilled Container Terminations** | `sum by (pod) (kube_pod_container_status_last_terminated_reason{namespace="memory-app-prod", reason="OOMKilled"})` | Tracks exact count of OOM termination events |
| **Total Container Restarts** | `sum by (pod) (kube_pod_container_status_restarts_total{namespace="memory-app-prod", container="memory-app"})` | Displays crash loops and restart frequency |
| **Health Check Ready Status** | `kube_pod_status_ready{namespace="memory-app-prod", condition="true"}` | Immediate binary indicator of pod availability |
| **Live Application Log Stream** | `{namespace="memory-app-prod", app="memory-app"}` | Live streaming container logs directly in Grafana |

---

## 5. Alerting & Notification Strategy

Configured in `observability/alerts/prometheus-rules.yaml`:

### Alert 1: Application Health Check Failure
- **Rule Name:** `MemoryAppHealthCheckFailure`
- **Condition:** `kube_pod_status_ready{namespace="memory-app-prod", condition="true"} == 0`
- **Evaluation Window:** 15 seconds
- **Severity:** `critical`
- **Description:** Fires when a pod becomes unready, fails liveness/readiness probes, or crashes.

### Alert 2: OOMKilled Event
- **Rule Name:** `MemoryAppOOMKilled`
- **Condition:**
  ```promql
  sum by (namespace, pod, container) (
    kube_pod_container_status_last_terminated_reason{namespace="memory-app-prod", reason="OOMKilled"}
  ) > 0
  ```
- **Evaluation Window:** 0 minutes (instantaneous notification)
- **Severity:** `critical`
- **Description:** Fires immediately when the Linux OOM killer terminates the pod at the 400Mi threshold.

### Alert 3: Approaching Memory Limit (Proactive Warning)
- **Rule Name:** `MemoryAppApproachingOOM`
- **Condition:**
  ```promql
  container_memory_working_set_bytes{namespace="memory-app-prod", container="memory-app"} / (400 * 1024 * 1024) > 0.85
  ```
- **Evaluation Window:** 10 seconds
- **Severity:** `warning`
- **Description:** Triggers when memory consumption reaches 85% of the 400Mi limit (~340Mi), giving SREs early warning before termination occurs.

### Alert Routing (Slack & Email)
Configured in `observability/alerts/alertmanager-config.yaml`:
- **Slack Webhook Channel:** `#alerts-sre` with formatted alert summaries and severity indicators.
- **Email Notifications:** Sent to `sre-team@example.com` via SMTP.

---

## 6. Deployment Instructions

Run the automated installer script:
```bash
bash /home/ubuntu/DevOps-SRE/observability/install-observability.sh
```
Port forward Grafana:
```bash
kubectl port-forward svc/kube-prometheus-grafana -n observability 3000:80
```
Login with `admin` / `prom-operator` and navigate to the pre-loaded **"Memory Application SRE Observability & OOM Dashboard"**.
