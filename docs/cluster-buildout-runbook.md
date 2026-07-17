# Cluster buildout — runbook & post-mortem

How the AV Tools Magnum cluster was stood up, every failure hit on the way, the
root cause of each, and a debug playbook for when a build fails again. Written
2026-07-17 after a multi-day buildout so the next person (or future us) does not
repeat it.

For the *quick* path, see [`../START-HERE.md`](../START-HERE.md). This file is the
**why** and the **when-it-breaks**.

---

## TL;DR — the three fixes that took days to find

1. **Authenticate with Kerberos, not an application credential.** Magnum creates
   a Keystone *trust*; app credentials can't, even `unrestricted`. Use `kinit` +
   `scripts/os-auth.sh`.
2. **The master must be `m2.large`, not the template default `m2.medium`.** The
   small master starves under CERN's addon install and the build fails.
3. **Cluster templates get retired.** Check `openstack coe cluster template list`
   before every apply; pin a current one in `terraform.tfvars`.

All three are now defaults/guards in `variables.tf` and checks in
`scripts/start-here.sh`. This doc explains them.

---

## What we built

- **Project:** `av-tools` (OpenStack, note the hyphen).
- **Cluster:** `avtools-k8s`, Magnum, template `kubernetes-1.35.3-2` (k8s v1.35.3).
- **Topology:** 1 master `m2.large` (4 vCPU / 7.5 GB) + 3 workers `m2.medium`
  (2 vCPU / 3.75 GB). = 10 cores / 18.75 GB — the 10-core quota, exactly.
- **Auth:** Kerberos → scoped token → Terraform (`scripts/os-auth.sh`).
- **State:** GitLab-managed Terraform state (project ID 239202).

---

## Post-mortem: the failures, in order

### 1. `CREATE_FAILED: Failed to create trustee or trust for Cluster` (~30s in)

**Cause.** Terraform authenticated with an OpenStack *application credential*.
Magnum must create a Keystone trust so the cluster can call OpenStack back (load
balancers, volumes, autoscaler). Keystone forbids trust creation from an app
credential — **including when `unrestricted = True`**, despite what the Keystone
docs imply. We verified this the hard way: recreated the credential unrestricted,
same failure.

**Fix.** Create the cluster as *yourself* via Kerberos — the same identity
`ai-rc` uses on aiadm. Terraform's OpenStack provider can't speak Kerberos
(gophercloud has no `v3fedkerb`), so `scripts/os-auth.sh` bridges it: `kinit`
→ `openstack token issue` → `OS_TOKEN` → Terraform. Requires three Arch packages
that are easy to miss: `python-requests-kerberos`, `python-gssapi`, **and**
`python-krb5` (the first two don't pull in the third; symptom is a late
`No module named 'krb5'`).

**Consequence.** CI's `tf_apply` job uses app credentials, so **CI cannot create
the cluster**. `terraform plan` in CI is fine (read-only). Cluster creation is a
human-with-Kerberos operation until someone gets a service account allowed to
create trusts.

### 2. Two `CREATE_FAILED: default-master failed, default-worker failed` (~45m in)

This is the one that cost days, because the surface signals were all misleading:

