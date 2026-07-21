#!/usr/bin/env bash
#
# THE single front door for the AV Tools Magnum (Kubernetes-on-OpenStack) deploy.
#
#   ./scripts/bootstrap.sh            # rebuild the cluster end-to-end (DESTRUCTIVE)
#   ./scripts/bootstrap.sh --check    # read-only: run the preflight/orientation
#                                     #   checks and CHANGE NOTHING. Exits non-zero
#                                     #   if a check fails (scriptable). This is the
#                                     #   old start-here.sh behaviour.
#
# A disposable-cluster rebuild becomes:
#
#     kinit <your-cern-username>@CERN.CH && ./scripts/bootstrap.sh
#
# It ORCHESTRATES the pieces that already exist — it does not reinvent them:
#   - run_checks() (below)    the preflight chain: tools, env.sh, Kerberos, Keystone
#                             /project, cluster template, cores quota, keypair,
#                             cluster status, kubectl/tbag, tfvars target. Used by
#                             BOTH --check and the normal-run preflight (no dup).
#   - scripts/os-auth.sh      Kerberos -> scoped OS_TOKEN bridge (Magnum needs a
#                             Keystone trust; app credentials cannot make one).
#   - terraform/              the cluster. Applying the 4x m2.large / m2.large-master
#                             topology REPLACES the Magnum cluster => the rebuild.
#   - scripts/sync-secret.sh  app secrets, bridged from tbag (single source of truth).
#   - argocd/                 app-of-apps -> AppProject + ApplicationSet (qa only;
#                             prod intentionally disabled) + kube-prometheus-stack.
#
# This automates exactly the manual runbook in docs/deployment/bootstrap.md and
# docs/cluster-buildout-runbook.md.
#
# ---------------------------------------------------------------------------
# DESTRUCTIVE (default mode). `terraform apply` of the target topology forces a
# FULL Magnum cluster replace: the running cluster (avtools-qa) is destroyed and
# rebuilt. The script requires you to type REBUILD unless --yes is passed. Use
# --check to only inspect, or --skip-terraform to re-bootstrap ArgoCD + secrets on
# an EXISTING cluster without touching it.
# ---------------------------------------------------------------------------
#
# PRECONDITION you must set by hand (terraform/terraform.tfvars is gitignored, so
# a fresh clone never has one and the script cannot know your intent):
#
#     cluster_name  = "avtools-k8s"
#     master_flavor = "m2.large"    # non-negotiable — see the master_flavor post-mortem
#     flavor        = "m2.large"    # worker flavor; changing it REPLACES the cluster
#     node_count    = 4
#     autoscale_min = 4
#     autoscale_max = 4             # 4 + 4*4 = 20 cores, the exact quota
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO}/terraform"
ENV_FILE="${REPO}/scripts/env.sh"

# ---------------------------------------------------------------------------
# Tunables (env-overridable). Defaults match the current deployment.
# ---------------------------------------------------------------------------
ARGOCD_MANIFEST_URL="${ARGOCD_MANIFEST_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml}"
KUBECONFIG_DIR="${KUBECONFIG_DIR:-${REPO}/.kube}"     # writable, gitignored
HG="${AVTOOLS_TBAG_HG:-itdcim/avtools}"

# Harbor pull secret (private image registry) — tbag key: harbor_robot_token
HARBOR_SERVER="registry.cern.ch"
HARBOR_SECRET_NAME="harbor-avtools"
HARBOR_ROBOT_USER="${HARBOR_ROBOT_USER:-robot-avtools+avtools-ci}"

# ArgoCD private-repo deploy token — tbag keys: argocd_repo_user, argocd_repo_token
ARGOCD_REPO_URL="https://gitlab.cern.ch/itdcim/av-tools-infra.git"
ARGOCD_REPO_SECRET_NAME="repo-av-tools-infra"

