terraform {
  required_version = ">= 1.6"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 3.0"
    }
  }

  # State lives in GitLab's managed Terraform/OpenTofu state backend (no extra
  # infra). `terraform init` is run with the project-specific address, e.g.:
  #
  #   terraform init \
  #     -backend-config="address=https://gitlab.cern.ch/api/v4/projects/<ID>/terraform/state/avtools" \
  #     -backend-config="lock_address=https://gitlab.cern.ch/api/v4/projects/<ID>/terraform/state/avtools/lock" \
  #     -backend-config="unlock_address=https://gitlab.cern.ch/api/v4/projects/<ID>/terraform/state/avtools/lock" \
  #     -backend-config="username=<gitlab-user>" \
  #     -backend-config="password=$GITLAB_ACCESS_TOKEN" \
  #     -backend-config="lock_method=POST" \
  #     -backend-config="unlock_method=DELETE" \
  #     -backend-config="retry_wait_min=5"
  #
  # In CI the address/credentials are injected automatically by the
  # `gitlab-terraform` wrapper (see terraform/README.md).
  backend "http" {}
}
