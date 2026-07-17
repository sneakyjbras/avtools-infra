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
  default     = 3
}

variable "autoscale_max" {
  description = <<-EOT
    cluster-autoscaler maximum worker count.

    Bounded by CORES, not instances. Quota is 10 cores. With the m2.large master
    (4 cores) the fix above requires, and m2.medium workers (2 cores each):
    4 + 2*max <= 10  =>  max <= 3. So 3 workers is the ceiling and there is no
    headroom to autoscale past node_count; min == max == 3 today. (Getting a
    cluster that builds at all mattered more than scaling room — the m2.large
    master is non-negotiable, see above.)
  EOT
  type        = number
  default     = 3

  validation {
    # m2.large master (4 cores) + max workers at 2 cores each, within 10 cores.
    condition     = 4 + var.autoscale_max * 2 <= 10
    error_message = "Quota is 10 cores; the m2.large master uses 4, leaving room for 3 m2.medium workers. Set autoscale_max to 3 or lower."
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
