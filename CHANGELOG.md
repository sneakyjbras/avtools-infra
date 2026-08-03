# Changelog

All notable changes to **av-tools-infra** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Fluent Bit retargeted from container-log tailing to Kubernetes Event collection.** The `chart/templates/fluent-bit.yaml` shipper (still disabled by default) previously guessed a `tail` INPUT over `/var/log/containers/*_<namespace>_*.log`, written before MonIT confirmed the transport. Two things ruled that design out: CERN's own `cern-magnum-fluentd` DaemonSet already tails every node's container logs to central MonIT (a duplicate collector), and avtools' own stdout is ANSI-coloured console text, not JSON, so tailing it would ship nothing parseable anyway. Application logs are unaffected — they ship as their own direct-OTLP pipeline from the avtools process, not through this shipper. This chart's Fluent Bit now collects **Kubernetes Event objects** instead (pod deadline kills, OOM kills, `ImagePullBackOff`, evictions, failed Jobs, ArgoCD syncs) via the `kubernetes_events` input, verified against the pinned `cr.fluentbit.io/fluent/fluent-bit:3.1.9` image (source at tag `v3.1.9` + `strings` on the extracted binary).
- **DaemonSet → Deployment (`replicas: 1`).** `kubernetes_events` polls/watches the API server rather than per-node log files, so a single pod already sees every event in the namespace; the old DaemonSet shape would have shipped every event once per node (5×).
- **RBAC narrowed:** the `ClusterRole` (originally `pods`/`namespaces` `get/list/watch`, for the retired `kubernetes` FILTER plugin's log enrichment) is replaced by a namespaced `Role`/`RoleBinding` granting `get/list/watch` on `events` (`""`) and `events.k8s.io`, scoped to the release's own namespace — least privilege, since `Kube_Namespace` scoping means the plugin only ever queries the namespaced Events endpoint.
- **Output fixed to the verified transport:** OTLP/HTTP to `monit-otlp.cern.ch:4319` (the only TLS-capable OTLP port; the gRPC ports support no TLS at all, and :4318 is the same endpoint in plaintext) with the CERN Grid CA chain — now bundled at `chart/files/cern-chain.pem` (both public CA certificates) and mounted via a configurable ConfigMap/path/key (`fluentBit.caBundle`), rather than disabling TLS verification. Removed the stale `TODO(verify)` markers.
- **Credential fixed:** the separate `AVTOOLS_LOGS_PWD` / `avtools_logs_pwd` key is retired from the chart, `secrets/secret.example.yaml`, and `scripts/sync-secret.sh` — MonIT confirmed logs and metrics share the same OTLP endpoint and password, so the existing `MONIT_PASSWORD` secret key (already used by every CronJob) is reused instead.
- **Index name corrected:** `monit-logs-ss4o_avtools`, not the `otel-logs_avtools` name previously documented in this repo's comments.
- Every shipped event now carries `service.name`, `deployment.environment`, and `k8s.namespace.name`, and uses the Event's own `message` field as the OTLP log body — filterable alongside application logs in the same index.
- `values-qa.yaml` / `values-prod.yaml` each get their own `fluentBit.enabled` switch (default `false`) so QA and PROD can be turned on independently.

## [0.3.0] — 2026-07-28

### Changed
- **`snmp-timeseries` split into 4 priority tiers**: replaced the single `snmp-timeseries` (`*/5`) CronJob with four — `snmp-critical`, `snmp-high`, `snmp-medium`, `snmp-low` — each invoking the new `avtools snmp-timeseries --priority {critical,high,medium,low}` flag shipped on the `qa` branch of the code repo. This is a **publish-filter** (phase 1): every tier still runs a full fleet SNMP/ping sweep (collects everything, unchanged cost) and only *publishes* its tier's series to MONIT. It trades spare, I/O-bound/low-CPU SNMP capacity (which we have headroom on) to cut the scarce MONIT OTLP ingest rate, by letting less-urgent metrics publish less frequently instead of every 5 minutes.
- **Schedules, staggered to avoid cross-job collisions**: `snmp-critical` keeps the original `*/5` offset (unchanged from `snmp-timeseries`, so it still coincides with `run-eam`/`run-landb` as before — not a regression); `snmp-high` runs `3-59/15 * * * *` (:03/:18/:33/:48); `snmp-medium` runs `7 * * * *` (:07 hourly); `snmp-low` runs `11 */6 * * *` (:11 every 6h). The +3/+7/+11 minute offsets keep the new tiers off the existing `*/5` (`run-eam`/`run-landb`) and `*/15` (`sync-rooms`) grids entirely, so at most one job type fires per minute tick instead of stacking concurrent OTLP flush bursts — the confirmed cause of past MONIT ingest gaps — and spiking node pod count.
- **Chart.yaml**: version `0.2.0` → `0.3.0`; `appVersion` → `1.11.1` (cosmetic — the image uses moving `qa`/`prod` tags — tracking the avtools release that added `--priority` plus the per-outlet current/power HIGH-tier reclassification); description updated to list the 4 tiered jobs instead of the retired `snmp-timeseries`.
- **`snmp-critical`** mirrors the old `snmp-timeseries` sizing (8 shards × 16 threads, `activeDeadlineSeconds: 150`) since it's the most frequent tier and freshness-sensitive. **`snmp-high`/`snmp-medium`/`snmp-low`** run at 4×16, 4×8 and 2×8 with `activeDeadlineSeconds` 220/320/1200.
- **`snmp-low` resized 2×4 → 2×8 (deadline 600 → 1200) before it ever ran.** At 4 threads it put 1375/2/4 = 172 devices on every thread, 16× the per-thread load of `snmp-critical`. Extrapolating linearly from critical's measured ~40s put the sweep at ~640s — past its own 600s `activeDeadlineSeconds`, i.e. killed mid-sweep every run. (The real figure turned out to be ~307s: the sweep has a ~24s fixed overhead, so the pure-linear extrapolation was ~2× pessimistic and the resize was precautionary rather than strictly necessary. The extra headroom is harmless and the 6h cadence makes a slower sweep free.)

### Measured

- **G0, from a 15-hour QA soak (2026-07-31)** — the per-tier figures the placeholders were pending. Sweep durations: critical ~43s, high ~60s, medium ~91s, low ~167s, against deadlines of 150/220/320/1200s (3.5×–7× headroom). Publish rate: critical 3,031 samples/cycle × 12/h, high 1,442 × 4/h, medium 657 × 1/h, low 444 × 1/6h = **42,871 samples/hr, down from 66,204 untiered — a 35% MONIT ingest reduction** with availability signals still refreshing every 5 minutes. The four tiers' sample counts sum to the untiered cycle total (5,574 vs 5,517), confirming the split partitions the same data rather than dropping any. Sizing model refit on this data: `duration ≈ 24s + 1.65 × (devices ÷ threads)`, accurate to within 6% across all four tiers.
- `chart/templates/NOTES.txt`: post-install "trigger one run" example now points at `snmp-critical` instead of the retired `snmp-timeseries`.
- **Maintainer & Contribution update**: Added `CONTRIBUTING.md` and updated `chart/Chart.yaml` to set José Bras (`jose.bras@cern.ch` / `j.eduardo.bras@outlook.com`, `@jsapinat` / `@sneakyjbras`) as sole maintainer under the MIT License.

### Unchanged
- `run-eam`, `run-landb`, and `sync-rooms` CronJobs are untouched by this release.

## [0.2.0] — 2026-07-27

### Added
- **`sync-rooms` CronJob**: Helm chart update adding the `eam_rooms` synchronization job.
- **ArgoCD QA tracking**: Configured ArgoCD QA namespace tracking.
