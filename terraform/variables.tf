# Auth is provided out-of-band via OpenStack application-credential env vars
# (OS_AUTH_TYPE=v3applicationcredential, OS_APPLICATION_CREDENTIAL_ID/SECRET,
# OS_AUTH_URL, OS_REGION_NAME) or a clouds.yaml. Do NOT put credentials here.

variable "cluster_name" {
  description = "Magnum cluster name."
  type        = string
  default     = "avtools-k8s"
}

variable "cluster_template" {
  description = <<-EOT
    Public CERN Magnum cluster template name (or UUID). Versions are RETIRED,
    not just superseded — `kubernetes-1.33.3-1` vanished within months. Always
    run `openstack coe cluster template list` before applying.

    Avoid the `-argo` variants: they set cern_chart_enabled=false (stripped, for
    CERN's newer Argo-based addon delivery). This repo assumes the plain
    template's cern_chart for the autoscaler and `logging_producer` fluentd.
  EOT
  type        = string
  default     = "kubernetes-1.35.3-2"
}

variable "keypair" {
  description = <<-EOT
    Name of an existing OpenStack keypair for node SSH access. Terraform
    references it BY NAME, so it must already exist in the project before apply
    (`scripts/start-here.sh` creates it if missing).

    Defaulted because terraform.tfvars is gitignored: CI has no tfvars, so any
    variable without a default breaks `terraform plan` in the pipeline. The name
    is not a secret. Keypairs belong to your USER, not the project — whoever
    applies must hold the matching private key or they cannot SSH to the nodes.
  EOT
  type        = string
  default     = "avtools-k8s"
}

variable "node_count" {
  description = "Number of worker nodes (master_count is fixed at 1)."
  type        = number
  default     = 4
}

variable "master_count" {
  description = "Number of control-plane nodes."
  type        = number
  default     = 1
}

variable "flavor" {
  description = <<-EOT
    Worker node flavor. Null keeps the template default (m2.medium).

    DANGER — DO NOT change this on a LIVE cluster. `flavor` is immutable on the
    Magnum cluster resource, so terraform treats any change as
    `forces replacement` and will DESTROY + recreate the ENTIRE cluster (master,
    ArgoCD, avtools-qa, all workloads). Confirmed via `terraform plan` on
    2026-07-20 ("cluster must be replaced ... Plan: 1 to add, 1 to destroy").

    The cluster IS memory-bound and workers should move to m2.large — but do it
    with a NODEGROUP migration, NOT this variable: create an m2.large nodegroup
    (`openstack coe nodegroup create ... --flavor m2.large`), drain the m2.medium
    default nodegroup onto it, then remove the old one. Quota-tight (3x m2.medium
    + 4x m2.large = 26 > 20 cores), so it's a staged swap.
  EOT
  type        = string
  default     = null
}

variable "master_flavor" {
  description = <<-EOT
    Control-plane flavor. Default m2.large (4 vCPU / 7.5 GB) is DELIBERATE and
    load-bearing — do not drop it back to the template default (m2.medium).

    Root-caused 2026-07-17 after two CREATE_FAILEDs: the m2.medium master
    (2 vCPU / 3.75 GB) cannot run etcd + the control plane + CERN's full
    cern-magnum addon bundle (Falco, Prometheus, Velero, cert-manager, Cilium,
    4x CSI, autoscaler, NFD, fluentd...) all installing at once. Measured on the
    failed master: 114 MiB free RAM, load 5.2 on 2 cores, a cascade of
    "context deadline exceeded" probe failures → the cern-magnum Helm install
    never converged → CREATE_FAILED. m2.large gives the headroom; first build on
    it reached CREATE_COMPLETE. See START-HERE.md ("things that bite").
  EOT
  type        = string
  default     = "m2.large"
}

variable "autoscale_min" {
  description = "cluster-autoscaler minimum worker count."
  type        = number
  default     = 4
}

variable "autoscale_max" {
  description = <<-EOT
    cluster-autoscaler maximum worker count.

    Bounded by CORES, not instances. Quota was raised 2026-07 to 20 cores. With
    the m2.large master (4 cores) and m2.large workers (4 cores each):
    4 + 4*max <= 20  =>  max <= 4. So 4 workers is the ceiling and it exactly
    maxes the quota (4 + 4*4 = 20); min == max == 4 today, no headroom to
    autoscale past node_count. (The m2.large master is non-negotiable — see the
    master_flavor post-mortem above.)
  EOT
  type        = number
  default     = 4

  validation {
    # m2.large master (4 cores) + max workers at 4 cores each, within 20 cores.
    condition     = 4 + var.autoscale_max * 4 <= 20
    error_message = "Quota is 20 cores; the m2.large master uses 4, leaving room for 4 m2.large workers. Set autoscale_max to 4 or lower."
  }
}

variable "extra_labels" {
  description = <<-EOT
    Extra Magnum labels merged on top of the template labels (merge_labels=true).
    Defaults enable the cluster-autoscaler and the central logging producer so
    cluster service logs ship to CERN IT logging.

    min_node_count/max_node_count are NOT set here — main.tf derives them from
    autoscale_min/autoscale_max so the labels and the variables cannot drift.
  EOT
  type        = map(string)
  default = {
    auto_scaling_enabled = "true"
    logging_producer     = "true"
  }
}
