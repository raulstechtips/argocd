# argocd

This repository contains the Helm chart that installs Argo CD in the cluster.

## 1. Purpose

The chart wraps the upstream `argo-cd` Helm chart as a dependency.
The chart also adds our own resources: the envsubst CMP plugin, the registry secrets from Infisical, and a Traefik IngressRoute.
Each push to a valid branch publishes a chart version to GHCR.
Argo CD then installs the chart from this OCI address:

```
oci://ghcr.io/raulstechtips/charts/argocd
```

## 2. Repository layout

| Path | Contents |
| --- | --- |
| `charts/` | The Helm chart. `Chart.yaml`, `Chart.lock`, `values.yaml` and `values.schema.json`. |
| `charts/templates/` | Our own templates: `external-registry-secrets.yaml` and `ingressroute.yaml`. |
| `charts/templates/envsubst/` | The envsubst CMP plugin resources. This directory is temporary. Section 11 tells you how to remove it. |
| `charts/tests/` | The helm-unittest test files (`*_test.yaml`). |
| `charts/ci/` | Values files for CI. `all-on-values.yaml` turns on all features with fake values. |
| `.github/workflows/` | `release.yaml` tests, versions and publishes the chart. `retention.yaml` deletes old branch versions. |
| `scripts/` | Shell scripts for the workflows. `retention.sh` contains the retention logic. |

## 3. Values layout

The values file has two parts.

1. Upstream values go under the `argo-cd:` key. The upstream chart reads them. Refer to the upstream `argo-cd` chart for the available keys.
2. Our own resources are top-level keys. Each resource has an `enabled` switch or an empty list. All are off by default.

| Key | Default | What it makes | Required values when on |
| --- | --- | --- | --- |
| `envsubst.enabled` | `false` | The CMP plugin ConfigMap, its RBAC and its InfisicalSecrets. | `envsubst.infisical.hostAPI`, `envsubst.infisical.projectSlug`, `envsubst.infisical.envSlug` |
| `infisical` | `projectSlug: ""` | The Infisical connection for `externalRegistrySecrets`. | `infisical.projectSlug` |
| `externalRegistrySecrets` | `[]` | One InfisicalStaticSecret for each list entry. | `name`, `environmentSlug`, `secretPath`, `url`, `usernameKey`, `passwordKey` |
| `ingressRoute.enabled` | `false` | One Traefik IngressRoute for `argocd-server`. | `ingressRoute.host`, `ingressRoute.tlsSecretName` |

Example values file. All values are examples:

```yaml
argo-cd:
  server:
    replicas: 2

envsubst:
  enabled: true
  infisical:
    hostAPI: https://infisical.example.test/api
    projectSlug: example
    envSlug: dev

infisical:
  projectSlug: example

externalRegistrySecrets:
  - name: example-registry
    environmentSlug: dev
    secretPath: /registry
    url: registry.example.test
    usernameKey: USERNAME
    passwordKey: PASSWORD

ingressRoute:
  enabled: true
  host: argocd.example.test
  tlsSecretName: example-tls
```

If you turn on a resource and you do not set a required value, `helm template` stops with an error message.

## 4. Branch rule

The workflow runs only for pushes to `main` and to branches that start with `feature/`, `bugfix/`, `hotfix/` or `release/`.
Other branches get no CI run.
Each branch other than `main` must match this regular expression:

```
^(feature|bugfix|hotfix|release)/([A-Z][A-Z0-9]*-[0-9]+)(-.*)?$
```

The format is `<type>/<KEY>-<number>[-text]`.

- `<type>` is one of these four words: `feature`, `bugfix`, `hotfix`, `release`.
- `<KEY>-<number>` is the ticket key in uppercase.
- `-text` is optional.

| Branch | Result | Reason |
| --- | --- | --- |
| `feature/DEVSECOPS-54-argocd-chart` | Good | Type, key and text are correct. |
| `bugfix/OPS-7` | Good | Text is optional. |
| `hotfix/DEVSECOPS-12-fix` | Good | Type, key and text are correct. |
| `release/DEVSECOPS-60` | Good | Text is optional. |
| `spike/OPS-7` | Bad | The type is not one of the four allowed types. |
| `feature/no-key` | Bad | The branch has no ticket key. |
| `Feature/DEVSECOPS-1` | Bad | The type has an uppercase letter. |

If the branch starts with an allowed type but the name is bad, the `version` job fails with this message:

```
Branch "<name>" must be <type>/<KEY>-<number>[-text]. The type must be feature, bugfix, hotfix or release. Example: feature/DEVSECOPS-54-argocd-chart.
```

To fix the name, rename the branch. Then push the branch again:

```bash
git branch -m feature/DEVSECOPS-54-argocd-chart
git push -u origin feature/DEVSECOPS-54-argocd-chart
```

## 5. Version format

The workflow makes the chart version. Do not write it into git.

