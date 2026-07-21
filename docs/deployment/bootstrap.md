# One-command cluster rebuild — `scripts/bootstrap.sh`

The Magnum cluster is **disposable**. `scripts/bootstrap.sh` rebuilds it end to
end so the whole thing becomes:

```bash
kinit <your-cern-username>@CERN.CH
./scripts/bootstrap.sh
```

It is the **single front door**. It **orchestrates the existing pieces** — its own
`run_checks()` preflight chain (tools, env.sh, Kerberos, Keystone/project, template,
quota, keypair, cluster), `os-auth.sh` (Kerberos→token), Terraform (the cluster),
`sync-secret.sh` (tbag→Secret), and the `argocd/` manifests. It does not reinvent
any of them. This is the automated form of the manual steps in
[`../cluster-buildout-runbook.md`](../cluster-buildout-runbook.md).

## Two modes

```bash
./scripts/bootstrap.sh --check   # read-only preflight/orientation; changes NOTHING;
                                 #   exits non-zero if a check fails (scriptable)
./scripts/bootstrap.sh           # rebuild the cluster end-to-end (DESTRUCTIVE)
```

`--check` is the orientation entry point — run it to see where the chain stands.
It is exactly the preflight the normal run gates on (same `run_checks()`), so the
two can never drift. `scripts/start-here.sh` is now a thin backward-compat shim
that `exec`s `bootstrap.sh --check`.

> **Destructive.** Applying the target topology forces a **full Magnum cluster
> replace** — the running cluster (avtools-qa) is destroyed and rebuilt. The
> script requires you to type `REBUILD` unless `--yes` is passed.

---

## Precondition you must set by hand

`terraform/terraform.tfvars` is **gitignored** — a fresh clone never has one, and
the script cannot guess your intent. Before running, set it to the rebuild target
(the script's step 1 verifies this and aborts otherwise):

```hcl
cluster_name  = "avtools-k8s"
master_flavor = "m2.large"   # non-negotiable — control-plane starves on m2.medium
flavor        = "m2.large"   # worker flavor; changing it REPLACES the cluster
node_count    = 4
autoscale_min = 4
autoscale_max = 4            # 4 + 4*4 = 20 cores, the exact quota
```

You also need `scripts/env.sh` filled in (CERN_USER, GITLAB_ACCESS_TOKEN,
PROJECT_ID) — `bootstrap.sh --check` verifies it (and `terraform.tfvars`; neither
is auto-seeded — a fresh clone must `cp` the `.example` and fill it in).

---

## One-time tbag token storage

All three secrets are pulled from Teigi/tbag (hostgroup `itdcim/avtools`) at run
time — nothing is pasted by hand. The app-secret keys already exist (they mirror
`code/manifests/avtools.pp`, see `scripts/sync-secret.sh`). The **two deploy
tokens are new** and must be stored in tbag **once** (run on an `itdcim/avtools`
host, values piped so they never land in shell history):

```bash
# 1. Harbor robot pull token (robot: robot-avtools+avtools-ci) — for the private image
printf %s 'ROBOT_TOKEN_HERE' | tbag set harbor_robot_token --hg itdcim/avtools --stdin

# 2. GitLab deploy token for ArgoCD to read this private repo (scope: read_repository)
printf %s 'DEPLOY_TOKEN_USER' | tbag set argocd_repo_user  --hg itdcim/avtools --stdin
printf %s 'DEPLOY_TOKEN_HERE' | tbag set argocd_repo_token --hg itdcim/avtools --stdin
```

(If your tbag build wants the value interactively, drop `--stdin` and paste when
prompted; confirm with `tbag show <key> --hg itdcim/avtools --plain`.)

**Fallback.** If a tbag key is absent (e.g. you are not on an `itdcim/avtools`
host), the script warns and falls back to environment variables:

| Secret                | tbag key (hg itdcim/avtools) | env-var fallback      |
| --------------------- | ---------------------------- | --------------------- |
| Harbor robot token    | `harbor_robot_token`         | `HARBOR_ROBOT_TOKEN`  |
| ArgoCD repo user      | `argocd_repo_user`           | `ARGOCD_REPO_USER`    |
| ArgoCD repo token     | `argocd_repo_token`          | `ARGOCD_REPO_TOKEN`   |
| App secrets (DB, …)   | see `scripts/sync-secret.sh` | (required; no fallback) |

The two deploy-token secrets are non-fatal if missing — the script warns and
continues (ArgoCD repo fetch / image pull will fail until you provide them). The
app secrets are required; `sync-secret.sh` refuses to write an incomplete Secret.

---

## Flags

| Flag               | Effect                                                                 |
| ------------------ | --------------------------------------------------------------------- |
| `--check`          | Read-only preflight/orientation — run the checks, change nothing, exit non-zero if any fails. The old `start-here.sh` behaviour.  |
| `--yes` / `-y`     | Skip the typed `REBUILD` confirmation.                                 |
| `--skip-terraform` | Leave the cluster untouched; only (re)bootstrap ArgoCD + secrets + labels on the EXISTING cluster. Skips the tfvars target check and the confirmation. |
| `--help` / `-h`    | Usage.                                                                 |

`--skip-terraform` makes the script a safe, idempotent re-bootstrap for an already
running cluster (re-apply ArgoCD, re-sync secrets, re-label nodes).

---

## What it does, in order

1. **Preflight** — runs `run_checks()`, the same read-only chain `--check` runs
   (tools incl. kubectl/tbag, env.sh, Kerberos, Keystone/project, template exists,
   cores quota, keypair, cluster status, and that tfvars matches the rebuild target).
2. **Confirm** — type `REBUILD` (skipped with `--yes` or `--skip-terraform`).
3. **OpenStack auth** — `source scripts/os-auth.sh` (Kerberos → `OS_TOKEN`).
4. **Terraform apply** — the topology change replaces the cluster (45–60 min).
5. **Kubeconfig** — `openstack coe cluster config` into `.kube/` (gitignored),
   exports `KUBECONFIG`.
6. **ArgoCD core** — `kubectl apply -n argocd --server-side --force-conflicts` the
   upstream install manifest. Server-side is **required**: the CRDs (incl. the
   ApplicationSet CRD) exceed the 262 KiB client-side last-applied annotation limit.
7. **Secrets (3, from tbag)** — ArgoCD repo credential (ns `argocd`), app secrets
   via `sync-secret.sh` (ns `avtools-qa`), Harbor pull secret (ns `avtools-qa`).
8. **GitOps** — apply `argocd/app-of-apps.yaml` (after the secrets exist, so the
   first sync already finds repo creds + pull secret + app secret in place).
   ArgoCD then reconciles the AppProject, the ApplicationSet (**qa only** — prod is
   intentionally disabled), and kube-prometheus-stack.
9. **Node labels** — reapply the `wow=` scheme lost on every rebuild: master →
   `medivh`; the four workers, sorted by their Magnum name (`…-node-0..3`) →
   `arthas`, `bolvar`, `cairne`, `draka`.
10. **Wait + verify** — poll until the `avtools-qa` ArgoCD app is Synced/Healthy
    and the `avtools-snmp-timeseries` CronJob exists; print a status summary.

> **Known blocker.** The chart pulls `registry.cern.ch/avtools/avtools:qa`. If the
> `av-tools` image does not exist yet, the CronJob pods `ImagePullBackOff` — that
> is the pre-existing blocker documented in [`../../START-HERE.md`](../../START-HERE.md),
> not a bootstrap failure.
