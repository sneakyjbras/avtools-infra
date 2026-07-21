#!/usr/bin/env bash
#
# One-command cluster rebuild for the AV Tools Magnum (Kubernetes-on-OpenStack)
# deployment. A disposable-cluster rebuild becomes:
#
#     kinit <you>@CERN.CH && ./scripts/bootstrap.sh
#
# It ORCHESTRATES the pieces that already exist — it does not reinvent them:
#   - scripts/start-here.sh   the preflight chain (tools, env, Kerberos, template,
#                             quota, keypair, cluster) — reused as the gate.
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
# DESTRUCTIVE. `terraform apply` of the target topology forces a FULL Magnum
# cluster replace: the running cluster (avtools-qa) is destroyed and rebuilt.
# Step 2 requires you to type REBUILD unless --yes is passed. Use --skip-terraform
# to re-bootstrap ArgoCD + secrets on an EXISTING cluster without touching it.
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
# Step 1 verifies tfvars matches this target and aborts if it does not.
#
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO}/terraform"

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

# Node wow= labels, lost on every rebuild. master -> medivh; the workers, sorted
# by their Magnum-generated name (...-node-0..3), -> arthas, bolvar, cairne, draka.
MASTER_WOW="medivh"
WORKER_WOW=(arthas bolvar cairne draka)

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
ASSUME_YES=0
SKIP_TERRAFORM=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y)        ASSUME_YES=1 ;;
    --skip-terraform) SKIP_TERRAFORM=1 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      echo
      echo "Usage: ./scripts/bootstrap.sh [--yes] [--skip-terraform]"
      echo "  --yes             skip the typed REBUILD confirmation"
      echo "  --skip-terraform  leave the cluster alone; only (re)bootstrap ArgoCD + secrets"
      exit 0 ;;
    *) echo "Unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Logging helpers (match scripts/start-here.sh)
# ---------------------------------------------------------------------------
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
info() { printf '  \033[90m·\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
die()  { printf '\n\033[31mABORT:\033[0m %s\n' "$1" >&2; exit 1; }

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
# 1. PREFLIGHT
# ============================================================================
step "1. Preflight"

# Reuse the whole start-here.sh chain as the gate: tools, env.sh, Kerberos ticket,
# Keystone auth+project, cluster template still exists, cores quota, keypair, and
# current cluster status. It exits non-zero with an exact fix if anything is off.
info "running scripts/start-here.sh --check (reused preflight chain)..."
if ! "${REPO}/scripts/start-here.sh" --check; then
  die "start-here.sh preflight failed — fix the item it printed above, then re-run."
fi
ok "start-here.sh preflight passed"

# Things start-here.sh does not check but this script needs.
command -v kubectl >/dev/null 2>&1 || die "kubectl not found (needed for ArgoCD, secrets, labels)."
ok "kubectl present"

if command -v tbag >/dev/null 2>&1; then
  ok "tbag present (secrets will be pulled from hostgroup ${HG})"
else
  warn "tbag not found — you are not on an itdcim/avtools host."
  warn "Secrets will fall back to env vars; see step 7 messages."
fi

# tfvars MUST be the target rebuild topology (the gitignored file the script applies).
if [ "$SKIP_TERRAFORM" -eq 0 ]; then
  errs=0
  check_tfvar() {
    local name="$1" want="$2" got; got="$(tfvar "$name")"
    if [ "$got" = "$want" ]; then ok "tfvars ${name} = ${got}"
    else bad "tfvars ${name} = '${got}', expected '${want}'"; errs=1; fi
  }
  check_tfvar master_flavor m2.large
  check_tfvar flavor        m2.large
  check_tfvar node_count    4
  check_tfvar autoscale_min 4
  check_tfvar autoscale_max 4
  if [ "$errs" -ne 0 ]; then
    die "terraform/terraform.tfvars is not set to the rebuild target. Set the values
       listed at the top of this script (4x m2.large workers, m2.large master,
       autoscale 4), then re-run. (Pass --skip-terraform to bootstrap ArgoCD +
       secrets on the EXISTING cluster without a rebuild.)"
  fi
else
  info "--skip-terraform: not validating tfvars; the running cluster is left untouched."
fi

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
# 3. OPENSTACK AUTH  (Kerberos -> OS_TOKEN)
# ============================================================================
step "3. OpenStack auth"

# shellcheck source=/dev/null
source "${REPO}/scripts/os-auth.sh" || die "OpenStack auth failed — see scripts/os-auth.sh."

# ============================================================================
# 4. TERRAFORM APPLY  (the flavor/count target forces a full cluster replace)
# ============================================================================
step "4. Terraform apply"

if [ "$SKIP_TERRAFORM" -eq 1 ]; then
  info "--skip-terraform: skipping. Using whatever cluster is already up."
else
  # env.sh holds CERN_USER / GITLAB_ACCESS_TOKEN / PROJECT_ID for the GitLab state backend.
  # shellcheck source=/dev/null
  source "${REPO}/scripts/env.sh"
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
# 5. KUBECONFIG
# ============================================================================
step "5. Kubeconfig"

mkdir -p "$KUBECONFIG_DIR"
# --force overwrites any stale config from a previous cluster => idempotent/re-runnable.
openstack coe cluster config --dir "$KUBECONFIG_DIR" --force "$(cluster_name)" >/dev/null
export KUBECONFIG="${KUBECONFIG_DIR}/config"
kubectl cluster-info >/dev/null 2>&1 || die "kubeconfig written but kubectl cannot reach the API server."
ok "KUBECONFIG=${KUBECONFIG} ($(kubectl get nodes --no-headers 2>/dev/null | wc -l) nodes)"

# ============================================================================
# 6. ARGOCD  (install core; server-side apply — the big CRDs blow the client-side
#    annotation limit; this is the known gotcha in the runbook)
# ============================================================================
step "6. ArgoCD (core install)"

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
# 7. SECRETS  (all 3, from tbag — no manual paste)
#    a) ArgoCD private-repo deploy token   -> ns argocd  (before app-of-apps syncs)
#    b) app secrets (sync-secret.sh)        -> ns avtools-qa
#    c) Harbor image pull secret            -> ns avtools-qa
# ============================================================================
step "7. Secrets (from tbag)"

# --- a) ArgoCD repo deploy token -------------------------------------------------
repo_user="$(tbag_or_env argocd_repo_user ARGOCD_REPO_USER)"
repo_token="$(tbag_or_env argocd_repo_token ARGOCD_REPO_TOKEN)"
if [ -n "$repo_user" ] && [ -n "$repo_token" ]; then
  # Declarative repo credential: an Opaque Secret labelled for ArgoCD to consume.
  # create|apply keeps the token off stdout; the label is added out-of-band.
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
# 8. GITOPS  (apply the app-of-apps root — deferred until after secrets so the
#    first sync already finds repo creds + pull secret + app secret in place)
# ============================================================================
step "8. GitOps (app-of-apps)"

kubectl apply -n argocd --server-side --force-conflicts -f "${REPO}/argocd/app-of-apps.yaml" >/dev/null
ok "avtools-root applied — ArgoCD now reconciles AppProject + ApplicationSet (qa) + kube-prometheus-stack"

# ============================================================================
# 9. NODE LABELS  (the wow= scheme, lost on rebuild)
# ============================================================================
step "9. Node labels (wow=)"

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
# 10. WAIT + VERIFY
# ============================================================================
step "10. Wait + verify"

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