- All four VMs showed **`ACTIVE`** in Horizon — looked like it worked.
- `openstack coe cluster show` `faults` was **empty `{}`** — no resource error.
- The first failed master happened to also log `erofs` disk-read errors — a
  **red herring** (the second failed master's disk was clean, same failure).
- `heat-container-agent` logged `RemoteDisconnected` from `kops-cern-heat.cern.ch`
  — also a **red herring** (that's the agent still polling long after; the real
  failure was earlier).

**What actually happened.** Core Kubernetes came up fine (nodes `Ready`, Cilium +
CoreDNS running), but the **CERN addon layer never converged**. CERN installs
~15 heavy addons on the master at boot via one Helm job — Falco, Prometheus,
Velero, cert-manager, Cilium, four CSI drivers, the autoscaler, node-feature-
discovery, fluentd, snapshot-controller. On an `m2.medium` master (3.75 GB) the
control plane **starves**:

- **114 MiB free RAM**, **load 5.2 on 2 cores** (measured on the failed master).
- API server slows → addon liveness/readiness probes time out
  (`context deadline exceeded`) → pods get liveness-killed → restart → burn more
  resources → worse. A death spiral.
- `install-cern-magnum-job` (helm `--wait --timeout 45m`) never sees everything
  healthy → errors (`the server was unable to return a response in the time
  allotted`) → creation health-check fails → `CREATE_FAILED`.

**Fix.** `master_flavor = "m2.large"` (4 vCPU / 7.5 GB). Doubles CPU and RAM;
gives the control plane headroom. First build on it reached `CREATE_COMPLETE`;
`install-cern-magnum-job` completed in **3m42s**; the autoscaler settled after 4
restarts (it was at 63+ and climbing on m2.medium).

### Smaller things that also bit

- **Template retired.** `kubernetes-1.33.3-1` (in the repo) had vanished; the data
  source failed. Templates rotate — list first. Avoid `-argo` variants
  (`cern_chart_enabled: false`; they expect CERN's newer addon delivery).
- **Quota is CORES, not instances.** 10 instances but only 10 cores. `m2.large`
  master (4) + 3× `m2.medium` (6) = 10, exact. No room to autoscale past 3.
- **CI Terraform too old** (`>= 1.6` vs image's 1.5.7) and **gitignored tfvars**
  meant `keypair` had no value in CI. Both fixed (relaxed constraint; defaulted
  keypair).

---

## Debug playbook: a cluster build failed — now what

`status_reason` is almost always the useless generic `default-master failed,
default-worker failed`. The real cause is one layer down. Work top-to-bottom:

**1. Is it the trust (fails ~30s in)?**
```bash
openstack coe cluster show <name> -f value -c status_reason
```
If it mentions `trust`/`trustee` → you're on an app credential. `source
scripts/os-auth.sh` (Kerberos) and rebuild.

**2. Does `faults` name a resource error (fails fast, quota/AZ/flavor)?**
```bash
openstack coe cluster show <name> --fit | sed -n '/faults/,/^|/p'
```
Populated `faults` = a real Heat resource failure (quota, bad AZ, missing
flavor). Read it literally.

**3. Empty `faults`, VMs `ACTIVE`, fails ~45m in? → addon layer. SSH in.**
Serial console is NOT enough — the addon failures are in-container. Get onto the
master (from a CERN-networked host / aiadm):
```bash
ssh -J <you>@aiadm.cern.ch -i ~/.ssh/jbras_avtools_k8s core@<master-ip>
```
Then, the three commands that actually diagnose it:
```bash
K=/etc/kubernetes/admin.conf
sudo kubectl --kubeconfig $K get pods -A | grep -vE "Running|Completed"  # what's dying
uptime; free -h; nproc                                                    # is it starved?
sudo kubectl --kubeconfig $K get events -A --sort-by=.lastTimestamp | tail -30
```
- Low free RAM / high load / `context deadline exceeded` probe events →
  **control-plane starvation** → bigger `master_flavor`.
- Resources fine but Cilium/etcd unhealthy → CNI/networking → **CERN ticket**,
  with these logs attached.

**Do NOT** trust `openstack coe cluster list` alone — a healthy-looking `ACTIVE`
VM set can sit under a `CREATE_FAILED` cluster whose addons are crash-looping.
Equally, `CREATE_COMPLETE` is trustworthy (Magnum only reports it once the addon
install job succeeds) but confirm with `kubectl get pods -A | grep -v Running`.

---

## Recovery: tear down a failed cluster and rebuild

A `CREATE_FAILED` cluster **cannot be refreshed** — the provider errors reading a
kubeconfig that never existed, so even `terraform plan` breaks. Remove it from
both OpenStack and state, then rebuild:

```bash
source scripts/os-auth.sh
openstack coe cluster delete avtools-k8s
# wait until: openstack coe cluster show avtools-k8s  -> "could not be found"
cd terraform
terraform state rm openstack_containerinfra_cluster_v1.avtools
terraform apply          # ~45 min; watch the FIRST minute for the trust error
```

A failed cluster holds its full quota until deleted — you cannot build the
replacement alongside it under a 10-core quota.

---

## Known-good configuration (reference)

```hcl
# terraform/terraform.tfvars  (gitignored; defaults live in variables.tf)
cluster_name     = "avtools-k8s"
cluster_template = "kubernetes-1.35.3-2"   # verify it still exists
keypair          = "avtools-k8s"
master_count     = 1
node_count       = 3
master_flavor    = "m2.large"              # NON-NEGOTIABLE — see post-mortem
autoscale_min    = 3
autoscale_max    = 3                       # 10-core quota is fully used
```

Auth every session: `kinit <you>@CERN.CH` then `source scripts/os-auth.sh`.
Verify a finished build: `kubectl get pods -A | grep -vE "Running|Completed"`
(header-only = healthy).
