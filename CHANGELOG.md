# Changelog

All notable changes to **av-tools-infra** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] — 2026-07-28

### Changed
- **`snmp-timeseries` split into 4 priority tiers**: replaced the single `snmp-timeseries` (`*/5`) CronJob with four — `snmp-critical`, `snmp-high`, `snmp-medium`, `snmp-low` — each invoking the new `avtools snmp-timeseries --priority {critical,high,medium,low}` flag shipped on the `qa` branch of the code repo. This is a **publish-filter** (phase 1): every tier still runs a full fleet SNMP/ping sweep (collects everything, unchanged cost) and only *publishes* its tier's series to MONIT. It trades spare, I/O-bound/low-CPU SNMP capacity (which we have headroom on) to cut the scarce MONIT OTLP ingest rate, by letting less-urgent metrics publish less frequently instead of every 5 minutes.
- **Schedules, staggered to avoid cross-job collisions**: `snmp-critical` keeps the original `*/5` offset (unchanged from `snmp-timeseries`, so it still coincides with `run-eam`/`run-landb` as before — not a regression); `snmp-high` runs `3-59/15 * * * *` (:03/:18/:33/:48); `snmp-medium` runs `7 * * * *` (:07 hourly); `snmp-low` runs `11 */6 * * *` (:11 every 6h). The +3/+7/+11 minute offsets keep the new tiers off the existing `*/5` (`run-eam`/`run-landb`) and `*/15` (`sync-rooms`) grids entirely, so at most one job type fires per minute tick instead of stacking concurrent OTLP flush bursts — the confirmed cause of past MONIT ingest gaps — and spiking node pod count.
- **Chart.yaml**: version `0.2.0` → `0.3.0`; `appVersion` → `1.11.0` (cosmetic — the image uses moving `qa`/`prod` tags — tracking the avtools code release that added `--priority`); description updated to list the 4 tiered jobs instead of the retired `snmp-timeseries`.
- **`snmp-critical`** mirrors the old `snmp-timeseries` sizing (8 shards × 16 threads, `activeDeadlineSeconds: 150`) since it's the most frequent tier and freshness-sensitive. **`snmp-high`/`snmp-medium`/`snmp-low`** ship with smaller **placeholder** shard/thread counts (4/16, 4/8, 2/4 respectively) and correspondingly larger `activeDeadlineSeconds` (220/320/600) — explicitly TBD pending the G0 cardinality measurement and observed per-tier sweep time, not tuned values.
- `chart/templates/NOTES.txt`: post-install "trigger one run" example now points at `snmp-critical` instead of the retired `snmp-timeseries`.
- **Maintainer & Contribution update**: Added `CONTRIBUTING.md` and updated `chart/Chart.yaml` to set José Bras (`jose.bras@cern.ch` / `j.eduardo.bras@outlook.com`, `@jsapinat` / `@sneakyjbras`) as sole maintainer under the MIT License.

### Unchanged
- `run-eam`, `run-landb`, and `sync-rooms` CronJobs are untouched by this release.

## [0.2.0] — 2026-07-27

### Added
- **`sync-rooms` CronJob**: Helm chart update adding the `eam_rooms` synchronization job.
- **ArgoCD QA tracking**: Configured ArgoCD QA namespace tracking.
