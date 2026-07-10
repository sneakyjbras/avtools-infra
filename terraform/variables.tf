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
    Public CERN Magnum cluster template name (or UUID). Versions change often —
    check `openstack coe cluster template list` before applying.
  EOT
  type        = string
  default     = "kubernetes-1.33.3-1"
}

variable "keypair" {
  description = "Name of an existing OpenStack keypair for node SSH access."
  type        = string
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
  description = "cluster-autoscaler maximum worker count (bounded by project quota)."
  type        = number
  default     = 6
}

variable "extra_labels" {
  description = <<-EOT
    Extra Magnum labels merged on top of the template labels (merge_labels=true).
    Defaults enable the cluster-autoscaler and the central logging producer so
    cluster service logs ship to CERN IT logging.
  EOT
  type        = map(string)
  default = {
    auto_scaling_enabled = "true"
    min_node_count       = "3"
    max_node_count       = "6"
    logging_producer     = "true"
  }
}
