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
  default     = 3
}

variable "master_count" {
  description = "Number of control-plane nodes."
  type        = number
  default     = 1
}

variable "flavor" {
  description = "Worker node flavor. Null keeps the template default (m2.medium)."
  type        = string
  default     = null
}

variable "master_flavor" {
  description = "Control-plane flavor. Null keeps the template default."
  type        = string
  default     = null
}

variable "autoscale_min" {
  description = "cluster-autoscaler minimum worker count."
  type        = number
  default     = 3
}

variable "autoscale_max" {
  description = <<-EOT
    cluster-autoscaler maximum worker count.

    Bounded by CORES, not instances. The av-tools project quota is 10 instances
    but only 10 CORES, and m2.medium is 2 cores — so 5 instances total is the
    real ceiling: 1 master + 4 workers. A previous value of 6 was unreachable
    (7 nodes = 14 cores); the autoscaler would have silently failed to scale.
  EOT
  type        = number
  default     = 4

  validation {
    # 1 master + max workers, at 2 cores each, must fit the 10-core quota.
    condition     = (1 + var.autoscale_max) * 2 <= 10
    error_message = "Quota is 10 cores and m2.medium is 2 cores, so 1 master plus autoscale_max workers must fit in 5 instances. Set autoscale_max to 4 or lower."
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
