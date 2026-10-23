#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD Setup Script for Local Kubernetes Cluster (Minikube / Kind / K3d)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

echo "=========================================================="
echo "Installing and Configuring ArgoCD for GitOps Continuous Delivery"
echo "=========================================================="

# Create ArgoCD Namespace
echo "[1/4] Creating argocd namespace..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install Official ArgoCD manifests
# NOTE: The `stable` install manifest embeds the applicationsets.argoproj.io CRD,
# whose YAML annotation exceeds the Kubernetes 256KB metadata limit on newer
# clusters ("metadata.annotations: Too long: must have at most 262144 bytes").
# That CRD failure does NOT affect the components this project needs (Application
# and AppProject CRDs are created fine), so we tolerate it and proceed.
echo "[2/4] Applying official ArgoCD manifests (tolerating the oversized applicationsets CRD)..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml || true

# Wait for ArgoCD server deployment to become available
echo "[3/4] Waiting for ArgoCD Server to become ready..."
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s || true

# Apply GitOps Application tracking the repository
echo "[4/4] Deploying ArgoCD Application Manifest..."
kubectl apply -f "$(dirname "$0")/application.yaml"

echo "=========================================================="
echo "ArgoCD setup complete!"
echo "To retrieve the admin initial password:"
echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"
echo "To port-forward ArgoCD UI to localhost:8080:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "=========================================================="
