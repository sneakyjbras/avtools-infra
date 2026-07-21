# Cluster rebuild — `scripts/bootstrap.sh`

The Magnum cluster is **disposable**: everything on it is either in git (GitOps via
ArgoCD) or in Teigi/tbag (secrets), so it can be destroyed and rebuilt from
scratch. `scripts/bootstrap.sh` orchestrates that rebuild — it does **not** reinvent
anything: it chains `run_checks()` (preflight), `os-auth.sh` (Kerberos→token),
Terraform (the cluster), the `argocd/` manifests, and `sync-secret.sh` (tbag→Secret).

Prod is unaffected by a rebuild — production runs on the **Puppet monolith**, not on
k8s. Only the QA k8s monitoring blips while the cluster is down (~15–25 min).

---

## ⚠️ The rebuild is TWO-HOST

The rebuild needs two things that live on **different hosts**, and (in the CERN
setup) **no single host has both**:

| Need | Lives on | Why |
| --- | --- | --- |
| **Terraform + OpenStack auth** | your **workstation / lxplus** | terraform is installed there, plus the `requests-kerberos` / `gssapi` / `krb5` python libs that `os-auth.sh` uses to mint an `OS_TOKEN` |
| **tbag secrets** | **aiadm** (an `itdcim/avtools` host) | tbag/Teigi is hostgroup-scoped — your workstation isn't a member; aiadm is, but has no terraform and lacks the kerberos python libs |

So `./scripts/bootstrap.sh` as a single command only works on a host that has
**both** terraform and tbag. If yours doesn't (the usual case), run the **two-host
procedure** below. `./scripts/bootstrap.sh --check` prints which pieces the current
host is missing.

---

## Node names

Every node is labelled `wow=<name>` (World of Warcraft theme; workers alphabetical).
**Labels are lost on every rebuild** and must be reapplied. View with
`kubectl get nodes -L wow`.

| Magnum node name | `wow=` label | Role |
| --- | --- | --- |
| `…-master-0` | **medivh** | control plane |
| `…-node-0` | **arthas** | worker |
| `…-node-1` | **bolvar** | worker |
| `…-node-2` | **cairne** | worker |
| `…-node-3` | **draka** | worker |

Extend alphabetically as workers are added: `draka, eitrigg, grommash, jaina, khadgar…`.

---

## Prerequisites (what you need)

1. **Kerberos ticket** — `kinit <you>@CERN.CH`.
2. **tfvars target** — `terraform/terraform.tfvars` is **gitignored**, so a fresh
   clone has none. Set it to the rebuild target (the `--check` / preflight verifies it):

   ```hcl
   cluster_name  = "avtools-k8s"
   master_flavor = "m2.large"   # non-negotiable — control plane starves on m2.medium
   flavor        = "m2.large"   # worker flavor. Changing it REPLACES the whole cluster.
   node_count    = 4
   autoscale_min = 4
   autoscale_max = 4            # 4 (master) + 4*4 (workers) = 20 cores = the exact quota
   ```

3. **`scripts/env.sh`** filled in (`CERN_USER`, `GITLAB_ACCESS_TOKEN`, `PROJECT_ID`) —
   `cp scripts/env.example.sh scripts/env.sh` and edit.
4. **The 3 tbag keys** stored once (below).

---

## One-time tbag token storage

All three Secrets are pulled from tbag (hostgroup `itdcim/avtools`) at rebuild time —
nothing is pasted into a manifest. The app-secret keys already exist (they mirror
`code/manifests/avtools.pp`; `sync-secret.sh` reads them). The **two deploy tokens
are new** and must be stored **once**, on an `itdcim/avtools` host (aiadm):

```bash
# tbag `set` PROMPTS for the value (hidden) — no value argument, no pipe, no --stdin.
tbag set --hg itdcim/avtools harbor_robot_token   # Harbor robot token (robot-avtools+avtools-ci)
tbag set --hg itdcim/avtools argocd_repo_user     # GitLab deploy-token USERNAME (scope: read_repository)
tbag set --hg itdcim/avtools argocd_repo_token    # GitLab deploy-token VALUE

# verify all three landed:
for k in harbor_robot_token argocd_repo_user argocd_repo_token; do
  tbag show "$k" --hg itdcim/avtools --plain >/dev/null 2>&1 && echo "  $k ✓" || echo "  $k ✗"
done
```

