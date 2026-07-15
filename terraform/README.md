# Terraform — AV Tools Magnum cluster

> Don't start here. Start with [`../START-HERE.md`](../START-HERE.md) →
> `./scripts/start-here.sh`. It does the setup and checks below for you.

Provisions the Kubernetes-on-OpenStack (Magnum) cluster in the **`av-tools`**
OpenStack project: **1 master + 3 workers** (`m2.medium`), `cluster-autoscaler`
min 3 / max 4. State lives in **GitLab-managed Terraform state** (no extra infra).

## The three constraints you cannot design around

**Auth must be Kerberos, not an application credential.** Magnum creates a
Keystone trust so the cluster can call OpenStack back; trust creation from an app
credential fails at CERN even when `unrestricted = True`. You get a clean plan and
then `CREATE_FAILED: Failed to create trustee or trust` ~30s into apply. Terraform's
provider can't speak Kerberos, so `scripts/os-auth.sh` bridges Kerberos → scoped
token → Terraform. This also means **CI cannot apply** (see below).

**Quota is cores.** 10 instances / **10 cores** / 20 GB. `m2.medium` = 2 cores →
**5 instances max**, master included. `autoscale_max` has a `validation` block
enforcing this; if you move to a bigger flavor, update that rule too.

**Templates get retired**, not just superseded — `kubernetes-1.33.3-1` was gone
within months of being written here. `openstack coe cluster template list` before
every apply. Use a plain template; `-argo` variants set `cern_chart_enabled:
false` and expect CERN's newer Argo addon delivery, not the cern_chart this repo
relies on for the autoscaler and `logging_producer` fluentd.

## Manual run

`start-here.sh` is the supported path — it holds the nine `-backend-config` flags
for the GitLab state backend. To init by hand, copy them out of that script.

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

## Notes

- `merge_labels = true` keeps the template's labels and layers ours on top.
  `min/max_node_count` are derived in `main.tf` from `autoscale_min/max`, so the
  labels can't drift from the variables.
- `terraform.tfvars` is gitignored (machine-specific); `start-here.sh` seeds it
  from `terraform.tfvars.example`.
- Keypairs belong to your **user**, not the project, and Terraform references
  them **by name** — the keypair must exist before apply. If the private half is
  lost, the entry is dead weight: delete and recreate it.
- Deleting the cluster may leave load balancers / volumes behind — clean up per
  the CERN Kubernetes docs.
