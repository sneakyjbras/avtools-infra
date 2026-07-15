#!/usr/bin/env bash
#
# START HERE. The single entry point to this project.
#
# Run it. It checks the whole chain in dependency order, stops at the first thing
# that isn't ready, and prints the exact command to fix it. Fix, re-run, repeat.
# When it says CLUSTER IS UP, this layer is done.
#
#   ./scripts/start-here.sh           # check, then init + plan when ready
#   ./scripts/start-here.sh --check   # check only, touch nothing
#
# Idempotent. It NEVER applies — you always do that yourself.
#
# Why a script instead of a README: every value in the README was wrong at some
# point (dead cluster template, impossible autoscale max, wrong project name, an
# auth method that cannot work). A check that runs beats a doc that rots.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO}/terraform"
ENV_FILE="${REPO}/scripts/env.sh"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '  \033[90m·\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Print what to do, then stop. One action at a time, on purpose.
stop() {
  printf '\n\033[1;33m── DO THIS ─────────────────────────────────────\033[0m\n\n'
  while [ "$#" -gt 0 ]; do printf '  %s\n' "$1"; shift; done
  printf '\n\033[90m  then re-run: ./scripts/start-here.sh\033[0m\n\n'
  exit 1
}

cluster_name() { grep -E '^\s*cluster_name' "${TF_DIR}/terraform.tfvars" | cut -d'"' -f2; }

# ============================================================================
# 1. TOOLS
# ============================================================================
step "1. Tools"

need=""
command -v openstack >/dev/null 2>&1 && ok "openstack" || { bad "openstack missing"; need="$need python-openstackclient"; }

# The Magnum (coe) subcommands ship SEPARATELY from the base client. Without them
# `openstack coe ...` says "not an openstack command", which reads like a typo.
openstack coe --help >/dev/null 2>&1 && ok "magnum (coe) subcommands" || { bad "magnum client missing"; need="$need python-magnumclient"; }

# Kerberos auth to Keystone needs all three Python bits. The Arch python-gssapi
# package depends on the C krb5 library but NOT on the python krb5 module, so
# missing python-krb5 fails late with a confusing "No module named 'krb5'".
for mod_pkg in "requests_kerberos:python-requests-kerberos" "gssapi:python-gssapi" "krb5:python-krb5"; do
  mod="${mod_pkg%%:*}"; pkg="${mod_pkg##*:}"
  if /usr/bin/python -c "import ${mod}" >/dev/null 2>&1; then ok "python: ${mod}"; else bad "python: ${mod} missing"; need="$need $pkg"; fi
done

command -v terraform >/dev/null 2>&1 && ok "terraform" || { bad "terraform missing"; need="$need terraform"; }
command -v kinit >/dev/null 2>&1 && ok "kinit" || { bad "kinit missing"; need="$need krb5"; }

[ -z "$need" ] || stop "sudo pacman -S${need}" \
  "" \
  "(RHEL/CentOS: swap python-X for python3-X and use dnf)" \
  "" \
  "NB 'pacman -Ss magnum' also matches an unrelated C++ graphics library." \
  "The one you want is python-magnumclient."

# ============================================================================
# 2. YOUR VALUES
# ============================================================================
step "2. Your values"

if [ ! -f "$ENV_FILE" ]; then
  bad "scripts/env.sh not found"
  stop "cp scripts/env.example.sh scripts/env.sh" \
       "\$EDITOR scripts/env.sh" \
       "" \
       "Three values, all explained in the file. That is everything this" \
       "project needs from you."
fi
# shellcheck source=/dev/null
source "$ENV_FILE"
ok "scripts/env.sh"

: "${CERN_USER:?set CERN_USER in scripts/env.sh}"
: "${PROJECT_ID:?set PROJECT_ID in scripts/env.sh}"
ok "cern user (${CERN_USER}), project id (${PROJECT_ID})"

# The GitLab token is ONLY needed to reach Terraform state (step 8). Everything
# up to and including the cluster status check needs Kerberos alone — so don't
# block a status check on it. Warn now, hard-fail later, at the point of use.
if [ -n "${GITLAB_ACCESS_TOKEN:-}" ]; then
  ok "gitlab token"
else
  info "no GITLAB_ACCESS_TOKEN — checks still run; only terraform init/plan needs it"
fi

# ============================================================================
# 3. OPENSTACK  (Kerberos — NOT an application credential)
# ============================================================================
step "3. OpenStack auth"

if ! klist -s 2>/dev/null; then
  bad "no Kerberos ticket"
  stop "kinit ${CERN_USER}@CERN.CH" \
       "" \
       "OpenStack auth here is YOU, via Kerberos — the same identity 'ai-rc'" \
       "uses on aiadm. Application credentials cannot create Magnum clusters" \
       "at CERN (see scripts/os-auth.sh)."
fi
ok "kerberos ticket ($(klist 2>/dev/null | awk '/Default principal/{print $3}'))"

