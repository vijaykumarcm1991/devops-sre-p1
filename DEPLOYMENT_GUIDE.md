# Deployment Guide — DevSecOps & SRE Assessment Stack

This guide walks through deploying the complete stack on a **local** Kubernetes cluster
(e.g. **Kind**, Minikube, or K3d) — no cloud accounts required. It covers the GitOps
deployment (ArgoCD) and the full observability stack (Prometheus, Grafana, Loki,
Promtail, Alertmanager), plus the exact **port-forward** commands and **credentials**
to reach every UI.

All manifests live in this repository and are applied via the provided scripts.

---

## 0. Prerequisites

| Tool    | Purpose                            | Install hint                |
| :------ | :--------------------------------- | :-------------------------- |
| Docker  | Container runtime for the cluster  | `docker --version`          |
| `kind`  | Local Kubernetes (or Minikube/K3d) | `kind create cluster`       |
| `kubectl` | Talk to the cluster              | `kubectl version --client`  |
| `helm`  | Deploy Prometheus/Grafana/Loki     | `helm version`              |

Create a local cluster (name can be anything; the project docs use `devops-sre`):

```bash
kind create cluster --name devops-sre
kubectl cluster-info                # confirm the context points at your cluster
```

> **Note for this machine:** if `docker build` / `kind create` fails with
> `error getting credentials - exec: "docker-credential-desktop": executable file
> not found`, your `~/.docker/config.json` still references the missing Docker
> Desktop credential helper (`"credsStore": "desktop"`). Remove that line (or the
> whole helper entry) so Docker falls back to default (no) credentials.

---

## 1. Task 1 — Docker image (build verification)

The project already ships a minimal, non-root Alpine image. To build and smoke-test it:

```bash
# Build the image
docker build -t memory-app:local .

# Run it and hit the healthcheck (the app deliberately grows memory; it will OOMKill)
docker run -d --name memory-app -p 8080:8080 memory-app:local
curl http://127.0.0.1:8080/healthcheck            # -> {"status": "healthy"}
docker logs -f memory-app                        # watch the memory ramp
docker rm -f memory-app
```

### CI/CD pipelines
- **PR pipeline** (`.github/workflows/pr-ci.yaml`) — runs on every PR to `main`:
  Flake8 lint, Bandit SAST (`-s B104`), TruffleHog secret scan, Pytest, and a
  Docker build + Trivy vulnerability scan.
- **Release pipeline** (`.github/workflows/release.yaml`) — on merge to `main`:
  builds a matrix of `v1.0.0`, `v1.1.0`, `v1.2.0`, pushes to GHCR, then
  auto-updates the image tags in `k8s/deployments.yaml` and commits back.
- Enable **branch protection** on `main` (Settings → Branches → ruleset):
  require a PR, 1 approval, and all status checks passing before merge.

---

## 2. Task 2 — ArgoCD GitOps deployment

### 2.1 Install ArgoCD and register the app

```bash
bash argocd/install-argocd.sh
```

This:
1. Creates the `argocd` namespace and applies the official ArgoCD manifests.
2. Waits for the `argocd-server` deployment.
3. Applies `argocd/application.yaml`, which tells ArgoCD to track the `k8s/`
   directory of this repository into namespace `memory-app-prod` with
   `selfHeal` + `prune` enabled.

> The installer tolerates the known oversized `applicationsets.argoproj.io` CRD
> (annotation > 256KB) that newer clusters reject — it does not affect the
> `Application`/`AppProject` CRDs this project uses.

### 2.2 Confirm the GitOps sync

```bash
kubectl get applications -n argocd          # memory-app should be Synced / Healthy
kubectl get deploy -n memory-app-prod       # memory-app-v1/v2/v3
kubectl get pods -n memory-app-prod         # 3 pods, each OOMKilling & restarting
```

### 2.3 Verify the OOMKilled drill

The app ramps 100MB → 500MB and each pod is capped at a **400Mi** memory limit, so the
kernel OOM-kills it well before it can exhaust node memory, then it auto-restarts:

```bash
kubectl get pods -n memory-app-prod \
  -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST:.status.containerStatuses[0].lastState.terminated.reason
```

You should see `RESTARTS > 0` and `LAST = OOMKilled` for all three pods.

### 2.4 ArgoCD UI

```bash
# Retrieve the admin initial password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d && echo

# Port-forward the ArgoCD server UI (HTTPS)
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

| Field      | Value                                    |
| :--------- | :--------------------------------------- |
| **URL**    | `https://localhost:8080`                 |
| **User**   | `admin`                                  |
| **Password** | output of the command above            |

---

## 3. Task 3 — Observability, Logging & Alerting

### 3.1 Install the stack

```bash
bash observability/install-observability.sh
```

This:
1. Adds the `prometheus-community` and `grafana` Helm repos.
2. Creates the `observability` namespace.
3. Installs `kube-prometheus` (`kube-prometheus-stack`): Prometheus, Grafana,
   Alertmanager, Node Exporter, kube-state-metrics.