| Branch | Format | Example |
| --- | --- | --- |
| Other branch | `X.Y.Z-<type>-<lowercase key>-<sha7>-<run#>` | `3.0.0-feature-devsecops-54-abc1234-12` |
| `main` | `X.Y.Z-main-<sha7>-<run#>` | `3.0.0-main-abc1234-13` |

- `X.Y.Z` is the `version` field in `charts/Chart.yaml`.
- `<sha7>` is the first 7 characters of the commit SHA.
- `<run#>` is the GitHub Actions run number.

## 6. Version bump rule

You must increase `X.Y.Z` only when you change files under `charts/`.
A change to other files, for example this README, does not need a bump.

When `charts/` changes, `X.Y.Z` in `charts/Chart.yaml` must be higher than the highest `main` release in GHCR.
The workflow finds the highest `main` release from the tags that match `X.Y.Z-main-<sha7>-<run#>`.
Branch builds do not count.

Do these steps when you change `charts/`:

1. Find the highest main release:

   ```bash
   oras repo tags ghcr.io/raulstechtips/charts/argocd | grep -E '^[0-9]+\.[0-9]+\.[0-9]+-main-[0-9a-f]{7}-[0-9]+$' | sort -V | tail -n 1
   ```

   Example result: `3.0.0-main-abc1234-13`.
2. Open `charts/Chart.yaml`.
3. Set `version` to a higher value. Example: `3.0.1`.
4. Commit the change.
5. Push the commit.

If the version is not higher, the `version` job fails with this message:

```
Raise version in charts/Chart.yaml above <latest>
```

## 7. Publish

Each push to a valid branch publishes one chart version to:

```
oci://ghcr.io/raulstechtips/charts/argocd
```

The `publish` job runs only when the `version` and `test` jobs pass.
The job summary shows the full chart address and version.

### 7.1 Render a branch build

1. Open the workflow run in GitHub Actions.
2. Open the `publish` job summary.
3. Copy the version. Example: `3.0.0-feature-devsecops-54-abc1234-12`.
4. Log in to GHCR if the package is private:

   ```bash
   echo "$GITHUB_TOKEN" | helm registry login ghcr.io -u <github-user> --password-stdin
   ```

5. Render the chart with your values file:

   ```bash
   helm template argocd oci://ghcr.io/raulstechtips/charts/argocd --version <version> -n argocd -f <values>
   ```

Expected result: Helm writes the Kubernetes manifests to standard output. Helm shows no error.

## 8. Local tests

Run these tests before you push. The `test` job in CI runs the same commands.

### 8.1 Tools

| Tool | Version |
| --- | --- |
| Helm | 3.x |
| helm-unittest plugin | 0.3.1 |
| kubeconform | 0.6.7 |
| actionlint | 1.7.12 |
| ShellCheck | 0.11.0 or newer |

Install the plugin one time:

```bash
helm plugin install https://github.com/helm-unittest/helm-unittest --version 0.3.1
```

Make sure that the plugin is installed:

```bash
helm plugin list
```

Expected result: the list shows `unittest` with version `0.3.1`.

Install kubeconform and actionlint one time.
Each command downloads a pinned release and checks its SHA-256 value before it unpacks the file.
Use the Linux values on Linux (amd64) and the macOS values on macOS (Apple silicon):

```bash
mkdir -p "$HOME/.local/bin"
TMP="$(mktemp -d)"

# Linux amd64
curl -fsSL -o "$TMP/kubeconform.tar.gz" https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-linux-amd64.tar.gz
echo "95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73  $TMP/kubeconform.tar.gz" | shasum -a 256 -c -
curl -fsSL -o "$TMP/actionlint.tar.gz" https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz
echo "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  $TMP/actionlint.tar.gz" | shasum -a 256 -c -

# macOS arm64
curl -fsSL -o "$TMP/kubeconform.tar.gz" https://github.com/yannh/kubeconform/releases/download/v0.6.7/kubeconform-darwin-arm64.tar.gz
echo "cbb47d938a8d18eb5f79cb33663b2cecdee0c8ac0bf562ebcfca903df5f0802f  $TMP/kubeconform.tar.gz" | shasum -a 256 -c -
curl -fsSL -o "$TMP/actionlint.tar.gz" https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_darwin_arm64.tar.gz
echo "aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f  $TMP/actionlint.tar.gz" | shasum -a 256 -c -

tar -xzf "$TMP/kubeconform.tar.gz" -C "$HOME/.local/bin" kubeconform
tar -xzf "$TMP/actionlint.tar.gz" -C "$HOME/.local/bin" actionlint
rm -rf "$TMP"
```

Expected result: each `shasum` line ends with `OK`. If a line shows `FAILED`, delete the file and do not use it.
Make sure that `$HOME/.local/bin` is in your `PATH`.

Install ShellCheck. The ShellCheck project does not publish checksum files, so use your package manager:

```bash
brew install shellcheck          # macOS
sudo apt-get install -y shellcheck   # Debian and Ubuntu
```

Make sure that the tools are installed:

```bash
kubeconform -v
actionlint -version
shellcheck --version
```

Expected result: the versions are `v0.6.7`, `1.7.12` and `0.11.0` or newer.

