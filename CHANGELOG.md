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

[Unreleased]: https://github.com/raulstechtips/argocd/commits/main