Where to get the values: **Harbor token** → registry.cern.ch → `avtools` project →
Robot Accounts → `robot-avtools+avtools-ci` (regenerate if lost). **Deploy token** →
gitlab.cern.ch → `itdcim/av-tools-infra` → Settings → Repository → Deploy tokens →
create one with scope `read_repository` (gives a username + token).

**Fallback.** If a tbag key is absent (e.g. you are not on an `itdcim/avtools` host),
the script warns and falls back to environment variables:

| Secret | tbag key (hg itdcim/avtools) | env-var fallback |
| --- | --- | --- |
| Harbor robot token | `harbor_robot_token` | `HARBOR_ROBOT_TOKEN` |
| ArgoCD repo user | `argocd_repo_user` | `ARGOCD_REPO_USER` |
| ArgoCD repo token | `argocd_repo_token` | `ARGOCD_REPO_TOKEN` |
| App secrets (DB, MONIT, LanDB…) | see `scripts/sync-secret.sh` | (required; no fallback) |

The two deploy tokens are non-fatal if missing (warn + continue; ArgoCD repo fetch /
image pull fail until provided). The app secrets are required — `sync-secret.sh`
refuses to write an incomplete Secret.

---

## How to run

### Single-host (host has BOTH terraform and tbag)

```bash
kinit
./scripts/bootstrap.sh --check     # orient — read-only, changes nothing
./scripts/bootstrap.sh             # rebuild end-to-end; type REBUILD when asked
```

### Two-host (the usual case) — terraform on the workstation, secrets on aiadm

**A. Workstation — build the cluster + install ArgoCD + label nodes**

```bash
cd av-tools-infra
# set terraform/terraform.tfvars to the target (see Prerequisites), then:
source scripts/os-auth.sh
cd terraform && terraform apply          # destroys old, builds new 4x m2.large (~15-25 min)

# fresh kubeconfig
mkdir -p .kube && openstack coe cluster config avtools-k8s --dir .kube --force
export KUBECONFIG="$PWD/.kube/config"
kubectl get nodes                        # 1 master + 4 workers, all Ready

cd ..
kubectl create namespace argocd
kubectl create namespace avtools-qa
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# reapply the wow= node labels (lost on rebuild) — sort by Magnum node name
S=$(kubectl get nodes -o name | grep master | sed 's#node/##;s/-master-0//')
kubectl label node ${S}-master-0 wow=medivh --overwrite
kubectl label node ${S}-node-0   wow=arthas --overwrite
kubectl label node ${S}-node-1   wow=bolvar --overwrite
kubectl label node ${S}-node-2   wow=cairne --overwrite
kubectl label node ${S}-node-3   wow=draka  --overwrite
```

**B. aiadm — create the 3 Secrets from tbag**

```bash
cd /tmp/avtools-infra                     # a clone of this repo on aiadm
export OS_PROJECT_NAME=av-tools           # aiadm defaults to a different project → 404 without this
mkdir -p /tmp/kube
openstack coe cluster config avtools-k8s --dir /tmp/kube --force
export KUBECONFIG=/tmp/kube/config        # PIN THIS. Creating secrets in a shell WITHOUT it
kubectl get nodes                         #   silently no-ops against the wrong/no cluster.

# 1. app secrets  → secret/avtools-secrets in avtools-qa
AVTOOLS_ENVIRONMENT=qa ./scripts/sync-secret.sh

# 2. Harbor pull secret → avtools-qa
kubectl create secret docker-registry harbor-avtools -n avtools-qa \
  --docker-server=registry.cern.ch \
  --docker-username='robot-avtools+avtools-ci' \
  --docker-password="$(tbag show harbor_robot_token --hg itdcim/avtools --plain)"

# 3. ArgoCD repo deploy token → argocd
kubectl create secret generic repo-av-tools-infra -n argocd \
  --from-literal=type=git \
  --from-literal=url=https://gitlab.cern.ch/itdcim/av-tools-infra.git \
  --from-literal=username="$(tbag show argocd_repo_user --hg itdcim/avtools --plain)" \
  --from-literal=password="$(tbag show argocd_repo_token --hg itdcim/avtools --plain)"
kubectl label secret repo-av-tools-infra -n argocd argocd.argoproj.io/secret-type=repository
```

