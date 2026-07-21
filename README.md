# av-tools-infra

GitOps + infrastructure for **AV Tools** on CERN **Kubernetes-on-OpenStack (Magnum)**.

### → New here? [**START-HERE.md**](START-HERE.md), then `./scripts/bootstrap.sh --check`
### → Rebuild the cluster? `./scripts/bootstrap.sh` — see [**docs/deployment/bootstrap.md**](docs/deployment/bootstrap.md)
### → Build failing? [**docs/cluster-buildout-runbook.md**](docs/cluster-buildout-runbook.md) — post-mortem + debug playbook

Application code lives in [`itdcim/av-tools`](https://gitlab.cern.ch/itdcim/av-tools);
this repo only **deploys** the container image that av-tools builds and publishes to
`registry.cern.ch`. The contract between the two repos is the **image tag**.

```
terraform/   Magnum cluster (1 master + 3 workers, autoscale 3–4, GitLab-managed state)
chart/       Helm chart: 3 Indexed CronJobs + ConfigMap + (opt) Fluent Bit + freshness rule
argocd/      AppProject + ApplicationSet (qa/prod) + app-of-apps + kube-prometheus-stack
scripts/     bootstrap.sh    (the single front door: --check = read-only preflight;
                              no flag = rebuild the whole cluster end-to-end)
             start-here.sh   (backward-compat shim → bootstrap.sh --check)
             env.example.sh  (the 3 values you supply; copy to env.sh, gitignored)
             os-auth.sh      (Kerberos → scoped token for Terraform; and why)
             sync-secret.sh  (tbag → K8s Secret bridge; run from an itdcim/avtools host)
secrets/     secret.example.yaml (manual fallback; a filled secret.yaml is gitignored)
```

The OpenStack project is **`av-tools`** (with a hyphen).

## The app ⇄ infra boundary

| `av-tools` (application) | `av-tools-infra` (this repo) |
|---|---|
| builds & publishes `registry.cern.ch/avtools/avtools:{qa,prod}`; owns `src/`, `Dockerfile`, Grafana dashboards, Sentry SDK | provisions the cluster and **deploys** that image via GitOps |

Images use **moving env tags** (`:qa`, `:prod`) with `imagePullPolicy: Always`; since
the workload is CronJobs, each run pulls the current image — no image-tag write-back
into git, and no per-release infra commit.

## Deploy

0. **Orient** — `./scripts/bootstrap.sh --check` (see [`START-HERE.md`](START-HERE.md)).
   Read-only; it walks the chain and stops wherever you are.
1. **Whole thing, one command** — `./scripts/bootstrap.sh` rebuilds end-to-end
   (cluster → ArgoCD → secrets → labels); see
   [`docs/deployment/bootstrap.md`](docs/deployment/bootstrap.md). The individual
   layers are still documented below and in their own READMEs:
2. **Cluster** — see [`terraform/README.md`](terraform/README.md).
3. **Secrets** — `AVTOOLS_ENVIRONMENT=qa ./scripts/sync-secret.sh` from an
   `itdcim/avtools` host (the monolith during the overlap). Secrets stay in tbag; this
   only bridges them into a K8s Secret ArgoCD never manages.
4. **ArgoCD** — see [`argocd/README.md`](argocd/README.md): install ArgoCD, register this
   repo, then `kubectl apply -n argocd -f argocd/app-of-apps.yaml`.

> ⚠️ **Steps 2–3 are blocked**: `registry.cern.ch/avtools/avtools:{qa,prod}` does not
> exist yet. `av-tools` `master` has no Dockerfile and no image build job — the
> Dockerfile lives only on the unmerged `feature/k8s-magnum-buildout`. Deploying the
> chart today yields `ImagePullBackOff`. See [`START-HERE.md`](START-HERE.md).

## Promotion (master mirrors QA)

QA app tracks **`master`**; PROD app tracks **`prod`** (fast-forward `prod` to a release
tag). Mirrors the tags→PROD convention already used for the Grafana dashboards.

## Reuse for other services

This is per-service by design. When `timeseries-dip` needs the same, copy the pattern
into `timeseries-dip-infra` (its own Terraform/Helm/ArgoCD), swap the image + values.