# Exchanges the Kerberos ticket for a scoped token and exports OS_TOKEN.
# shellcheck source=/dev/null
source "${REPO}/scripts/os-auth.sh" >/dev/null || stop \
  "Kerberos auth to Keystone failed." \
  "" \
  "Ticket expired?  kinit ${CERN_USER}@CERN.CH" \
  "" \
  "Details: source scripts/os-auth.sh"

project_id="$(openstack token issue -f value -c project_id 2>/dev/null || true)"
project_name="$(openstack project show -f value -c name "$project_id" 2>/dev/null || echo '?')"
[ "$project_name" = "av-tools" ] || stop \
  "Authenticated, but scoped to project '${project_name}' — expected 'av-tools'." \
  "" \
  "Check OS_PROJECT_NAME in scripts/os-auth.sh."
ok "keystone token, project: ${project_name}"

# ============================================================================
# 4. TERRAFORM CONFIG
# ============================================================================
step "4. Terraform config"

if [ ! -f "${TF_DIR}/terraform.tfvars" ]; then
  cp "${TF_DIR}/terraform.tfvars.example" "${TF_DIR}/terraform.tfvars"
  ok "created terraform.tfvars from example (gitignored — a fresh clone never has one)"
else
  ok "terraform.tfvars"
fi

TEMPLATE="$(grep -E '^\s*cluster_template' "${TF_DIR}/terraform.tfvars" | cut -d'"' -f2 || true)"
KEYPAIR="$(grep -E '^\s*keypair' "${TF_DIR}/terraform.tfvars" | cut -d'"' -f2 || true)"

# Templates are RETIRED, not merely superseded — kubernetes-1.33.3-1 vanished
# within months of being committed here. Stale name = cryptic data-source error.
if openstack coe cluster template show "$TEMPLATE" >/dev/null 2>&1; then
  ok "cluster template '${TEMPLATE}'"
else
  bad "cluster template '${TEMPLATE}' no longer exists (they rotate)"
  echo
  info "current plain templates:"
  openstack coe cluster template list -f value -c name 2>/dev/null \
    | grep -vE '\-(argo|aarch64|multi|rhel10)' | sed 's/^/      /'
  stop "Set cluster_template in terraform/terraform.tfvars to one of the above." \
       "" \
       "Avoid '-argo' variants: cern_chart_enabled=false, they expect CERN's" \
       "newer Argo addon delivery. This repo needs the plain template's" \
       "cern_chart (autoscaler + logging_producer fluentd)."
fi

# ============================================================================
# 5. QUOTA  (cores binds, not instances)
# ============================================================================
step "5. Quota"

max_cores="$(openstack limits show --absolute -f value -c Name -c Value 2>/dev/null | awk '$1=="max_total_cores"{print $2}')"
flavor="$(openstack coe cluster template show "$TEMPLATE" -f value -c flavor_id 2>/dev/null || true)"
vcpus="$(openstack flavor show "$flavor" -f value -c vcpus 2>/dev/null || true)"

if [ -n "$max_cores" ] && [ -n "${vcpus:-}" ] && [ "${vcpus:-0}" -gt 0 ] 2>/dev/null; then
  max_nodes=$(( max_cores / vcpus ))
  ok "${max_cores} cores; ${flavor} = ${vcpus} cores => ${max_nodes} instances max (master included)"
  want=$(( 1 + $(grep -E '^\s*autoscale_max' "${TF_DIR}/terraform.tfvars" | grep -oE '[0-9]+' | head -1) ))
  if [ "$want" -gt "$max_nodes" ]; then
    bad "autoscale_max implies ${want} nodes; quota allows ${max_nodes}"
    stop "Lower autoscale_max in terraform/terraform.tfvars to $(( max_nodes - 1 ))." \
         "" \
         "The instance quota looks generous, but CORES is the real ceiling." \
         "The autoscaler would silently fail to scale past it."
  fi
fi

# ============================================================================
# 6. KEYPAIR
# ============================================================================
step "6. Keypair"

