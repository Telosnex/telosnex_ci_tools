# The package standard

What a Telosnex package does so that its CI reads the same as the others' and shows up properly on the [dashboard](https://github.com/Telosnex/telosnex_ci_tools/tree/dashboard). fllama is the reference: copy its `.github/workflows/` and adapt.

The lint enforces the items marked **(lint)**. Every package runs it in `unit.yml`, after `setup-flutter`:

```yaml
      - uses: Telosnex/telosnex_ci_tools/actions/lint@<full sha> # vX.Y.Z
```

Locally, from a checkout of this repository: `dart run telosnex_ci_tools:lint ../<package>`.

## 1. Workflows

| File | Name | Runs on | Contents |
|---|---|---|---|
| `unit.yml` | Unit | every pull request; pushes to the default branch and `ci/**` | the workflow lint, format, analyze, the package's host tests. Fast: this is what a PR waits for. |
| `integration.yml` | Integration | pushes to the default branch and `ci/**`, nightly, manual | every platform and browser |
| `kiln_check.yml`, `kiln_release.yml` | Kiln check, Kiln release | see [Kiln release](../README.md#kiln-release) | Kiln packages only |

Other workflows are named for their topic (`cuda_pack.yml`). The `name:` matches the file name in sentence case **(lint)**. `ci/**` branches run both workflows so a new workflow can be tried before it reaches the default branch.

## 2. Jobs

- **Every job has a `name:`.** A job that runs on a platform is `<Platform> <Arch> [detail]`, a browser job is `Web <Platform> <Arch> <Browser> [detail]` **(lint)**. See [Job names](../README.md#job-names) for the words. The dashboard puts a job in a platform column by its name: a name that doesn't fit lands under "Other".
- **Details**: mobile jobs say what they run on (`simulator`, `emulator`, `build`); web jobs end with the compiler (`dart2js`, `dart2wasm`, `ddc`), after any other detail (`Web Linux x64 Chrome Flutter ddc`). Don't use `native` or `example`: say what is tested.
- **Job IDs** are the boxes of the run graph: `desktop-<platform>-<arch>`, `web-<platform>-<browser>-<compiler>`, `ios`, `android`. Jobs without a platform: any ID (`models`, `web-files`).
- **No matrix** **(lint `no-matrix`)**: GitHub draws a matrix as one box. Write the jobs out, give the first `steps: &desktop_steps` and the others `steps: *desktop_steps`, and put what differs in job `env:` (`TARGET`, `DEVICE`, `BROWSER`, `COMPILER`) and step `if:`. Use `${{ env.X }}` where you used `${{ matrix.x }}`. No merge key `<<:` **(lint `no-merge-key`)**: GitHub rejects it at startup.
- `timeout-minutes` on every job **(lint)**; top-level `permissions` **(lint)**; workflow `defaults.run.shell: bash`, so a pipe into `tee` cannot hide a failure (the lint flags such a pipe without it).

## 3. telosnex_ci_tools

- **Pin a tag**, never `main`: `uses: Telosnex/telosnex_ci_tools/actions/<action>@<full sha> # vX.Y.Z`, the same tag everywhere in the package (`dart run telosnex_ci_tools:release` moves them). Git dependencies on `packages/telosnex_web_test` use `ref: vX.Y.Z` of the same tag.
- Install Flutter with `actions/setup-flutter` **(lint)**.
- **Upstream fork workflows** (issue bots and the like): delete them, or bring them in line; the lint checks every workflow.
- **Logs on failure**: every job that can fail opaquely uploads its logs. `ios-flutter-test` and `web-driver` do it themselves (give each an `artifact-name`); upload the Android emulator's `log` and `logcat` outputs with `if: failure() || cancelled()`. Name artifacts `<job-ish>-logs`.

## 4. Tests by platform

- **Desktop**: `flutter test integration_test/...` on the device (`-d linux`, `xvfb-run` on Linux), under `actions/watch` for anything that can stall.
- **Web, `flutter drive`**: use `actions/web-driver` and [`packages/telosnex_web_test`](../packages/telosnex_web_test/README.md) (`installWebTestSupport` in the test, `webIntegrationDriver` as the driver), and set `require-result` so a run without results fails. Without them a failed plain `test()` passes and the browser console is lost. Web tests with `dart test --platform` (fonnx) need neither.
- **iOS**: boot with `actions/ios-simulator-boot` (`id: simulator`), then `actions/ios-flutter-test` with `udid: ${{ steps.simulator.outputs.udid }}`. **Don't build ahead** with `flutter build ios --simulator`: Xcode rebuilds everything for flutter test's destination anyway. **One target**: each target is a build, install and launch, so import all integration test files into one entry point (fonnx: `integration_test/ios_all.dart`, not named `*_test.dart`).
- **iOS without Flutter** (Dart tests run by a script on a simulator): boot with `actions/ios-simulator-boot`, and upload the script's logs with `if: failure() || cancelled()`.
- **Android**: `actions/android-emulator`; building the APK before the emulator boots does help (Gradle and the emulator share the CPUs).

## 5. Dependencies between Telosnex packages

Pin another Telosnex package's git dependency to a commit, not a branch: a branch can lose its prebuilt files between Kiln releases, and then every consumer builds from source (fonnx and telosnex_audio, 2026-10-27).

## 6. Branch protection

A protected default branch requires **one check: `Unit`**. Nothing else.

- **Why only Unit:** a required check that doesn't run on a pull request stays "expected" forever, and the PR can't merge. `Unit` is the only workflow that runs on every pull request, with no `paths` filter. Integration runs on push, nightly and by hand, so requiring its jobs blocks every PR. `Kiln check` runs on pull requests only when the manifest changes, so requiring it blocks every other PR.
- **So `unit.yml` must keep running on every pull request:** `pull_request:` without `paths` or `branches`.
- **Integration still guards the default branch:** it runs on every push there and nightly, and a red run shows on the dashboard. Run it on a PR by hand (`workflow_dispatch` on the PR branch) when the change needs it, before merging.
- **Job names are the check names:** if you rename the Unit job, update the rule in the same change.
- **Set it with:**

  ```sh
  gh api -X PUT repos/Telosnex/<repo>/branches/<default branch>/protection --input - <<'JSON'
  {"required_status_checks": {"strict": false, "checks": [{"context": "Unit"}]},
   "enforce_admins": true,
   "required_pull_request_reviews": {"required_approving_review_count": 0},
   "restrictions": null}
  JSON
  ```

  This also requires a pull request for every change (no approvals). Protection is optional. A repository without it is fine; one with it follows this rule.

## 7. The dashboard

Add the repository to [`packages.yaml`](packages.yaml). Its defaults read `unit.yml` and `integration.yml` (test cells), `kiln_check.yml` and `kiln_release.yml`; set `checks: []` and `releases: []` for a package without Kiln. Only public repositories. `packages.md` and the dashboard then follow the default branch on their own.
