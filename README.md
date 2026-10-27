# telosnex_ci_tools

The shared GitHub Actions workflows, composite actions and CI conventions of the Telosnex repositories.

## Contents

| Path | Kind | What it does |
|---|---|---|
| `actions/setup-flutter` | Composite action | Installs Flutter from a shallow clone of its tag. The default version is in `flutter_version.txt`. |
| `actions/check-clean-tree` | Composite action | Fails if the checkout has untracked or changed files. |
| `actions/kiln-build` | Composite action | Describes the toolchain and runs `<package>:build` for one target. |
| `actions/watch` | Composite action | Runs a bash command; stops it after N minutes without output, runs an `on-stall` command first, and exits 124. |
| `actions/android-emulator` | Composite action | Boots an x86_64 Android emulator with KVM on ubuntu-24.04, and puts `adb` on `PATH`. |
| `actions/web-driver` | Composite action | Starts chromedriver, geckodriver or safaridriver (`ios-safari`: opens Safari once in the simulator first). Optionally runs `flutter drive` with a watchdog, and again only when the driver could not start a session; passes with a warning when all tests passed and only closing the session failed. Its "All tests passed." misses failed plain `test()`s unless the app reports them (see the action's header). |
| `actions/dart-test-browser` | Composite action | `dart test -p chrome/firefox/safari`: Firefox on Linux under xvfb-run; Safari with safaridriver enabled (package:test 1.33+). |
| `actions/ios-simulator-boot` | Composite action | Creates and boots a fresh iPhone simulator (newest runtime) and outputs its UDID. For native and iOS Safari jobs; use macos-26 or newer. |
| `actions/ios-flutter-test` | Composite action | `flutter test` on a fresh iOS simulator: a connect watchdog (flutter test sometimes never sees the VM service), a stall watchdog, and up to 3 attempts while no test has started. Never starts Safari. |
| `.github/workflows/kiln_release.yml` | Reusable workflow | Builds, tests and publishes the prebuilt native and web files of a kiln package. |
| `.github/workflows/kiln_check.yml` | Reusable workflow | Runs `<package>:check`. |
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

The caller has the triggers and the `run-name`. The shared workflow has the jobs. A caller passes only what is different about its package. This is the kiln release of fonnx, `.github/workflows/kiln_release.yml`:

```yaml
name: Kiln release
run-name: Kiln release / ${{ (github.ref_name == 'kiln-release-dry' || inputs.dry_run) && 'build only' || 'publish' }}

on:
  workflow_dispatch:
    inputs:
      dry_run:
        description: Build only, upload nothing.
        type: boolean
        default: false
  push:
    branches: [kiln-release, kiln-release-dry]

permissions:
  contents: read

jobs:
  kiln-release:
    uses: Telosnex/telosnex_ci_tools/.github/workflows/kiln_release.yml@<sha> # v0.1.0
    permissions:
      contents: write
    with:
      dry-run: ${{ inputs.dry_run == true }}
      build-args: '{"*": ["--ios-version", "15", "--macos-version", "14"]}'
      web-test-cache-path: example/assets/models
```

### Kiln release

The shared workflow sets these values for every package:

| Value | |
|---|---|
| Flutter | `flutter_version.txt` |
| Android NDK | 28.2.13676358, passed to the hook as the user defines `android_ndk_home` (the NDK directory) and `android` (`{"android_home", "ndk_version"}`, the form of native_toolchain_cmake) |
| Runners | `windows-2022`, `windows-11-arm`, `ubuntu-22.04` and `ubuntu-22.04-arm` (older glibc), `macos-15`. Web: `ubuntu-24.04`. |
| Targets | The 10 targets in the `targets` default. A package can pass its own list. |
| Publisher | `jpohhhh`, from a repository of the Telosnex organization. |

A package changes the steps with optional files in `tool/kiln/`. The workflow runs each file with `dart <file>`, in the package directory, after pub get. `dart run` would first run the package's build hook, which can need the tools that `prepare.dart` installs.

| File | Runs | Arguments |
|---|---|---|
| `prepare.dart` | Before each native build. Installs tools. | Environment: `TARGET`, `OUT`, `ANDROID_NDK_HOME`. It can write to `GITHUB_ENV` and `GITHUB_PATH`. `KILN_TOOLCHAIN` replaces the toolchain description; `KILN_TOOLCHAIN_EXTRA` goes at its end. |
| `test_build.dart` | After each native build. Tests the files in `$OUT/out/$TARGET`. | Environment: `TARGET`, `OUT`. |
| `build_web.dart` | In the web job. Without it, the package has no web files. | `--out <dir> --toolchain-file <file>`: writes the web files to `<dir>` and a description of its toolchain to `<file>`. |
| `test_web.dart` | After `<package>:web install-dev` of the built web files, on `web-test-runner`. | Environment: `KILN_WEB_FILES`, the directory of the built web files. |
| `release.dart` | Instead of `<package>:release`. | The same arguments. |

The inputs of `kiln_release.yml` are for the rest: `targets`, `build-args`, `input-artifact`, `debug-symbols-path`, `web-test-cache-path`, `runners`, `web-container`, `web-test-runner` and `working-directory`.

`working-directory` is the directory of the package in a repository with more than one package, for example `super_native_extensions`. Every step runs there, and `tool/kiln/` and `native_artifacts/` are in it. `kiln_check.yml` has the same input.

A target in `runners` builds on its runner, and in its container image if it has one. Before the checkout, the job installs git, curl, unzip and xz with apt-get, if the image has apt-get. The runner description in `target.json` is `local` there: pass `--runner` in `build-args`.

### Names

| Thing | Name |
|---|---|
| Workflow file and name | `kiln_release.yml`, `Kiln release` |
| Trigger branches | `kiln-release`, `kiln-release-dry` (a dry run) |
| Artifacts | `kiln-<target>`, `kiln-web`, `manifest`, `debug-symbols-<target>` |
| Manifest branch | `kiln-manifest/<tag>` |
| Release tag | `native-<16 characters of the source key>`. Kiln sets it. |

The `package` input is the Dart package of [kiln](https://github.com/Telosnex/kiln), `kiln` by default. A package that still uses `native_prebuilt` passes `package: native_prebuilt`.

## Change this repository

The reusable workflows use the composite actions of this repository. A `uses:` cannot contain an expression, so each of these references names a commit. `pin_self` sets the references, and `pin_self --check` in CI makes sure that they are current.

1. Commit the change to `actions/` or `flutter_version.txt`.
2. Run `dart run telosnex_ci_tools:pin_self`.
3. Commit the changed workflow files.
4. Push, then tag the commit of step 3 `vX.Y.Z`.

Callers pin the tagged commit. Do not pin the commit of step 1: its workflows still reference the actions by branch, and the SHA pinning policy of the organization rejects the run with a startup failure. Renovate opens a pull request in each caller for a new tag.

## Renovate

The Renovate GitHub app is installed on the organization. Each repository has `renovate.json`:

```json
{ "extends": ["github>Telosnex/telosnex_ci_tools"] }
```

The preset, `default.json`, updates only the pinned GitHub Actions:

- A new tag of this repository: one pull request, at once.
- Other actions: one grouped pull request, before 6am on Mondays.

This repository pins its own actions with `pin_self`; its `renovate.json` makes Renovate ignore them.

## Job names

`bin/lint.dart` checks them (rule `job-name`). A job that runs on one
platform is named `<Platform> <Arch> [detail]`; a browser job is
`Web <Platform> <Arch> <Browser> [detail]`:

- platforms: Linux, macOS, Windows, iOS, Android
- archs: x64, ARM64, ARM, x86, universal (a job for every arch, e.g. an Android build of all ABIs)
- browsers: Chrome, Firefox, Safari, Edge

Examples: `Windows ARM64`, `macOS ARM64 Metal`, `iOS ARM64 simulator`,
`Android x64 API 37`, `Web Linux x64 Chrome dart2wasm`,
`Web iOS ARM64 Safari`. Jobs without a platform (`Unit`, `Web files`) only
need sentence case.

Workflows of a Kiln package: `unit.yml` (Unit: analyze, format, host VM
tests; every pull request), `integration.yml` (Integration: every platform
and browser; main, nightly, manual), `kiln_check.yml`, `kiln_release.yml`.

