# Terraform — AV Tools Magnum cluster

> Don't start here. Start with [`../START-HERE.md`](../START-HERE.md) →
> `./scripts/bootstrap.sh --check`. It does the checks below for you (and
> `./scripts/bootstrap.sh` runs the whole apply end-to-end).

Provisions the Kubernetes-on-OpenStack (Magnum) cluster in the **`av-tools`**
OpenStack project: **1 master + 4 workers** (all `m2.large`), `cluster-autoscaler`
min 4 / max 4. State lives in **GitLab-managed Terraform state** (no extra infra).

## The three constraints you cannot design around

**Auth must be Kerberos, not an application credential.** Magnum creates a
Keystone trust so the cluster can call OpenStack back; trust creation from an app
credential fails at CERN even when `unrestricted = True`. You get a clean plan and
then `CREATE_FAILED: Failed to create trustee or trust` ~30s into apply. Terraform's
provider can't speak Kerberos, so `scripts/os-auth.sh` bridges Kerberos → scoped
token → Terraform. This also means **CI cannot apply** (see below).

**Quota is cores.** As of 2026-07 the quota is 20 instances / **20 cores** / 40 GB
(was 10 cores). The cluster is **1 master + 4 workers, all `m2.large`** (4 cores
each): 4 + 4×4 = **20 cores, exact** — the quota is fully used, no room to
autoscale past 4. `autoscale_max` has a `validation` block enforcing this
(`4 + max*4 <= 20`); if you change a flavor, update that rule too.

**Templates get retired**, not just superseded — `kubernetes-1.33.3-1` was gone
within months of being written here. `openstack coe cluster template list` before
every apply. Use a plain template; `-argo` variants set `cern_chart_enabled:
false` and expect CERN's newer Argo addon delivery, not the cern_chart this repo
relies on for the autoscaler and `logging_producer` fluentd.

## Manual run

`./scripts/bootstrap.sh` is the supported path — it holds the nine `-backend-config`
flags for the GitLab state backend. To init by hand, copy them out of that script.

```bash
kinit <your-cern-username>@CERN.CH
source scripts/os-auth.sh                          # Kerberos -> OS_TOKEN
cd terraform
terraform plan
terraform apply                                    # 10-20 min, silent
eval $(openstack coe cluster config avtools-k8s)   # kubeconfig
kubectl get nodes
```

Tickets and tokens expire. On a 401, re-`kinit` and re-source `os-auth.sh`.

## Recovering from CREATE_FAILED

A failed cluster **cannot be refreshed** — the provider errors reading a
kubeconfig that was never created, so even `terraform plan` breaks. Remove it from
both places:

```bash
openstack coe cluster delete avtools-k8s
terraform state rm openstack_containerinfra_cluster_v1.avtools
terraform apply
```

`status_reason` carries the real cause; `faults` is usually an empty `{}`:

```bash
openstack coe cluster show avtools-k8s -f value -c status_reason
```

## CI: plan yes, apply no

The `gitlab-terraform` wrapper (image
`registry.gitlab.com/gitlab-org/terraform-images/stable`) injects the
managed-state address and credentials automatically; the OpenStack
application-credential values are **masked** CI variables. A merge request runs
`terraform plan`, which is fine — it's read-only.

**The manual `tf_apply` job on `master` cannot create the cluster**: CI
authenticates with an application credential, which cannot create the Magnum
trust. Cluster creation is a human-with-Kerberos operation today. Automating it
would need a service account permitted to create trusts — ask the CERN cloud team
rather than guessing.

## Rescaling workers (m2.medium → m2.large)

The 2026-07 rescale changes the worker `flavor` from the template default
(`m2.medium`, 3.75 GB) to `m2.large` (7.5 GB) and grows `node_count` 3 → 4. On
`terraform apply` Magnum performs a **rolling node replacement**: changing a
node-group flavor is destructive per node — each worker is drained, deleted, and
recreated on the new flavor one at a time (the master is untouched). Expect:

- The apply to take a while (each node is a full VM create; see the 60m timeout).
- Pods to reschedule as nodes cycle. The CronJobs are AP-model and idempotent
  (`concurrencyPolicy: Forbid`, a missed tick converges on the next), so a sweep
  landing mid-roll simply retries — no data loss, at most one jittered cycle.
- Transient capacity crunch: a new m2.large (4 cores) can only be created once
  the quota allows it. At 20 cores the old 10-core footprint has room, but if a
  replacement ever stalls on quota, let the old node delete first.

Verify after: `kubectl get nodes -o wide` shows 4 workers, and
`openstack server list` shows them all on `m2.large`.

## Notes

- `merge_labels = true` keeps the template's labels and layers ours on top.
  `min/max_node_count` are derived in `main.tf` from `autoscale_min/max`, so the
  labels can't drift from the variables.
- `terraform.tfvars` is gitignored (machine-specific); copy it yourself from
  `terraform.tfvars.example` and set the rebuild target. `bootstrap.sh --check`
  verifies it exists and matches the target (it does not seed it).
- Keypairs belong to your **user**, not the project, and Terraform references
  them **by name** — the keypair must exist before apply. If the private half is
  lost, the entry is dead weight: delete and recreate it.
- Deleting the cluster may leave load balancers / volumes behind — clean up per
  the CERN Kubernetes docs.
