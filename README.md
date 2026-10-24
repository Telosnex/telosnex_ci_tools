# telosnex_ci_tools

The shared GitHub Actions workflows, composite actions and CI conventions of the Telosnex repositories.

## Contents

| Path | Kind | What it does |
|---|---|---|
| `actions/setup-flutter` | Composite action | Installs Flutter from a shallow clone of its tag. The default version is in `flutter_version.txt`. |
| `actions/check-clean-tree` | Composite action | Fails if the checkout has untracked or changed files. |
| `actions/prebuilt-build` | Composite action | Describes the toolchain and runs `<package>:build` for one target. |
| `.github/workflows/prebuilt_release.yml` | Reusable workflow | Builds, tests and publishes the prebuilt native and web files of a package. |
| `.github/workflows/prebuilt_check.yml` | Reusable workflow | Runs `<package>:check`. |
| `bin/lint.dart` | Dart CLI | Checks the workflow files of a repository against the conventions. |
| `bin/pin_self.dart` | Dart CLI | Pins the references from the workflows to the actions of this repository. |
| `default.json` | Renovate preset | Keeps the pinned actions current. |

## Conventions

`dart run telosnex_ci_tools:lint <repository...>` checks these rules:

| Rule | Requirement |
|---|---|
| `file-name` | The workflow file names are in snake_case and end with `.yml`. |
| `name` | The workflow `name:` is in sentence case. `Native release`, not `native release` or `Native Release`. |
| `name-matches-file` | The `name:` is the file name in sentence case. `native_release.yml` is `Native release`. Acronyms such as `CUDA` can be in capitals. |
| `permissions` | Each workflow sets the top-level `permissions`. |
| `timeout` | Each job sets `timeout-minutes`. |
| `pinned-uses` | Each `uses:` names a full commit SHA, then a version comment: `@<sha> # v7.0.1`. |
| `setup-flutter` | Jobs install Flutter with `actions/setup-flutter`. |
| `shared-concurrency` | A caller of a shared workflow does not set `concurrency`. The same group in the caller and in the shared workflow deadlocks. |

## Call a shared workflow

The caller has the triggers, the `run-name` and the package-specific values. The shared workflow has the jobs. This is the prebuilt release of fonnx, `.github/workflows/prebuilt_release.yml`:

```yaml
name: Prebuilt release
run-name: Prebuilt release / ${{ (github.ref_name == 'prebuilt-release-dry' || inputs.dry_run) && 'build only' || 'publish' }}

on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: Build only, upload nothing.
        type: boolean
        default: false
  push:
    branches: [prebuilt-release, prebuilt-release-dry]

permissions:
  contents: read

jobs:
  prebuilt-release:
    uses: Telosnex/telosnex_ci_tools/.github/workflows/prebuilt_release.yml@<sha> # v0.1.0
    permissions:
      contents: write
    with:
      dry-run: ${{ inputs.dry_run == true }}
      flutter-version: 3.47.0
      build-timeout-minutes: 150
      targets: >-
        [{"target": "windows-x64", "runner": "windows-2022"},
         {"target": "windows-arm64", "runner": "windows-11-arm"},
         {"target": "linux-x64", "runner": "ubuntu-22.04"},
         {"target": "linux-arm64", "runner": "ubuntu-22.04-arm"},
         {"target": "macos-arm64", "runner": "macos-15"},
         {"target": "ios-arm64-iphoneos", "runner": "macos-15"},
         {"target": "ios-arm64-iphonesimulator", "runner": "macos-15"},
         {"target": "android-arm", "runner": "ubuntu-22.04"},
         {"target": "android-arm64", "runner": "ubuntu-22.04"},
         {"target": "android-x64", "runner": "ubuntu-22.04"}]
      build-args: >-
        {"*": ["--ios-version", "15", "--macos-version", "14", "--android-api", "24"],
         "android-*": ["--define", "android_ndk_home=${ANDROID_NDK_HOME}"]}
      web-runner: ubuntu-22.04
      web-build-command: dart run tool/build_web.dart --out "$OUT/web"
      web-toolchain-command: echo "onnxruntime-web $(jq -r .version web_build/onnxruntime_web.json) (npm)"
      web-test-cache-path: example/assets/models/**/*.onnx
      web-test-cache-hash-files: native_artifacts/manifest.json
      web-test-command: |
        dart run tool/fetch_hf_models.dart futoSwipe keywordSpotter magika miniLmL6V2 minishLab/potion8m.onnx msmarcoMiniLmL6V3 nemoAsr/fastconformer_ctc_multilingual_int8.onnx pyannote senseVoice sileroVad whisper
        node tool/test_web_runtime.mjs
        dart test -p chrome -c dart2js,dart2wasm test/web_runtime_test.dart test/deterministic_operation_corpus_test.dart
      release-command: dart run tool/release_native.dart
```

`prebuilt_release.yml` describes each input.

### Names

| Thing | Name |
|---|---|
| Workflow file and name | `prebuilt_release.yml`, `Prebuilt release` |
| Trigger branches | `prebuilt-release`, `prebuilt-release-dry` (a dry run) |
| Artifacts | `prebuilt-<target>`, `prebuilt-web`, `manifest`, `debug-symbols-<target>` |
| Manifest branch | `prebuilt-manifest/<tag>` |
| Release tag | `native-<16 characters of the source key>`. The package sets it. |

The `package` input is the Dart package of the tool, `native_prebuilt` by default. When that package is renamed, only the default changes.

## Change this repository

The reusable workflows use the composite actions of this repository. A `uses:` cannot contain an expression, so each of these references names a commit. `pin_self` sets the references, and `pin_self --check` in CI makes sure that they are current.

1. Commit the change to `actions/` or `flutter_version.txt`.
2. Run `dart run telosnex_ci_tools:pin_self`.
3. Commit the changed workflow files.
4. Push, then tag the commit `vX.Y.Z`.

Callers pin the tagged commit. Renovate opens a pull request in each caller for a new tag.

## Renovate

Install the Renovate GitHub app on the organization. Then add `renovate.json` to each repository:

```json
{ "extends": ["github>Telosnex/telosnex_ci_tools"] }
```
