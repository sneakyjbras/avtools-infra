# Source this (don't run it) to authenticate to CERN OpenStack for Terraform:
#
#   source scripts/os-auth.sh
#   cd terraform && terraform apply
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS — do not "simplify" it back to an application credential.
#
# Magnum creates a Keystone TRUST so the cluster can call OpenStack back (load
# balancers, volumes, autoscaler). Trust creation from an application credential
# FAILS at CERN — including with `unrestricted = True`, which the Keystone docs
# claim should permit it. Verified the hard way on 2026-07-15: two applies, both
# CREATE_FAILED ~30s in with
#
#     Failed to create trustee or trust for Cluster: <uuid>
#
# So the cluster must be created as YOU (Kerberos), the same identity that works
# with `ai-rc` on aiadm. Terraform's OpenStack provider cannot speak Kerberos
# (gophercloud has no v3fedkerb), so we bridge: authenticate with Kerberos via
# the openstack CLI, exchange that for a plain scoped TOKEN, and hand the token
# to Terraform.
#
# Application credentials remain fine for read-only/CI things. Just not Magnum.
# ---------------------------------------------------------------------------
#
# Requires: kinit + python-requests-kerberos, python-gssapi, python-krb5
# (all three; the Arch python-gssapi package does not pull in the krb5 module).

_os_auth() {
  # NB your CERN principal is NOT necessarily your local login name.
  if ! klist -s 2>/dev/null; then
    echo "No Kerberos ticket. Run:  kinit <your-cern-username>@CERN.CH" >&2
    return 1
  fi
  local principal
  principal="$(klist 2>/dev/null | awk '/Default principal/{print $3}')"

  # App-cred vars would take precedence over the token — clear them.
  unset OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET OS_TOKEN

  local token
  token="$(
    env -u OS_TOKEN \
      OS_AUTH_TYPE=v3fedkerb \
      OS_AUTH_URL=https://keystone.cern.ch/v3 \
      OS_IDENTITY_PROVIDER=sssd \
      OS_PROTOCOL=kerberos \
      OS_PROJECT_NAME=av-tools \
      OS_PROJECT_DOMAIN_ID=default \
      OS_REGION_NAME=cern \
      openstack token issue -f value -c id 2>/dev/null
  )"

  if [ -z "$token" ]; then
    echo "Kerberos auth to Keystone failed (principal: ${principal:-none})." >&2
    echo "Ticket expired? Try: kinit ${principal:-<your-cern-username>@CERN.CH}" >&2
    echo "Missing plugin?  sudo pacman -S python-requests-kerberos python-gssapi python-krb5" >&2
    return 1
  fi

  # Hand the token to both consumers:
  #   - Terraform (gophercloud) infers token auth from OS_TOKEN and ignores
  #     OS_AUTH_TYPE, which is a keystoneauth concept.
  #   - The openstack CLI (keystoneauth) does NOT infer it, and without an
  #     explicit OS_AUTH_TYPE it falls back to password auth and asks for a
  #     password that doesn't exist. Hence v3token.
  unset OS_IDENTITY_PROVIDER OS_PROTOCOL
  export OS_AUTH_TYPE=v3token
  export OS_AUTH_URL=https://keystone.cern.ch/v3
  export OS_TOKEN="$token"
  export OS_PROJECT_NAME=av-tools
  export OS_PROJECT_DOMAIN_ID=default
  export OS_REGION_NAME=cern

  echo "OpenStack: authenticated as ${principal} via Kerberos, project av-tools."
  echo "           (token is short-lived — re-source this if Terraform 401s)"
}

_os_auth