4. Installs `loki` (`loki-stack`): Loki + Promtail (retried up to 3× for the
   known transient chart-download timeout).
5. Applies the `memory-app-monitor` ServiceMonitor and `memory-app-alerts`
   PrometheusRules (HealthCheckFailure / OOMKilled / ApproachingOOM).
6. Imports the Grafana dashboard via a sidecar-labeled ConfigMap.

Confirm everything is Ready:

```bash
kubectl get pods -n observability
```

Expected fully-healthy output:

```
alertmanager-kube-prometheus-alertmanager-0      2/2   Running
kube-prometheus-grafana-*                        3/3   Running
kube-prometheus-kube-state-metrics-*             1/1   Running
kube-prometheus-operator-*                       1/1   Running
kube-prometheus-prometheus-node-exporter-*       1/1   Running
loki-0                                           1/1   Running
loki-promtail-*                                  1/1   Running
prometheus-kube-prometheus-prometheus-0          2/2   Running
```

### 3.2 Access every UI (port-forwards + credentials)

Run each `kubectl port-forward` in its own terminal (or background them), then open the
given URL.

| UI          | Port-forward command                                                       | URL / Credentials                          |
| :---------- | :------------------------------------------------------------------------- | :----------------------------------------- |
| **Grafana** | `kubectl port-forward svc/kube-prometheus-grafana -n observability 3000:3000` | `http://localhost:3000` · `admin` / `prom-operator` |
| **Prometheus** | `kubectl port-forward svc/kube-prometheus-prometheus -n observability 9090:9090` | `http://localhost:9090`                 |
| **Alertmanager** | `kubectl port-forward svc/kube-prometheus-alertmanager -n observability 9093:9093` | `http://localhost:9093`           |
| **Loki**    | `kubectl port-forward svc/loki -n observability 3100:3100`                  | `http://localhost:3100` (LogQL API)        |
| **ArgoCD**  | `kubectl port-forward svc/argocd-server -n argocd 8080:443`                 | `https://localhost:8080` · `admin` / (pwd from §2.4) |
| **memory-app** | `kubectl port-forward svc/memory-app-service -n memory-app-prod 8081:80`  | `http://localhost:8081/healthcheck`        |

> **Grafana credentials:** `admin` / `prom-operator` (set in
> `observability/prometheus-grafana-values.yaml`).

### 3.3 Grafana dashboard

After port-forwarding Grafana, open **http://localhost:3000**, log in
(`admin` / `prom-operator`), and open:

> **Dashboards → Memory Application SRE Observability & OOM Dashboard**

It includes rows for Node CPU/Memory/Disk, Pod memory vs the 400Mi limit, OOMKilled
counts & restarts, health-check status, and a live Loki log stream for
`namespace="memory-app-prod"`.

### 3.4 Verify alerting end-to-end

Query Prometheus for the custom alerts (they fire as the app OOM-kills):

```bash
curl -s "http://localhost:9090/api/v1/rules" | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print([ (r['name'],r['state']) for g in d['data']['groups'] for r in g['rules'] if r['name'].startswith('MemoryApp')])"
```

Expected: `MemoryAppOOMKilled` = `firing`, `MemoryAppHealthCheckFailure` /
`MemoryAppApproachingOOM` = `pending`/`firing` depending on the pod cycle.

Alertmanager is configured (`observability/alerts/alertmanager-config.yaml`) to route
these to Slack (`#alerts-sre`) and email (`sre-team@example.com`) as a bonus.
**Replace the placeholder `api_url`/SMTP values** with your real webhook/email before
relying on notifications.

---

## 4. Troubleshooting

| Symptom                                                | Fix                                                                             |
| :----------------------------------------------------- | :------------------------------------------------------------------------------ |
| ArgoCD app stuck `Unknown` / `ComparisonError` (repo-server connection refused) | The repo-server was still starting. Apply a **hard refresh**: `kubectl patch application memory-app -n argocd --type merge -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'` |
| Grafana CrashLoopBackOff "Only one datasource ... default" | Loki datasource was also marked default. Ensured `loki.isDefault: false` in `observability/loki-promtail-values.yaml`, then `helm upgrade --install loki grafana/loki-stack -n observability -f observability/loki-promtail-values.yaml` and delete the Grafana pod. |
| Grafana `3000:80` port-forward "no service port 80"    | The Grafana service listens on **3000**, not 80. Use `3000:3000`.                |
| Docker pull/build "docker-credential-desktop not found" | Remove `"credsStore": "desktop"` from `~/.docker/config.json`.                |
| `applicationsets.argoproj.io` CRD "Too long"           | Harmless — the installer tolerates it; the `Application` CRD still works.        |

---

## 5. Full teardown

```bash
# Delete GitOps-managed app resources + ArgoCD
kubectl delete application memory-app -n argocd
kubectl delete ns argocd memory-app-prod observability

# Delete the local cluster (removes everything)
kind delete cluster --name devops-sre
```