**C. Workstation — deploy the app (GitOps)**

```bash
kubectl apply -n argocd --server-side --force-conflicts -f argocd/app-of-apps.yaml
kubectl -n argocd annotate application avtools-root argocd.argoproj.io/refresh=hard --overwrite
kubectl get applications -n argocd        # avtools-qa → Synced / Healthy
# smoke test:
kubectl -n avtools-qa create job --from=cronjob/avtools-snmp-timeseries smoke
kubectl get pods -n avtools-qa -l job-name=smoke -o wide   # 8 shards spread ~2/node, status=ok
kubectl -n avtools-qa delete job smoke
```

### The secret sync — `sync-secret.sh`

`sync-secret.sh` is the single bridge for the **app** secrets: it reads them from
tbag (hg `itdcim/avtools`, the SAME keys `avtools.pp` uses) and writes
`secret/avtools-secrets` into the environment namespace (`avtools-qa` for
`AVTOOLS_ENVIRONMENT=qa`). tbag stays the source of truth — **rotate a secret by
updating tbag and re-running the script**; values never touch git or stdout. It needs
`tbag` + `kubectl` (so it runs on aiadm), not terraform or os-auth.

---

## Flags

| Flag | Effect |
| --- | --- |
| `--check` | Read-only preflight/orientation — run the checks, change nothing, exit non-zero if any fails. The old `start-here.sh` behaviour. |
| `--yes` / `-y` | Skip the typed `REBUILD` confirmation. |
| `--skip-terraform` | Leave the cluster untouched; only (re)bootstrap ArgoCD + secrets + labels on the EXISTING cluster. Skips the tfvars check and the confirmation. Handy on a host that has tbag but no terraform. |
| `--help` / `-h` | Usage. |

---

## What it does, in order

1. **Preflight** — `run_checks()`: tools (incl. kubectl/tbag), `env.sh`, Kerberos,
   Keystone/project, template exists, cores quota, keypair, cluster status, tfvars target.
2. **Confirm** — type `REBUILD` (skipped with `--yes` or `--skip-terraform`).
3. **OpenStack auth** — `source scripts/os-auth.sh` (Kerberos → `OS_TOKEN`).
4. **Terraform apply** — the topology change replaces the cluster (~15–25 min).
5. **Kubeconfig** — `openstack coe cluster config` into `.kube/` (gitignored), exports `KUBECONFIG`.
6. **ArgoCD core** — `kubectl apply -n argocd --server-side --force-conflicts` the
   upstream install manifest. **Server-side is required**: the ApplicationSet CRD
   exceeds the 262 KiB client-side last-applied annotation limit.
7. **Secrets (3, from tbag)** — ArgoCD repo credential (ns `argocd`), app secrets via
   `sync-secret.sh` (ns `avtools-qa`), Harbor pull secret (ns `avtools-qa`).
8. **GitOps** — apply `argocd/app-of-apps.yaml` **after** the secrets exist, so the
   first sync finds repo creds + pull secret + app secret in place. ArgoCD reconciles
   the AppProject and the ApplicationSet (**qa only** — prod is intentionally disabled).
9. **Node labels** — reapply the `wow=` scheme (see the table above).
10. **Wait + verify** — poll until `avtools-qa` is Synced/Healthy and the
    `avtools-snmp-timeseries` CronJob exists; print a status summary.

---

## Gotchas (learned during the 2026-07-21 rebuild)

- **aiadm project**: `export OS_PROJECT_NAME=av-tools` before any `openstack` call, or
  you get `Cluster avtools-k8s could not be found (HTTP 404)`.
- **aiadm kubeconfig dir**: `mkdir -p /tmp/kube` before `--dir /tmp/kube`, or
  `openstack coe cluster config` errors with `No such file or directory`.
- **Pin `KUBECONFIG` before `kubectl create secret` on aiadm.** A shell without it
  creates the Secret nowhere useful and the step silently "succeeds" — the classic
  symptom is `avtools-secrets` present (sync-secret set the ns) but `harbor-avtools`
  and `repo-av-tools-infra` missing.
- **Node labels don't survive a rebuild** — reapply them (step 9 / the label block).
- **`tbag set` is interactive** — `tbag set --hg itdcim/avtools <key>` then type the
  value at the prompt. No `--stdin`, no value argument.
