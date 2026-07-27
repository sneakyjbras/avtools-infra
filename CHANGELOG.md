# Changelog

All notable changes to **av-tools-infra** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- **Maintainer & Contribution update**: Added `CONTRIBUTING.md` and updated `chart/Chart.yaml` to set José Bras (`jose.bras@cern.ch` / `j.eduardo.bras@outlook.com`, `@jsapinat` / `@sneakyjbras`) as sole maintainer under the MIT License.

## [0.2.0] — 2026-07-27

### Added
- **`sync-rooms` CronJob**: Helm chart update adding the `eam_rooms` synchronization job.
- **ArgoCD QA tracking**: Configured ArgoCD QA namespace tracking.
