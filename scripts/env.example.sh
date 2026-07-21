# Copy to scripts/env.sh and fill in. That copy is gitignored — never commit it.
#
#   cp scripts/env.example.sh scripts/env.sh
#   $EDITOR scripts/env.sh
#   ./scripts/bootstrap.sh --check
#
# Three values. That is everything this project needs from a human.
#
# Note there is NO OpenStack credential here, on purpose: OpenStack auth comes
# from your Kerberos ticket (`kinit`), the same identity `ai-rc` uses on aiadm.
# Application credentials CANNOT create Magnum clusters at CERN — see
# scripts/os-auth.sh for the full story. There is no credential file to leak.

# 1. Your CERN username — the Kerberos principal, e.g. `kinit jsapinat@CERN.CH`.
#    NOT your local login name, and also your gitlab.cern.ch username.
export CERN_USER="jsapinat"

# 2. GitLab personal access token, scope: api. Terraform state lives in GitLab.
#    gitlab.cern.ch -> avatar -> Preferences -> Access Tokens.
#    The only secret here. Keep this file out of git (it already is).
export GITLAB_ACCESS_TOKEN=""

# 3. Numeric project ID of this repo, shown under the name on its GitLab page.
export PROJECT_ID="239202"