# Terraform references the keypair BY NAME — it must exist before apply.
# Keypairs belong to your USER, not the project.
if openstack keypair show "$KEYPAIR" >/dev/null 2>&1; then
  ok "keypair '${KEYPAIR}' exists"
  fp="$(openstack keypair show "$KEYPAIR" -f value -c fingerprint 2>/dev/null || true)"
  have=0
  for pub in "$HOME"/.ssh/*.pub; do
    [ -f "$pub" ] || continue
    if [ "$(ssh-keygen -l -E md5 -f "$pub" 2>/dev/null | awk '{print $2}' | sed 's/^MD5://')" = "$fp" ]; then
      have=1; info "private key: ${pub%.pub}"; break
    fi
  done
  [ "$have" -eq 1 ] || stop \
    "Keypair '${KEYPAIR}' exists but no local private key matches it — you" \
    "could not SSH to the nodes when something breaks. Delete and recreate:" \
    "" \
    "  openstack keypair delete ${KEYPAIR}" \
    "" \
    "Then re-run; this script will make a fresh one."
else
  info "creating keypair '${KEYPAIR}'..."
  keyfile="$HOME/.ssh/${USER}_${KEYPAIR}"
  [ -f "$keyfile" ] || ssh-keygen -t ed25519 -f "$keyfile" -N "" -C "${KEYPAIR} nodes"
  openstack keypair create --public-key "${keyfile}.pub" "$KEYPAIR" >/dev/null
  ok "keypair '${KEYPAIR}' created (private key: ${keyfile})"
fi

# ============================================================================
# 7. CLUSTER
# ============================================================================
step "7. Cluster"

status="$(openstack coe cluster show "$(cluster_name)" -f value -c status 2>/dev/null || true)"
if [ -n "$status" ]; then
  ok "cluster '$(cluster_name)' — ${status}"
  case "$status" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      printf '\n\033[1;32m── CLUSTER IS UP ───────────────────────────────\033[0m\n\n'
      echo "  eval \$(openstack coe cluster config $(cluster_name))"
      echo "  kubectl get nodes"
      echo
      echo "  Next: secrets, then ArgoCD — see START-HERE.md"
      echo
      echo "  ⚠ BLOCKED ABOVE HERE: the chart pulls"
      echo "    registry.cern.ch/itdcim/avtools:qa, which does not exist. av-tools"
      echo "    master has no Dockerfile and no image build job. Deploying now"
      echo "    gives ImagePullBackOff on every CronJob. See START-HERE.md."
      echo
      exit 0 ;;
    CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS)
      # All four VMs go ACTIVE around 20 min while the cluster is still building:
      # Heat is then waiting on ignition, the kubelet bootstrap, and the
      # cern_chart addon install (45m budget in the template alone). Running VMs
      # are NOT a sign it is nearly done, and they are not a sign it is stuck.
      info "Normal. Budget 45-60 min — running VMs do not mean it's nearly done."
      info "Nothing to do; Magnum builds server-side whether or not you watch."
      info "Re-run this script to check again."
      exit 0 ;;
    CREATE_FAILED)
      # `faults` is usually an empty {}; status_reason carries the real cause.
      reason="$(openstack coe cluster show "$(cluster_name)" -f value -c status_reason 2>/dev/null || true)"
      bad "creation failed: ${reason}"
      case "$reason" in
        *trust*)
          stop "This is the application-credential trap. You are authenticated" \
               "with an app credential somewhere instead of Kerberos." \
               "" \
               "  unset OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET" \
               "  source scripts/os-auth.sh" \
               "" \
               "Then clear the wreckage and retry:" \
               "  openstack coe cluster delete $(cluster_name)" \
               "  cd terraform && terraform state rm openstack_containerinfra_cluster_v1.avtools" \
               "  terraform apply" \
               "" \
               "Details: scripts/os-auth.sh" ;;
      esac
      stop "Fix the cause above, then clear the wreckage and retry:" \
           "" \
           "  openstack coe cluster delete $(cluster_name)" \
           "  cd terraform && terraform state rm openstack_containerinfra_cluster_v1.avtools" \
           "  terraform apply" \
           "" \
           "(A failed cluster cannot be refreshed — the provider errors trying" \
           "to read a kubeconfig that was never created. Hence the state rm.)" ;;
  esac
else
  info "no cluster yet"
fi

[ "$CHECK_ONLY" -eq 1 ] && { echo; echo "All checks passed. Drop --check to init + plan."; exit 0; }

# ============================================================================
# 8. INIT + PLAN
# ============================================================================
step "8. Terraform init + plan"

# Now it's actually needed.
[ -n "${GITLAB_ACCESS_TOKEN:-}" ] || stop \
  "GITLAB_ACCESS_TOKEN is empty in scripts/env.sh." \
  "" \
  "gitlab.cern.ch -> avatar -> Preferences -> Access Tokens -> scope: api" \
  "" \
  "Terraform state lives in GitLab, so init/plan cannot run without it." \
  "(Everything above this point works fine without it.)"

STATE_URL="https://gitlab.cern.ch/api/v4/projects/${PROJECT_ID}/terraform/state/avtools"
cd "$TF_DIR"
terraform init -reconfigure -input=false \
  -backend-config="address=${STATE_URL}" \
  -backend-config="lock_address=${STATE_URL}/lock" \
  -backend-config="unlock_address=${STATE_URL}/lock" \
  -backend-config="username=${CERN_USER}" \
  -backend-config="password=${GITLAB_ACCESS_TOKEN}" \
  -backend-config="lock_method=POST" \
  -backend-config="unlock_method=DELETE" \
  -backend-config="retry_wait_min=5" >/dev/null
ok "init (state: GitLab project ${PROJECT_ID})"

echo
terraform plan

printf '\n\033[1;33m── DO THIS ─────────────────────────────────────\033[0m\n\n'
echo "  Expect: Plan: 1 to add, 0 to change, 0 to destroy."
echo
echo "  Build it (Kerberos token must be live — this shell has one):"
echo "    source scripts/os-auth.sh"
echo "    cd terraform && terraform apply"
echo
echo "  10-20 min, silent throughout. Then re-run this script."
echo