# The ApplicationSet generates only avtools-qa (prod is intentionally disabled).
APP_NAME="avtools-qa"
APP_NAMESPACE="avtools-qa"
SNMP_CRONJOB="avtools-snmp-timeseries"   # {{ fullname "avtools" }}-snmp-timeseries

# Target rebuild topology — tfvars MUST match this (checked in run_checks).
declare -A TARGET_TFVARS=(
  [master_flavor]=m2.large
  [flavor]=m2.large
  [node_count]=4
  [autoscale_min]=4
  [autoscale_max]=4
)

# Node wow= labels, lost on every rebuild. master -> medivh; the workers, sorted
# by their Magnum-generated name (...-node-0..3), -> arthas, bolvar, cairne, draka.
MASTER_WOW="medivh"
WORKER_WOW=(arthas bolvar cairne draka)

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
CHECK_ONLY=0
ASSUME_YES=0
SKIP_TERRAFORM=0
for arg in "$@"; do
  case "$arg" in
    --check)          CHECK_ONLY=1 ;;
    --yes|-y)         ASSUME_YES=1 ;;
    --skip-terraform) SKIP_TERRAFORM=1 ;;
    -h|--help)
      sed -n '3,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      echo "Flags:"
      echo "  --check           read-only preflight/orientation; change nothing; non-zero on failure"
      echo "  --yes / -y        skip the typed REBUILD confirmation"
      echo "  --skip-terraform  leave the cluster alone; only (re)bootstrap ArgoCD + secrets + labels"
      echo "  --help / -h       this help"
      exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '  \033[90m·\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die()  { printf '\n\033[31mABORT:\033[0m %s\n' "$1" >&2; exit 1; }

# Print what to do, then stop. One action at a time, on purpose. (From start-here.)
stop() {
  printf '\n\033[1;33m── DO THIS ─────────────────────────────────────\033[0m\n\n'
  while [ "$#" -gt 0 ]; do printf '  %s\n' "$1"; shift; done
  printf '\n\033[90m  then re-run: ./scripts/bootstrap.sh --check\033[0m\n\n'
  exit 1
}

cluster_name() { grep -E '^\s*cluster_name' "${TF_DIR}/terraform.tfvars" | cut -d'"' -f2; }

# Read a single scalar from terraform.tfvars (number or "quoted string").
tfvar() {
  grep -E "^\s*$1\s*=" "${TF_DIR}/terraform.tfvars" | head -1 \
    | sed -E "s/^\s*$1\s*=\s*//; s/#.*//; s/\"//g; s/[[:space:]]*$//"
}

# tbag reader with an env-var fallback. Prints the value to stdout (never logs it).
#   tbag_or_env <tbag-key> <ENV_VAR_NAME>
tbag_or_env() {
  local key="$1" envname="$2" val=""
  if command -v tbag >/dev/null 2>&1; then
    val="$(tbag show "$key" --hg "$HG" --plain 2>/dev/null || true)"
  fi
  if [ -z "$val" ]; then
    val="${!envname:-}"
    [ -n "$val" ] && warn "tbag key '$key' absent — using \$$envname instead." >&2
  fi
  printf '%s' "$val"
}

# ============================================================================
# run_checks — the WHOLE preflight/orientation chain, in dependency order.
#
# READ-ONLY: it inspects and reports; it never creates or mutates infrastructure
# (it does source os-auth.sh, which only exchanges your Kerberos ticket for a
# scoped token in THIS shell — no server-side change). Used verbatim by both
# `--check` and the normal-run preflight, so the two can never drift.
#
# On any unmet prerequisite it calls stop()/die() and exits non-zero. On success
# it returns 0 and leaves OS_TOKEN exported and CLUSTER_STATUS set.
# ============================================================================
CLUSTER_STATUS=""
CHECK_FAILED=0   # set by non-fatal --check findings so --check can exit non-zero

run_checks() {
  # ---- 1. Tools --------------------------------------------------------------
  step "1. Tools"
  local need=""
  # need_tool <label> <pkg> -- run the following command; log ok/bad and, on
  # absence, append <pkg> to $need. Keeps the tool list flat and shellcheck-clean.
  need_tool() {
    local label="$1" pkg="$2"; shift 2
    if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label missing"; need="$need $pkg"; fi
  }
  need_tool openstack python-openstackclient command -v openstack
  # The Magnum (coe) subcommands ship SEPARATELY from the base client.
  need_tool "magnum (coe) subcommands" python-magnumclient openstack coe --help
  # Kerberos auth to Keystone needs all three Python bits (gssapi does NOT pull krb5).
  local mod_pkg mod pkg
  for mod_pkg in "requests_kerberos:python-requests-kerberos" "gssapi:python-gssapi" "krb5:python-krb5"; do
    mod="${mod_pkg%%:*}"; pkg="${mod_pkg##*:}"
    need_tool "python: ${mod}" "$pkg" /usr/bin/python -c "import ${mod}"
  done
  need_tool terraform terraform command -v terraform
  need_tool kinit krb5 command -v kinit
  # kubectl + tbag are needed by the bootstrap steps (ArgoCD, secrets, labels).
  need_tool kubectl kubectl command -v kubectl
  if command -v tbag >/dev/null 2>&1; then
    ok "tbag (secrets pulled from hostgroup ${HG})"
  else
    warn "tbag not found — not on an itdcim/avtools host; secrets fall back to env vars (see step 6)."
  fi
  [ -z "$need" ] || stop "sudo pacman -S${need}" \
    "" \
    "(RHEL/CentOS: swap python-X for python3-X and use dnf; kubectl via its own repo)" \
    "" \
    "NB 'pacman -Ss magnum' also matches an unrelated C++ graphics library." \
    "The one you want is python-magnumclient."

  # ---- 2. Your values --------------------------------------------------------
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
  # GITLAB_ACCESS_TOKEN is only needed for the Terraform state backend (apply);
  # warn now, hard-fail at the point of use so a --check never blocks on it.
  if [ -n "${GITLAB_ACCESS_TOKEN:-}" ]; then ok "gitlab token"
  else info "no GITLAB_ACCESS_TOKEN — checks still run; only terraform apply needs it"; fi

  # ---- 3. OpenStack auth (Kerberos — NOT an application credential) ----------
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
  # shellcheck source=/dev/null
  source "${REPO}/scripts/os-auth.sh" >/dev/null || stop \
    "Kerberos auth to Keystone failed." \
    "" \
    "Ticket expired?  kinit ${CERN_USER}@CERN.CH" \
    "" \
    "Details: source scripts/os-auth.sh"
  local project_id project_name
  project_id="$(openstack token issue -f value -c project_id 2>/dev/null || true)"
  project_name="$(openstack project show -f value -c name "$project_id" 2>/dev/null || echo '?')"
  [ "$project_name" = "av-tools" ] || stop \
    "Authenticated, but scoped to project '${project_name}' — expected 'av-tools'." \
    "" \
    "Check OS_PROJECT_NAME in scripts/os-auth.sh."
  ok "keystone token, project: ${project_name}"

  # ---- 4. Terraform config (READ-ONLY: verify, never seed tfvars) ------------
  step "4. Terraform config"
  if [ ! -f "${TF_DIR}/terraform.tfvars" ]; then
    bad "terraform/terraform.tfvars not found (gitignored — a fresh clone has none)"
    stop "cp terraform/terraform.tfvars.example terraform/terraform.tfvars" \
         "\$EDITOR terraform/terraform.tfvars   # set the rebuild target:" \
         "  master_flavor=m2.large  flavor=m2.large  node_count=4" \
         "  autoscale_min=4  autoscale_max=4"
  fi
  ok "terraform.tfvars"
  local TEMPLATE KEYPAIR
  TEMPLATE="$(grep -E '^\s*cluster_template' "${TF_DIR}/terraform.tfvars" | cut -d'"' -f2 || true)"
  KEYPAIR="$(grep -E '^\s*keypair' "${TF_DIR}/terraform.tfvars" | cut -d'"' -f2 || true)"
  # Templates are RETIRED, not merely superseded — a stale name = cryptic error.
  if openstack coe cluster template show "$TEMPLATE" >/dev/null 2>&1; then
    ok "cluster template '${TEMPLATE}'"
  else
    bad "cluster template '${TEMPLATE}' no longer exists (they rotate)"
    echo; info "current plain templates:"
    openstack coe cluster template list -f value -c name 2>/dev/null \
      | grep -vE '\-(argo|aarch64|multi|rhel10)' | sed 's/^/      /'
    stop "Set cluster_template in terraform/terraform.tfvars to one of the above." \
         "" \
         "Avoid '-argo' variants: cern_chart_enabled=false, they expect CERN's" \
         "newer Argo addon delivery. This repo needs the plain template's cern_chart."
  fi

  # ---- 4b. tfvars matches the rebuild TARGET ---------------------------------
  # Fatal only when a rebuild is actually on the table (not --skip-terraform).
  if [ "$SKIP_TERRAFORM" -eq 0 ]; then
    step "4b. Rebuild target (tfvars)"
    local errs=0 name want got
    for name in master_flavor flavor node_count autoscale_min autoscale_max; do
      want="${TARGET_TFVARS[$name]}"; got="$(tfvar "$name")"
      if [ "$got" = "$want" ]; then ok "tfvars ${name} = ${got}"
      else bad "tfvars ${name} = '${got}', expected '${want}'"; errs=1; fi
    done
    if [ "$errs" -ne 0 ]; then
      if [ "$CHECK_ONLY" -eq 1 ]; then
        # Orientation must not abort here — tfvars-target is a rebuild concern, not
        # a prerequisite for inspecting the cluster. Report and keep going; --check
        # still exits non-zero at the end (scriptable) via CHECK_FAILED.
        CHECK_FAILED=1
        warn "tfvars is not at the rebuild target — a rebuild would refuse until you fix it."
      else
        stop \
          "terraform/terraform.tfvars is not set to the rebuild target." \
          "Set: master_flavor=m2.large  flavor=m2.large  node_count=4" \
          "     autoscale_min=4  autoscale_max=4" \
          "" \
          "(These force the intended full-cluster replace. Pass --skip-terraform to" \
          " bootstrap ArgoCD + secrets on the EXISTING cluster without a rebuild.)"
      fi
    fi
  else
    step "4b. Rebuild target (tfvars)"
    info "--skip-terraform: not validating tfvars target; the cluster is left untouched."
  fi

  # ---- 5. Quota (cores binds, not instances) ---------------------------------
  step "5. Quota"
  local max_cores flavor_id vcpus max_nodes want
  max_cores="$(openstack limits show --absolute -f value -c Name -c Value 2>/dev/null | awk '$1=="max_total_cores"{print $2}')"
  flavor_id="$(openstack coe cluster template show "$TEMPLATE" -f value -c flavor_id 2>/dev/null || true)"
  vcpus="$(openstack flavor show "$flavor_id" -f value -c vcpus 2>/dev/null || true)"
  if [ -n "$max_cores" ] && [ -n "${vcpus:-}" ] && [ "${vcpus:-0}" -gt 0 ] 2>/dev/null; then
    max_nodes=$(( max_cores / vcpus ))
    ok "${max_cores} cores; template flavor ${flavor_id} = ${vcpus} cores => ${max_nodes} instances max"
    want=$(( 1 + $(grep -E '^\s*autoscale_max' "${TF_DIR}/terraform.tfvars" | grep -oE '[0-9]+' | head -1) ))
    if [ "$want" -gt "$max_nodes" ]; then
      bad "autoscale_max implies ${want} nodes; template-flavor quota allows ${max_nodes}"
      stop "Lower autoscale_max in terraform/terraform.tfvars, or confirm the" \
           "override flavor's core math against the 20-core quota." \
           "" \
           "The instance quota looks generous, but CORES is the real ceiling."
    fi
  else
    info "quota math skipped (could not read cores/vcpus)"
  fi

  # ---- 6. Keypair (READ-ONLY: verify, never create) --------------------------
  step "6. Keypair"
  if openstack keypair show "$KEYPAIR" >/dev/null 2>&1; then
    ok "keypair '${KEYPAIR}' exists"
    local fp have=0 pub
    fp="$(openstack keypair show "$KEYPAIR" -f value -c fingerprint 2>/dev/null || true)"
    for pub in "$HOME"/.ssh/*.pub; do
      [ -f "$pub" ] || continue
      if [ "$(ssh-keygen -l -E md5 -f "$pub" 2>/dev/null | awk '{print $2}' | sed 's/^MD5://')" = "$fp" ]; then
        have=1; info "private key: ${pub%.pub}"; break
      fi
    done
    [ "$have" -eq 1 ] || stop \
      "Keypair '${KEYPAIR}' exists but no local private key matches it — you" \
      "could not SSH to the nodes when something breaks. Recreate it:" \
      "" \
      "  openstack keypair delete ${KEYPAIR}" \
      "  ssh-keygen -t ed25519 -f ~/.ssh/${KEYPAIR} -N '' -C '${KEYPAIR} nodes'" \
      "  openstack keypair create --public-key ~/.ssh/${KEYPAIR}.pub ${KEYPAIR}"
  else
    bad "keypair '${KEYPAIR}' does not exist (Terraform references it BY NAME)"
    stop "Create it (keypairs belong to your USER, not the project):" \
         "" \
         "  ssh-keygen -t ed25519 -f ~/.ssh/${KEYPAIR} -N '' -C '${KEYPAIR} nodes'" \
         "  openstack keypair create --public-key ~/.ssh/${KEYPAIR}.pub ${KEYPAIR}"
  fi

  # ---- 7. Cluster status (orientation) ---------------------------------------
  step "7. Cluster"
  CLUSTER_STATUS="$(openstack coe cluster show "$(cluster_name)" -f value -c status 2>/dev/null || true)"
  if [ -n "$CLUSTER_STATUS" ]; then
    ok "cluster '$(cluster_name)' — ${CLUSTER_STATUS}"
    case "$CLUSTER_STATUS" in
      CREATE_COMPLETE|UPDATE_COMPLETE) : ;;                       # up — fine for both modes
      CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS)
        info "Build in progress. Budget 45-60 min — running VMs do not mean it's nearly done." ;;
      CREATE_FAILED)
        local reason; reason="$(openstack coe cluster show "$(cluster_name)" -f value -c status_reason 2>/dev/null || true)"
        bad "creation failed: ${reason}"
        case "$reason" in
          *trust*) stop "The application-credential trap: you are authenticated with an" \
                        "app credential instead of Kerberos." \
                        "" \
                        "  unset OS_APPLICATION_CREDENTIAL_ID OS_APPLICATION_CREDENTIAL_SECRET" \
                        "  source scripts/os-auth.sh" \
                        "" \
                        "Then clear the wreckage and rebuild:" \
                        "  openstack coe cluster delete $(cluster_name)" \
                        "  cd terraform && terraform state rm openstack_containerinfra_cluster_v1.avtools" \
                        "  ./scripts/bootstrap.sh" ;;
        esac
        stop "Clear the wreckage, then rebuild:" \
             "" \
             "  openstack coe cluster delete $(cluster_name)" \
             "  cd terraform && terraform state rm openstack_containerinfra_cluster_v1.avtools" \
             "  ./scripts/bootstrap.sh" \
             "" \
             "(A failed cluster cannot be refreshed — the provider errors reading a" \
             "kubeconfig that was never created. Hence the state rm.)" ;;
    esac
  else
    info "no cluster yet (a normal state before the first build)"
  fi

  return 0
}

# ============================================================================
# --check mode: run the chain, print orientation, change nothing, exit.
# ============================================================================
if [ "$CHECK_ONLY" -eq 1 ]; then
  printf '\033[1mAV Tools — preflight / orientation (read-only)\033[0m\n'
  run_checks
  case "$CLUSTER_STATUS" in
    CREATE_COMPLETE|UPDATE_COMPLETE)
      printf '\n\033[1;32m── CLUSTER IS UP ───────────────────────────────\033[0m\n\n'
      echo "  Rebuild it:            ./scripts/bootstrap.sh"
      echo "  Re-bootstrap only:     ./scripts/bootstrap.sh --skip-terraform"
      echo "  Kubeconfig:            openstack coe cluster config $(cluster_name)" ;;
    CREATE_IN_PROGRESS|UPDATE_IN_PROGRESS)
      printf '\n\033[1;33m── CLUSTER IS BUILDING ─────────────────────────\033[0m\n\n'
      echo "  Nothing to do; Magnum builds server-side. Re-run --check to poll." ;;
    *)
      if [ "$CHECK_FAILED" -eq 0 ]; then
        printf '\n\033[1;32m── ALL CHECKS PASSED ───────────────────────────\033[0m\n\n'
        echo "  No cluster yet. Build it:  ./scripts/bootstrap.sh"
      fi ;;
  esac
  if [ "$CHECK_FAILED" -ne 0 ]; then
    printf '\n\033[1;33m── NOT READY TO REBUILD ────────────────────────\033[0m\n\n'
    echo "  Cluster inspection OK, but fix the tfvars target above before a rebuild."
    echo
    exit 1
  fi
  echo
  exit 0
fi

# ============================================================================
# 1. PREFLIGHT  (same run_checks() — the normal run gates on it before destroying)
# ============================================================================
step "1. Preflight"
run_checks
ok "preflight passed"

# ============================================================================
# 2. CONFIRM  (only when we are about to destroy)
# ============================================================================
step "2. Confirm"
if [ "$SKIP_TERRAFORM" -eq 1 ]; then
  ok "--skip-terraform: no destroy; confirmation not required."
elif [ "$ASSUME_YES" -eq 1 ]; then
  warn "--yes: skipping typed confirmation. Cluster '$(cluster_name)' WILL be rebuilt."
else
  echo
  warn "This DESTROYS and rebuilds cluster '$(cluster_name)' (currently running avtools-qa)."
  read -r -p "  Type REBUILD to continue: " reply
  [ "$reply" = "REBUILD" ] || die "Not confirmed (you typed '${reply:-}'). Nothing changed."
  ok "confirmed"
fi

# ============================================================================
# 3. TERRAFORM APPLY  (the flavor/count target forces a full cluster replace)
# ============================================================================
step "3. Terraform apply"
if [ "$SKIP_TERRAFORM" -eq 1 ]; then
  info "--skip-terraform: skipping. Using whatever cluster is already up."
else
  # run_checks already sourced env.sh + os-auth.sh; refresh the token (short-lived)
  # right before the long apply so it cannot 401 mid-build.
  # shellcheck source=/dev/null
  source "${REPO}/scripts/os-auth.sh" >/dev/null
  : "${GITLAB_ACCESS_TOKEN:?set GITLAB_ACCESS_TOKEN in scripts/env.sh (Terraform state lives in GitLab)}"
  STATE_URL="https://gitlab.cern.ch/api/v4/projects/${PROJECT_ID}/terraform/state/avtools"
  (
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
    ok "terraform init (state: GitLab project ${PROJECT_ID})"
    info "applying — a topology change REPLACES the cluster; budget 45-60 min, silent."
    terraform apply -auto-approve
  )
  ok "terraform apply complete"
fi

# ============================================================================
# 4. KUBECONFIG
# ============================================================================
step "4. Kubeconfig"
mkdir -p "$KUBECONFIG_DIR"
# --force overwrites any stale config from a previous cluster => idempotent/re-runnable.
openstack coe cluster config --dir "$KUBECONFIG_DIR" --force "$(cluster_name)" >/dev/null
export KUBECONFIG="${KUBECONFIG_DIR}/config"
kubectl cluster-info >/dev/null 2>&1 || die "kubeconfig written but kubectl cannot reach the API server."
ok "KUBECONFIG=${KUBECONFIG} ($(kubectl get nodes --no-headers 2>/dev/null | wc -l) nodes)"

# ============================================================================
# 5. ARGOCD  (install core; server-side apply — the big CRDs blow the client-side
#    annotation limit; this is the known gotcha in the runbook)
# ============================================================================
step "5. ArgoCD (core install)"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# --server-side --force-conflicts: the upstream install.yaml carries CRDs (incl. the
# ApplicationSet CRD) that exceed the 262 KiB client-side last-applied annotation
# limit, so a plain `kubectl apply` fails with "metadata.annotations: Too long".
kubectl apply -n argocd --server-side --force-conflicts -f "$ARGOCD_MANIFEST_URL" >/dev/null
ok "argo-cd manifests applied (server-side)"
info "waiting for argocd-server + applicationset-controller to roll out..."
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s >/dev/null
kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=300s >/dev/null
ok "ArgoCD is up"

# ============================================================================
# 6. SECRETS  (all 3, from tbag — no manual paste)
#    a) ArgoCD private-repo deploy token   -> ns argocd  (before app-of-apps syncs)
#    b) app secrets (sync-secret.sh)        -> ns avtools-qa
#    c) Harbor image pull secret            -> ns avtools-qa
# ============================================================================
step "6. Secrets (from tbag)"

# --- a) ArgoCD repo deploy token -------------------------------------------------
repo_user="$(tbag_or_env argocd_repo_user ARGOCD_REPO_USER)"
repo_token="$(tbag_or_env argocd_repo_token ARGOCD_REPO_TOKEN)"
if [ -n "$repo_user" ] && [ -n "$repo_token" ]; then
  kubectl create secret generic "$ARGOCD_REPO_SECRET_NAME" \
    --namespace argocd \
    --from-literal=type=git \
    --from-literal=url="$ARGOCD_REPO_URL" \
    --from-literal=username="$repo_user" \
    --from-literal=password="$repo_token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n argocd label secret "$ARGOCD_REPO_SECRET_NAME" \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  ok "ArgoCD repo credential (secret/${ARGOCD_REPO_SECRET_NAME} in argocd)"
else
  warn "no ArgoCD repo deploy token (tbag argocd_repo_user/argocd_repo_token or"
  warn "  \$ARGOCD_REPO_USER/\$ARGOCD_REPO_TOKEN). If the repo is private, ArgoCD"
  warn "  will fail to fetch it until you add the credential. See docs/deployment/bootstrap.md."
fi

# --- b) App secrets (tbag -> secret/avtools-secrets), creates the namespace -------
info "syncing app secrets via scripts/sync-secret.sh (env=qa)..."
AVTOOLS_ENVIRONMENT=qa "${REPO}/scripts/sync-secret.sh"
ok "app secrets in sync (secret/avtools-secrets in ${APP_NAMESPACE})"

# --- c) Harbor image pull secret --------------------------------------------------
harbor_token="$(tbag_or_env harbor_robot_token HARBOR_ROBOT_TOKEN)"
if [ -n "$harbor_token" ]; then
  kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry "$HARBOR_SECRET_NAME" \
    --namespace "$APP_NAMESPACE" \
    --docker-server="$HARBOR_SERVER" \
    --docker-username="$HARBOR_ROBOT_USER" \
    --docker-password="$harbor_token" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  ok "Harbor pull secret (secret/${HARBOR_SECRET_NAME} in ${APP_NAMESPACE})"
else
  warn "no Harbor robot token (tbag harbor_robot_token or \$HARBOR_ROBOT_TOKEN)."
  warn "  Without it the private image cannot be pulled => ImagePullBackOff."
fi

# ============================================================================
# 7. GITOPS  (apply the app-of-apps root — deferred until after secrets so the
#    first sync already finds repo creds + pull secret + app secret in place)
# ============================================================================
step "7. GitOps (app-of-apps)"
kubectl apply -n argocd --server-side --force-conflicts -f "${REPO}/argocd/app-of-apps.yaml" >/dev/null
ok "avtools-root applied — ArgoCD now reconciles AppProject + ApplicationSet (qa) + kube-prometheus-stack"

# ============================================================================
# 8. NODE LABELS  (the wow= scheme, lost on rebuild)
# ============================================================================
step "8. Node labels (wow=)"
# Names are Magnum-generated: <cluster>-<id>-master-0 and <cluster>-<id>-node-0..3.
mapfile -t masters < <(kubectl get nodes -o name | sed 's|node/||' | grep -- '-master-' | sort)
mapfile -t workers < <(kubectl get nodes -o name | sed 's|node/||' | grep -- '-node-'   | sort)

for m in "${masters[@]}"; do
  kubectl label node "$m" "wow=${MASTER_WOW}" --overwrite >/dev/null
  ok "master ${m} -> wow=${MASTER_WOW}"
done

[ "${#workers[@]}" -eq 4 ] || warn "expected 4 workers, found ${#workers[@]} — labelling as many as line up."
i=0
for w in "${workers[@]}"; do
  if [ "$i" -lt "${#WORKER_WOW[@]}" ]; then
    kubectl label node "$w" "wow=${WORKER_WOW[$i]}" --overwrite >/dev/null
    ok "worker ${w} -> wow=${WORKER_WOW[$i]}"
  else
    warn "worker ${w} has no wow name left (more than 4 workers?)"
  fi
  i=$((i + 1))
done

# ============================================================================
# 9. WAIT + VERIFY
# ============================================================================
step "9. Wait + verify"
info "waiting for ArgoCD app '${APP_NAME}' to become Synced/Healthy (up to 10 min)..."
deadline=$(( $(date +%s) + 600 ))
app_state=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  sync="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  health="$(kubectl -n argocd get application "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  app_state="${sync:-?}/${health:-?}"
  [ "$app_state" = "Synced/Healthy" ] && break
  sleep 10
done
if [ "$app_state" = "Synced/Healthy" ]; then ok "app ${APP_NAME}: ${app_state}"
else warn "app ${APP_NAME}: ${app_state} (did not reach Synced/Healthy in time)"; fi

info "waiting for the snmp CronJob to be created (up to 3 min)..."
deadline=$(( $(date +%s) + 180 ))
cron_ok=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl -n "$APP_NAMESPACE" get cronjob "$SNMP_CRONJOB" >/dev/null 2>&1; then cron_ok=1; break; fi
  sleep 10
done
if [ "$cron_ok" -eq 1 ]; then ok "cronjob/${SNMP_CRONJOB} exists"
else warn "cronjob/${SNMP_CRONJOB} not found yet (ArgoCD may still be syncing)"; fi

# ---------------------------------------------------------------------------
# Final summary
# ---------------------------------------------------------------------------
printf '\n\033[1;32m── BOOTSTRAP SUMMARY ───────────────────────────\033[0m\n\n'
echo "  export KUBECONFIG=${KUBECONFIG}"
echo
echo "  Nodes (wow=):"
kubectl get nodes -L wow --no-headers 2>/dev/null | awk '{printf "    %-40s %s\n", $1, $6}'
echo
echo "  ArgoCD apps:"
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers 2>/dev/null | sed 's/^/    /'
echo
echo "  CronJobs (${APP_NAMESPACE}):"
kubectl -n "$APP_NAMESPACE" get cronjobs --no-headers 2>/dev/null | awk '{printf "    %-30s %s\n", $1, $2}' || echo "    (none yet)"
echo
echo "  Reminder: the chart pulls ${HARBOR_SERVER}/avtools/avtools:qa. If the av-tools"
echo "  image does not exist yet, the CronJob pods ImagePullBackOff — that is the"
echo "  known blocker documented in START-HERE.md, not a bootstrap failure."
echo
