# Metrics Server

> Metrics Server collects resource metrics from Kubelets and exposes them in Kubernetes apiserver through Metrics API for use by Horizontal Pod Autoscaler and Vertical Pod Autoscaler. Metrics API can also be accessed by kubectl top, making it easier to debug autoscaling pipelines.

~ https://github.com/kubernetes-sigs/metrics-server?tab=readme-ov-file

## Installation

### Manual

Installation is done simply by running a Helm Chart provided by upstream. There are only minor changes compared to default `values.yaml` file.

```bash
helm dependency build
helm install metrics-server . -n kube-system --create-namespace
```

### ArgoCD

Deployment with ArgoCD uses ApplicationSet defined in [.argocd](../.argocd/metricsServerApplicationSet.yaml). It automatically deploys metrics-server to all registered clusters.

