# Terraform — AV Tools Magnum cluster

Provisions the Kubernetes-on-OpenStack (Magnum) cluster for AV Tools in the
`avtools` OpenStack project: **1 master + 3 workers** (`m2.medium`) with the
`cluster-autoscaler` addon (min 3 / max 6). State is stored in **GitLab-managed
Terraform state** (no extra infra).

## Auth (never commit credentials)

Use an OpenStack **application credential** for the `avtools` project:

```bash
export OS_AUTH_TYPE=v3applicationcredential
export OS_AUTH_URL=https://keystone.cern.ch/v3
export OS_APPLICATION_CREDENTIAL_ID=...
export OS_APPLICATION_CREDENTIAL_SECRET=...
export OS_REGION_NAME=cern           # or the region shown by `openstack region list`
```

## Local run

```bash
cp terraform.tfvars.example terraform.tfvars   # set keypair, sizing
terraform init -backend-config=... (see versions.tf for the GitLab state address)
terraform plan
terraform apply
eval $(openstack coe cluster config avtools-k8s)   # kubeconfig for kubectl/ArgoCD
```

## CI

In GitLab CI use the `gitlab-terraform` wrapper (image
`registry.gitlab.com/gitlab-org/terraform-images/stable`), which injects the
managed-state address and credentials automatically. The OpenStack
application-credential values are **masked** CI variables. A merge request runs
`terraform plan`; `apply` is a **manual** job on the default branch.

## Notes

- Template/flavor names change frequently — re-check
  `openstack coe cluster template list` before applying.
- `merge_labels = true` keeps the template's labels and layers ours on top
  (autoscaler + `logging_producer`).
- Deleting the cluster may leave load balancers / volumes behind — clean up per
  the CERN Kubernetes docs.