### 8.2 Commands

Run each command from the repository root.

1. Add the Argo Helm repository:

   ```bash
   helm repo add argo https://argoproj.github.io/argo-helm
   ```

   Expected result: `"argo" has been added to your repositories`.

2. Download the chart dependencies:

   ```bash
   helm dependency build charts
   ```

   Expected result: Helm writes the `argo-cd` package to `charts/charts/`. The command exits with code 0.

3. Lint the chart with the default values:

   ```bash
   helm lint --strict charts
   ```

   Expected result: `1 chart(s) linted, 0 chart(s) failed`.

4. Lint the chart with all features on:

   ```bash
   helm lint --strict charts -f charts/ci/all-on-values.yaml
   ```

   Expected result: `1 chart(s) linted, 0 chart(s) failed`.

5. Run the unit tests:

   ```bash
   helm unittest charts
   ```

   Expected result: the summary lines `Test Suites:` and `Tests:` show only `passed` values. Example: `Tests: 16 passed, 16 total`.

6. Render the chart with all features on:

   ```bash
   helm template argocd charts -n argocd -f charts/ci/all-on-values.yaml > rendered.yaml
   ```

   Expected result: the command exits with code 0 and `rendered.yaml` contains the manifests. Do not commit `rendered.yaml`.

7. Check the rendered manifests against the Kubernetes schemas:

   ```bash
   kubeconform -strict -summary -schema-location default -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -skip InfisicalSecret,InfisicalStaticSecret,apiextensions.k8s.io/v1/CustomResourceDefinition rendered.yaml
   ```

   Expected result: the summary shows `Invalid: 0, Errors: 0` and the command exits with code 0.
   The skip list is necessary because no public schema exists for these kinds. The check does not validate the Infisical resources and the three Argo CD CustomResourceDefinitions.

8. Check the workflow files:

   ```bash
   actionlint .github/workflows/*.yaml
   ```

   Expected result: actionlint prints no output and exits with code 0. When ShellCheck is in your `PATH`, actionlint also checks the shell code inside the workflows.

9. Check the shell scripts:

   ```bash
   shellcheck scripts/*.sh test/*.sh
   ```

   Expected result: ShellCheck prints no output and exits with code 0.

### 8.3 Trivy

CI scans `rendered.yaml` with Trivy for HIGH and CRITICAL misconfigurations.
The Trivy step runs with `exit-code: 0`. Findings show as warnings and never fail the release.
The job summary shows the Trivy table and a warning with the number of findings.
Read the findings. Fix them when you can.

## 9. Retention

The `retention` workflow runs one time each day.

| Version type | Rule |
| --- | --- |
| Branch version older than 7 days | Deleted. |
| Branch version 7 days old or newer | Kept. |
| `main` version (`X.Y.Z-main-<sha7>-<run#>`) | Always kept. |
| Untagged version | Kept. The job writes a notice. |

CI lints and tests the retention scripts: `shellcheck scripts/*.sh test/*.sh`, `actionlint .github/workflows/*.yaml` and `bash test/retention_test.sh` run in the `test` job of `release.yaml`.
The `retention` workflow also runs `bash test/retention_test.sh` first. A failed test stops the run before any delete.
Only the scheduled run and a manual run with `dry_run` set to `false` get `packages: write`. All other runs get `packages: read`.

A push that changes `retention.yaml` or `scripts/retention.sh` runs the job in dry-run mode only.
To run the job by hand, open **Actions > retention > Run workflow**. The `dry_run` input is `true` by default.

## 10. Operator note: GHCR package settings

Do these steps one time, after the first push creates the package.

1. In GitHub, open your profile.
2. Click **Packages**.
3. Click the package `charts/argocd`.
4. Click **Package settings**.
5. In **Manage Actions access**, click **Add Repository**.
6. Select this repository.
7. Set the role to **Admin**. The retention job needs Admin access to delete versions.
8. In **Danger Zone**, click **Change visibility**.
9. Select **Private** or **Public**, as necessary.

Expected result: the package page shows this repository under **Manage Actions access** with the role **Admin**.

## 11. Remove the envsubst plugin

The envsubst plugin is temporary. Do these steps in this sequence.

### Step 1: cluster-config repository

1. Open `apps/dev/argocd.yaml`.
2. Delete the line `envsubst.enabled: true`.
3. Delete the sidecar block.
4. Open a pull request.
5. Merge the pull request.
6. Make sure that Argo CD syncs the `argocd` Application without errors.

Rollback: revert that pull request.

### Step 2: this repository

1. Delete the directory `charts/templates/envsubst/`.
2. Delete the `envsubst` block from `charts/values.yaml`, `charts/values.schema.json` and `charts/ci/all-on-values.yaml`.
3. Delete `charts/tests/envsubst_test.yaml`.
4. Increase `version` in `charts/Chart.yaml` (see section 6).
5. Run the local tests (see section 8).
6. Push the branch.
7. Merge the pull request. The workflow releases a new chart version.
