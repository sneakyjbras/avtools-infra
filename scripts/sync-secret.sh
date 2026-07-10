#!/usr/bin/env bash
#
# Bridge AV Tools secrets from Teigi/tbag (hostgroup itdcim/avtools) into a
# native Kubernetes Secret so the sharded CronJobs can read them.
#
# tbag stays the SINGLE source of truth. This script pushes the SAME live values
# the monolith reads via Puppet into secret/avtools-secrets. Nothing is stored in
# git; values never hit stdout. Rotate a key = update tbag, re-run this script.
#
# Run it from a host that is a member of hostgroup itdcim/avtools (the monolith
# host is ideal during the overlap) with a kubeconfig for the Magnum cluster.
#
# Requires: tbag (Teigi CLI) + kubectl.
#
#   ./sync-secret.sh                 # qa   -> namespace avtools-qa
#   AVTOOLS_ENVIRONMENT=prod ./sync-secret.sh
#
# tbag key mapping mirrors code/manifests/avtools.pp:
#   qa   : database_url_qa, eam_qa_pwd, landb_qa_pwd
#   prod : database_url,    eam_pwd,    landb_pwd
#   both : monit_pwd, avtools_logs_pwd
#
set -euo pipefail

HG="${AVTOOLS_TBAG_HG:-itdcim/avtools}"
ENVIRONMENT="${AVTOOLS_ENVIRONMENT:-qa}"
NAMESPACE="${K8S_NAMESPACE:-avtools-${ENVIRONMENT}}"
SECRET_NAME="${SECRET_NAME:-avtools-secrets}"

case "$ENVIRONMENT" in
  qa)   db_key="database_url_qa"; eam_key="eam_qa_pwd"; landb_key="landb_qa_pwd" ;; # pragma: allowlist secret
  prod) db_key="database_url";    eam_key="eam_pwd";    landb_key="landb_pwd" ;; # pragma: allowlist secret
  *) echo "ERROR: AVTOOLS_ENVIRONMENT must be qa or prod (got '$ENVIRONMENT')." >&2; exit 2 ;;
esac

echo "Reading secrets from tbag (hg=${HG}, env=${ENVIRONMENT})..." >&2
read_key() { tbag show "$1" --hg "$HG" --plain; }

db_url="$(read_key "$db_key")"
monit_pwd="$(read_key monit_pwd)"
eam_pwd="$(read_key "$eam_key")"
landb_secret="$(read_key "$landb_key")"
# Optional keys (don't fail if not yet provisioned).
logs_pwd="$(read_key avtools_logs_pwd 2>/dev/null || true)"

for pair in "DATABASE_URL:$db_url" "MONIT_PASSWORD:$monit_pwd" "MY_PASSWORD:$eam_pwd" "LANDB_CLIENT_SECRET:$landb_secret"; do # pragma: allowlist secret
  if [[ -z "${pair#*:}" ]]; then
    echo "ERROR: tbag returned empty for ${pair%%:*}; refusing to write an incomplete secret." >&2
    exit 1
  fi
done

args=(
  --from-literal=DATABASE_URL="$db_url"
  --from-literal=MONIT_PASSWORD="$monit_pwd"
  --from-literal=MY_PASSWORD="$eam_pwd"
  --from-literal=LANDB_CLIENT_SECRET="$landb_secret"
)
[[ -n "$logs_pwd" ]] && args+=(--from-literal=AVTOOLS_LOGS_PWD="$logs_pwd")
# SENTRY_DSN is issued by IT-PW (not tbag); pass it in the environment to include it.
[[ -n "${SENTRY_DSN:-}" ]] && args+=(--from-literal=SENTRY_DSN="$SENTRY_DSN")

echo "Applying secret/${SECRET_NAME} to namespace ${NAMESPACE}..." >&2
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# create --dry-run | apply => idempotent upsert without echoing values to stdout
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  "${args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

echo "Done. secret/${SECRET_NAME} in ${NAMESPACE} is in sync with tbag (${HG})." >&2
