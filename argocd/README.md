# ArgoCD bootstrap

ArgoCD is the one thing installed imperatively (once per cluster); everything
else is then GitOps.

## 1. Install ArgoCD

```bash
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deploy/argocd-server
```

(Or add ArgoCD itself as a Helm Application if you prefer a fully declarative
install — the `argo/argo-cd` chart.)

## 2. Give ArgoCD the source repo

The manifests reference `https://gitlab.cern.ch/itdcim/av-tools-infra.git`. If the repo
is private, register credentials (a deploy token / read-only PAT):

```bash
argocd repo add https://gitlab.cern.ch/itdcim/av-tools-infra.git \
  --username <deploy-token-user> --password <deploy-token>
```

## 3. Apply the root app

```bash
kubectl apply -n argocd -f argocd/app-of-apps.yaml
```

`avtools-root` then reconciles:

- `appproject.yaml` — the `avtools` AppProject
- `applicationset.yaml` — `avtools-qa` (tracks `master`, ns `avtools-qa`) and
  `avtools-prod` (tracks `prod`, ns `avtools-prod`)
- `kube-prometheus-stack.yaml` — cluster-health Prometheus in `monitoring`

## Promotion model (master mirrors QA)

- **QA** auto-syncs from `master`.
- **PROD** tracks the `prod` branch; a release = fast-forward `prod` to the
  tagged commit (mirrors the tags→PROD convention used for the Grafana dashboards).

## Note on the Secret

`avtools-secrets` is created out-of-band by `scripts/sync-secret.sh` (tbag bridge)
and is **not** managed by ArgoCD — `prune` will not remove it because the chart
never renders it.
