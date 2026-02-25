# ArgoCD Deployment

Quick deployment guide for ArgoCD with SSO, persistent storage, and HA.

## Prerequisites

- Kubernetes cluster (v1.33+)
- Helm
- Vertical Pod Autoscaler (VPA) installed

## Deployment Steps

### 1. Create Namespace

```bash
kubectl create namespace argocd
```

### 2. Create Secrets

```bash
cp argocd-secret.example.yaml argocd-secret.yaml
```

Populate `argocd-secret.yaml` with your actual secret values, then run:

```bash
kubectl apply -f argocd-secret.yaml -n argocd
```

### 3. Create PVCs

```bash
kubectl apply -f argocd-repo-server-pvcs.yaml
```

Verify:

```bash
kubectl get pvc -n argocd
```

### 4. Install ArgoCD

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --values values.yaml
```

### 5. Verify

```bash
kubectl get pods -n argocd
kubectl get ingress -n argocd
```

## Grafana Dashboards

Import these dashboard IDs in Grafana:

- **19993**: Operational Overview
- **19974**: Application Overview
- **19975**: Notifications Overview

You can do that by applying the Resource manifest:

```bash
kubectl apply -f argocd-grafana-dashboards.yaml -n grafana
```

Datasource: **Victoria Metrics Cluster**

## Troubleshooting

### Check SSO Status

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server | grep "sso:"
```

6. Connect remote cluster. Refer to: https://medium.com/pickme-engineering-blog/how-to-connect-an-external-kubernetes-cluster-to-argo-cd-using-bearer-token-authentication-d9ab093f081d
