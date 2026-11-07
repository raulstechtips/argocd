# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Move Argo CD out of [cluster-config](https://github.com/raulstechtips/cluster-config) into this standalone repo, which manages the Argo CD chart ([DEVSECOPS-54](https://raulstechtips.atlassian.net/browse/DEVSECOPS-54)).

### Changed

- Build with the Jenkins shared library (`Jenkinsfile`, `project-pipeline-config.yaml`) and keep the GitHub Actions `main` workflow as a manual backup ([DEVSECOPS-34](https://raulstechtips.atlassian.net/browse/DEVSECOPS-34)).

### Fixed

- Argo CD now manages `v1/Endpoints`: `resource.exclusions` keeps the chart defaults but no longer excludes Endpoints, so the static Endpoints of selector-less Services (Traefik external services) are created on a new cluster. EndpointSlice stays excluded ([DEVSECOPS-60](https://raulstechtips.atlassian.net/browse/DEVSECOPS-60)).

[Unreleased]: https://github.com/raulstechtips/argocd/commits/main
