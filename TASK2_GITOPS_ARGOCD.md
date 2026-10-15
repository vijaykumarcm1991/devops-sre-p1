# Task 2: GitOps Deployment with ArgoCD — Detailed Guide

## 1. Overview & Architecture

Task 2 implements an automated GitOps deployment model using ArgoCD. All Kubernetes manifests reside in version-controlled declarative files under `k8s/`. When changes are committed to Git, ArgoCD automatically reconciles and syncs the live cluster state with the desired state.

```
+-----------------------------------------------------------------------------------+
|                              Git Repository (GitHub)                              |
|                                                                                   |
|  k8s/deployments.yaml  |  k8s/service.yaml  |  k8s/rbac.yaml  |  k8s/networkpolicy|
+------------------------------------------+----------------------------------------+
                                           |
                                  Sync & Reconcile
                                           |
                                           v
+-----------------------------------------------------------------------------------+
|                             ArgoCD Application Controller                         |
+------------------------------------------+----------------------------------------+
                                           |
                                      Deploys to
                                           |
                                           v
+-----------------------------------------------------------------------------------+
|                        Kubernetes Cluster (memory-app-prod)                       |
|                                                                                   |
|   +---------------------------------------------------------------------------+   |
|   |                  Shared Service: memory-app-service (Port 80)             |   |
|   +-------------------+-------------------+-------------------+---------------+   |
|                       |                   |                   |                   |
|                       v                   v                   v                   |
|               +---------------+   +---------------+   +---------------+           |
|               | memory-app-v1 |   | memory-app-v2 |   | memory-app-v3 |           |
|               |  (Image v1.0) |   |  (Image v1.1) |   |  (Image v1.2) |           |
|               | Limit: 400Mi  |   | Limit: 400Mi  |   | Limit: 400Mi  |           |
|               |  (OOMKilled)  |   |  (OOMKilled)  |   |  (OOMKilled)  |           |
|               +---------------+   +---------------+   +---------------+           |
+-----------------------------------------------------------------------------------+
```

---

## 2. Multi-Version Deployments & Shared Service

Per the assessment requirements, the pipeline produces three distinct image versions (`v1.0.0`, `v1.1.0`, `v1.2.0`). All three run concurrently in the cluster.

### Deployments (`k8s/deployments.yaml`)
1. `memory-app-v1`: Runs `ghcr.io/vijaykumarcm1991/memory-app:v1.0.0`
2. `memory-app-v2`: Runs `ghcr.io/vijaykumarcm1991/memory-app:v1.1.0`
3. `memory-app-v3`: Runs `ghcr.io/vijaykumarcm1991/memory-app:v1.2.0`

### Shared Load Balancer Service (`k8s/service.yaml`)
- A single `ClusterIP` (or `LoadBalancer`) service named `memory-app-service`.
- Selector: `app: memory-app`.
- Because all three deployments share the common label `app: memory-app`, kube-proxy and CoreDNS distribute incoming traffic evenly across all pods across all versions.

---

## 3. Crucial Memory Limit & OOMKilled Engineering

The application code starts by allocating 100MB of memory and progressively allocates ~3.33MB/sec to reach 500MB within 120 seconds.

### Cgroup & Resource Limit Configuration:
```yaml
resources:
  requests:
    cpu: "100m"
    memory: "150Mi"
  limits:
    cpu: "500m"
    memory: "400Mi" # Crucial: triggers Linux OOM killer at 400Mi
```

### Why 400Mi?
- When the container approaches ~400Mi (around ~90 seconds into execution), the Linux kernel cgroup controller enforces the hard memory boundary.
- The kernel terminates the runaway container with exit code `137` and reason `OOMKilled`.
- Kubernetes detects the termination, records the `OOMKilled` status in `kube_pod_container_status_last_terminated_reason`, and restarts the pod in accordance with `restartPolicy: Always`.
- This strictly protects the underlying Kubernetes worker nodes from memory exhaustion, avoiding cascading node failures.

---

## 4. Enterprise Production-Grade Kubernetes Features

To deliver an enterprise-ready posture, the implementation includes:

1. **Dedicated Namespace (`k8s/namespace.yaml`):**
   - Namespace `memory-app-prod` with Pod Security Standards (`pod-security.kubernetes.io/enforce: restricted`).
2. **ConfigMaps & Secrets (`k8s/configmap-secret.yaml`):**
   - `memory-app-config`: Externalized runtime configurations (`APP_ENV`, `PORT`, `LOG_LEVEL`).
   - `memory-app-secret`: Sensitive credentials mounted safely as environment variables.
3. **initContainers:**
   - Pre-flight validation container running `busybox:1.36` before the main application starts.
   - Verifies network connectivity and runtime readiness before opening port 8080.
4. **RBAC (`k8s/rbac.yaml`):**
   - Dedicated `ServiceAccount` (`memory-app-sa`) with `automountServiceAccountToken: false`.
   - Explicit `Role` and `RoleBinding` adhering to the principle of least privilege.
5. **NetworkPolicies (`k8s/networkpolicy.yaml`):**
   - Ingress restricted only to port `8080` from within the cluster.
   - Egress restricted to DNS resolution (port 53 TCP/UDP), preventing unauthorized outbound lateral movement.
6. **ResourceQuotas & LimitRanges (`k8s/resourcequota-limitrange.yaml`):**
   - Namespace-wide hard caps on CPU, memory, and total pod count to prevent rogue resource consumption.
   - LimitRange setting container defaults (`cpu: 100m`, `memory: 150Mi`) and maximum boundaries.
7. **Security Context:**
   - `runAsNonRoot: true`, `runAsUser: 10001`, `runAsGroup: 10001`.
   - `readOnlyRootFilesystem: true`.
   - `capabilities: drop: ["ALL"]`.
   - `allowPrivilegeEscalation: false`.

---

## 5. ArgoCD Setup & Continuous Sync

### Manifest (`argocd/application.yaml`):
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: memory-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/vijaykumarcm1991/devops-sre-p1.git
    targetRevision: HEAD
    path: k8s
  destination:
    server: https://kubernetes.default.svc
    namespace: memory-app-prod
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### Installation Steps:
Run the provided installer script:
```bash
bash /home/ubuntu/DevOps-SRE/argocd/install-argocd.sh
```
Or execute manually:
```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl apply -f /home/ubuntu/DevOps-SRE/argocd/application.yaml
```
ArgoCD continuously monitors the git repository and reconciles the state within seconds of any push.
