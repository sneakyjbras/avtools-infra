provider "openstack" {
  # All connection settings come from the environment / clouds.yaml.
}

# Resolve the public cluster template by name so we can reference it by a
# human-readable version string instead of a UUID.
data "openstack_containerinfra_clustertemplate_v1" "template" {
  name = var.cluster_template
}

# Merge the autoscaler/logging overrides with min/max derived from the
# autoscale_* variables so the two stay consistent.
locals {
  labels = merge(
    var.extra_labels,
    {
      min_node_count = tostring(var.autoscale_min)
      max_node_count = tostring(var.autoscale_max)
    },
  )
}

resource "openstack_containerinfra_cluster_v1" "avtools" {
  name                = var.cluster_name
  cluster_template_id = data.openstack_containerinfra_clustertemplate_v1.template.id
  keypair             = var.keypair
  master_count        = var.master_count
  node_count          = var.node_count
  flavor              = var.flavor
  master_flavor       = var.master_flavor

  # Keep the template's labels and layer ours on top.
  merge_labels = true
  labels       = local.labels

  # Magnum creation is SLOW and 30m was not enough (observed 2026-07-15: all four
  # VMs Active at ~20 min, cluster still CREATE_IN_PROGRESS at 25+).
  #
  # "Active" instances only mean the VMs booted. Heat then waits on ignition,
  # the Kubernetes bootstrap, and the cern_chart addon install — and the CERN
  # template itself budgets `helm-install-timeout: 45m0s` for that last stage
  # alone. So the create timeout must comfortably exceed 45m.
  #
  # This matters beyond patience: when Terraform times out it errors while Magnum
  # happily keeps building, leaving state out of step with a cluster that is
  # actually fine.
  timeouts {
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}
