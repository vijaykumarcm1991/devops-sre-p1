# DevSecOps & Site Reliability Engineering (SRE) Master Documentation

This directory contains comprehensive architectural explanations and implementation guides for each task of the project located in `/home/ubuntu/DevOps-SRE`.

Repository: [https://github.com/vijaykumarcm1991/devops-sre-p1.git](https://github.com/vijaykumarcm1991/devops-sre-p1.git)

---

## Task Documentation Breakdown

| Document | Scope | Key Highlights |
| :--- | :--- | :--- |
| **[TASK1_DOCKER_CICD.md](TASK1_DOCKER_CICD.md)** | Containerization & Multi-Branch CI/CD | Minimal Alpine Dockerfile, Non-Root (`10001`), Flake8 linting, Bandit SAST (ignoring B104), TruffleHog secrets scan, Pytest suite, Trivy container CVE scanner, Matrix release build (`v1.0.0`, `v1.1.0`, `v1.2.0`), GHCR push, Automated GitOps tag update. |
| **[TASK2_GITOPS_ARGOCD.md](TASK2_GITOPS_ARGOCD.md)** | GitOps Deployment with ArgoCD | ArgoCD Application CRD (self-heal, prune), 3 distinct Deployments running simultaneously, single shared load-balancing Service, strictly enforced `400Mi` memory limit (`OOMKilled` cgroup trigger), enterprise features: Namespaces, ConfigMaps, Secrets, initContainers, RBAC, NetworkPolicies, ResourceQuotas, LimitRanges. |
| **[TASK3_OBSERVABILITY_ALERTING.md](TASK3_OBSERVABILITY_ALERTING.md)** | Observability, Logging & Alerting | Helm-managed `kube-prometheus-stack` & `loki-stack` (Promtail + Loki), complete Grafana dashboard (Node CPU/Mem/Disk, Pod Memory vs 400Mi Limit, Restarts), Prometheus alerts for Health Check Failure & OOMKilled events, Alertmanager Slack & Email routing. |

---

## Project Architecture Overview

```
                                  +---------------------------------------------------+
                                  |              Developer Git Push / PR               |
                                  +-------------------------+-------------------------+
                                                            |
                                                            v
                                  +---------------------------------------------------+
                                  |               GitHub Actions CI/CD                |
                                  |                                                   |
                                  |   [Flake8 Lint] ──► [Bandit SAST] ──► [Pytest]    |
                                  |   [TruffleHog]  ──► [Docker Build]──► [Trivy Scan]|
                                  |   [Matrix Build: v1.0, v1.1, v1.2] ──► [GHCR Push]|
                                  |   [Auto-update k8s/deployments.yaml Image Tags]   |
                                  +-------------------------+-------------------------+
                                                            |
                                                            v
                                  +---------------------------------------------------+
                                  |           GitOps Controller (ArgoCD)              |
                                  |         (Tracking k8s/ in devops-sre-p1)          |
                                  +-------------------------+-------------------------+
                                                            |
                                                            v
+-----------------------------------------------------------------------------------------------------------------------+
|                                        Kubernetes Cluster (memory-app-prod)                                           |
|                                                                                                                       |
|    +--------------------------------------------------------------------------------------------------------------+   |
|    |                                  Shared Service: memory-app-service (Port 80)                                |   |
|    +---------------------------+------------------------------+-------------------------------+-------------------+   |
|                                |                              |                               |                       |
|                                v                              v                               v                       |
|                     +--------------------+         +--------------------+          +--------------------+             |
|                     |   memory-app-v1    |         |   memory-app-v2    |          |   memory-app-v3    |             |
|                     |   (Image v1.0.0)   |         |   (Image v1.1.0)   |          |   (Image v1.2.0)   |             |
|                     | Memory Limit 400Mi |         | Memory Limit 400Mi |          | Memory Limit 400Mi |             |
|                     | (OOMKilled at 90s) |         | (OOMKilled at 90s) |          | (OOMKilled at 90s) |             |
|                     +---------+----------+         +----------+---------+          +----------+---------+             |
|                               |                               |                               |                       |
+-------------------------------|-------------------------------|-------------------------------|-----------------------+
                                |                               |                               |
       ┌────────────────────────┴───────────────────────────────┴───────────────────────────────┴───────────────────────┐
       │                                                                                                               │
       ▼                                                                                                               ▼
+--------------------------------------------------+                                +----------------------------------+
|              Prometheus & Alertmanager           |                                |       Loki & Promtail Logging    |
|                                                  |                                |                                  |
| - ServiceMonitor scrapes /healthcheck            |                                | - Promtail daemonset scrapes     |
| - Alerts: HealthCheckFailure & OOMKilled         |                                |   /var/log/pods/ container logs  |
| - Alertmanager routes to Slack & Email           |                                | - Centralized TSDB log queries   |
+------------------------+-------------------------+                                +-----------------+----------------+
                         │                                                                            │
                         └─────────────────────────────────────┬──────────────────────────────────────┘
                                                               │
                                                               v
                                  +---------------------------------------------------+
                                  |                 Grafana Dashboard                 |
                                  |                                                   |
                                  |  - Node Infrastructure (CPU, Memory, Disk)        |
                                  |  - Pod Working Set Memory vs 400Mi Limit          |
                                  |  - OOMKilled Terminations & Pod Restart Counts    |
                                  |  - Live Memory Check Log Stream (Loki)            |
                                  +---------------------------------------------------+
```

---

## Step-by-Step Reproduction Guide

### Prerequisites
- A local Kubernetes cluster (Minikube, Kind, or K3d):
  ```bash
  # Example with Kind:
  kind create cluster --name devops-sre
  ```
- Helm v3 installed.
- Kubectl installed and pointing to cluster context.

### 1. Deploy ArgoCD & GitOps Application
```bash
bash /home/ubuntu/DevOps-SRE/argocd/install-argocd.sh
```

### 2. Deploy Observability Stack (Prometheus, Grafana, Loki, Alerts)
```bash
bash /home/ubuntu/DevOps-SRE/observability/install-observability.sh
```

### 3. Verify Deployments & OOM Behavior
```bash
# Watch pod memory growth and restarts in memory-app-prod:
kubectl get pods -n memory-app-prod -w

# Check previous termination reason showing OOMKilled:
kubectl get pods -n memory-app-prod -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST_STATE:.status.containerStatuses[0].lastState.terminated.reason
```

### 4. Access Grafana Dashboard
```bash
kubectl port-forward svc/kube-prometheus-grafana -n observability 3000:80
```
- Open browser at `http://localhost:3000`
- Credentials: `admin` / `prom-operator`
- Navigate to: **Memory Application SRE Observability & OOM Dashboard**
