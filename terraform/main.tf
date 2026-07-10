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

  # Cluster creation on Magnum can take several minutes.
  timeouts {
    create = "30m"
    update = "30m"
    delete = "20m"
  }
}
