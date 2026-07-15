# Start here

```bash
kinit <your-cern-username>@CERN.CH
cp scripts/env.example.sh scripts/env.sh    # fill in 3 values
./scripts/start-here.sh
```

The script checks the whole chain, stops at the first thing that isn't ready, and
prints the exact command to fix it. Fix, re-run, repeat. When it says **CLUSTER IS
UP**, this layer is done.

You never need to read further to make it work. The rest is *why*, for when it
surprises you.

---

## Top down: what this is

Four layers. Each is useless without the one below it.

```
  4  ArgoCD + Helm    deploys the app image into the cluster   argocd/ chart/
  3  A container image  ← ⚠ DOES NOT EXIST YET (see below)     (av-tools repo)
  2  Kubernetes       the cluster, built by Terraform          terraform/
  1  OpenStack        CERN's cloud, project "av-tools"         your Kerberos ticket
```

The application itself lives in a **different repo**
([`itdcim/av-tools`](https://gitlab.cern.ch/itdcim/av-tools)). This repo only
deploys the image that one publishes. The contract between them is the image tag.

## Bottom up: the chain

Work upward. Nothing higher can work until everything below it does — which is why
the script refuses to skip ahead, and why "everything is broken" is almost always
"the bottom isn't there yet".

| # | What | Done when | Who |
|---|------|-----------|-----|
| 1 | Tools installed | `start-here.sh` step 1 passes | `pacman` (sudo) |
| 2 | Your 3 values | `scripts/env.sh` filled in | you, once |
| 3 | Kerberos ticket | `klist` shows `@CERN.CH` | `kinit`, daily |
| 4 | Cluster | `terraform apply` → CREATE_COMPLETE | 10–20 min |
| 5 | kubeconfig | `kubectl get nodes` works | one command |
| 6 | **Container image** | **← blocked, see below** | `av-tools` repo |
| 7 | Secrets | `scripts/sync-secret.sh` | from an itdcim/avtools host |
| 8 | ArgoCD | `argocd/README.md` | after 6 and 7 |

Steps 1–5 are done by `start-here.sh`. Step 6 is somebody's afternoon.

## ⚠ The blocker above the cluster

**There is no container image.** The chart pulls
`registry.cern.ch/itdcim/avtools:qa`, but:

- `av-tools` `master` has **no Dockerfile**
- its CI declares `docker_prepare` / `docker_build` / `docker_test` stages
  (inherited from the CERN template) with **no jobs in them**
- the Dockerfile exists only on the unmerged branch `feature/k8s-magnum-buildout`

AV Tools ships today as an **RPM onto a Puppet host**. It has never been a
container. So you can build the cluster all you like — deploying the chart now
just yields `ImagePullBackOff` on every CronJob.

**Fix that in `av-tools` before touching `argocd/` or `chart/`.**

## Summary: the five things that bite

All five are now enforced by `start-here.sh` rather than trusted to a reader.

1. **Application credentials CANNOT create the cluster.** This is the big one.
   Magnum needs a Keystone **trust**, and trust creation from an app credential
   fails at CERN — *including* with `unrestricted = True`, which the Keystone
   docs claim should allow it. Symptom: perfect plan, apply starts, then
   `CREATE_FAILED: Failed to create trustee or trust for Cluster` about 30
   seconds in. **Use Kerberos** (`kinit`) — the same identity `ai-rc` uses on
   aiadm. `scripts/os-auth.sh` bridges it: Kerberos → scoped token → Terraform,
   because the OpenStack provider can't speak Kerberos itself.
2. **Quota is CORES, not instances.** 10 instances but only **10 cores**, and
   `m2.medium` is 2 cores → **5 instances max** (1 master + 4 workers). The
   config once said `autoscale_max = 6`, which was simply unreachable.
3. **Cluster templates get retired.** `kubernetes-1.33.3-1` vanished within
   months. Always list before applying. Avoid `-argo` variants — they set
   `cern_chart_enabled: false` and expect CERN's newer addon delivery.
4. **The magnum client is a separate package**, and so are the three Kerberos
   Python modules. Missing them fails in confusing ways: `openstack coe` claims
   it isn't a command; Kerberos dies on `No module named 'krb5'` because Arch's
   `python-gssapi` depends on the C library but not the Python one.
5. **A failed cluster cannot be refreshed.** The provider errors trying to read a
   kubeconfig that was never created, so `terraform plan` breaks until you
   `terraform state rm` it. Delete in OpenStack *and* drop it from state.

Also: the OpenStack project is **`av-tools`** (hyphen), your CERN username may
differ from your local login, and `terraform.tfvars` + `scripts/env.sh` are
gitignored — a fresh clone never has them, so the script seeds `tfvars` for you.

## Day-to-day

Kerberos tickets and Keystone tokens both expire. If Terraform starts returning
401s:

```bash
kinit <your-cern-username>@CERN.CH   # if klist is empty
source scripts/os-auth.sh            # refresh the token
```

## ⚠ CI cannot apply

`.gitlab-ci.yml` has a manual `tf_apply` job on `master` using
`gitlab-terraform`, which authenticates with **application credentials** — so it
cannot create the cluster, for the reason in bite #1. `terraform plan` in CI is
fine (read-only). Cluster creation is a human-with-Kerberos operation today. If
this needs to be automated, it needs a service account that can create trusts —
worth a question to the CERN cloud team rather than more guessing.

## Reference

- `scripts/os-auth.sh` — Kerberos → token bridge, and why it exists
- `terraform/README.md` — cluster details, CI, teardown
- `argocd/README.md` — GitOps bootstrap
- `scripts/sync-secret.sh` — tbag → Kubernetes Secret bridge
