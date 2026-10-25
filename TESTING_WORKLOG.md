# Testing worklog

Tests of kiln packages on GitHub-hosted runners: what we learned, and what
to follow up on. The fllama MVP comes first; the other packages follow.

## Status (2026-10-25)

fllama spike: branch `spike/test-cells`, workflow
`.github/workflows/spike_test_cells.yml`. A commit message with
`[ios only]` runs only the iOS job.

| Job | Status |
|---|---|
| desktop: linux-x64, linux-arm64, macos-arm64 (CPU), macos-arm64-metal, windows-x64, windows-arm64 | Pass, 2 runs in a row |
| android-x64 emulator (ubuntu-24.04, KVM) | Pass, about 23 min |
| web: Chrome dart2js and dart2wasm, Firefox dart2js, Safari dart2js | **Unproven.** The probe used `test()`, which `flutter drive` never reports, and since 5487175 the build did not even compile (hidden by `| tee` without pipefail). Real test `web_llm_integration_test.dart` passes locally in Firefox; first CI run pending. |
| ios simulator | **Open.** Passed twice, then stalled 18 min after `Xcode build done`, before any test. Run 40231960707 has the diagnostics. |

## TODO

### fllama
- [ ] **iOS simulator stall.** Read the `ios-diagnostics` artifact of run 40231960707: simulator log, app list, screenshot. Find out whether install, launch or the connection to `flutter test` stalls.
- [ ] Decide: cap `numThreads` at the number of CPU cores? More threads than cores makes each token take seconds (llama.cpp threads spin at barriers).
- [x] Pause test: the macOS run had a 394 ms gap against a 400 ms limit. Minimum now 750 ms (spike `c38a93c`, not pushed). Good runs: 30-394 ms; a decode thread on every CPU: 605-1012 ms.
- [ ] Safari dart2js was 0.26 tok/s on Qwen 0.8B. Check the thread count against the 3-CPU runner.
- [x] `scripts/serve_test_models.dart` "died" twice locally: the agent's shell ends background processes when a command ends. It survives dropped downloads. No change needed; on CI it runs in the same step as the tests.
- [ ] Turn the spike into `.github/workflows/test.yml`: PR cells (linux-x64, macos-arm64, Chrome dart2js and dart2wasm), all cells nightly and on demand.
- [x] Port the dev/web_smoke cases (9 of 10; not `compat_solid_red`) to `example/integration_test/web_llm_integration_test.dart`.
- [ ] Force the compat build on Chrome (`compat_solid_red`): Safari covers compat today.
- [ ] Firefox `image_title` took 65 s locally; the other image cases 1-2 s. Check whether the mmproj cache fix downloads the model again, and whether test order matters.
- [ ] iOS: from the `flutter test -v` log, find why flutter_tools does not connect to the app's VM service (port forwarding? mDNS?), and fix it.
- [ ] The real `test.yml` keeps the reporting driver, `pipefail`, and the check that the report has a result for the last test.
- [ ] Check web tests in Chrome and Safari before relying on CI (delegate).
- [ ] Remove `/tmp/wip_backup.patch` once the uncommitted ggml-metal work in the fllama checkout is confirmed intact.
- [ ] Merge to main: `fllamaWebRuntimeInfoJs`, the mmproj cache fix in `fllama_web_init.js`, `scripts/fetch_web_release.dart`, the reporting driver.
- [x] Make the web cells check the wllama build (default or compat), cross-origin isolation and thread count, and fail on a mismatch.
- [ ] Merge the fllama fixes of the spike to `main` (see Decisions). Leave out the spike workflow and `web_spike_test.dart`.

### telosnex_ci_tools
- [ ] Lint: a workflow `run:` that pipes into `tee` needs `pipefail` (workflow `defaults.run.shell: bash`). Without it a failed `flutter drive` passed.
- [ ] Lint or check: an integration test run with `flutter drive` uses `testWidgets`. `test()` failures are not reported to the driver.
- [ ] Never `git commit -a` in a package checkout that has someone's local work (fllama: uncommitted ggml-metal changes went into 73898ff and started CUDA pack / publish; cancelled before it published).
- [ ] Release the 3 lint rules (committed locally, not pushed). First run found 3 legacy `index.html` in super_native_extensions examples (super_context_menu, super_drag_and_drop, super_keyboard_layout). Fix them before the repo's CI runs the new lint.
- [x] Lint: no `actions/cache/restore` or `actions/cache/save`. The org allow list has only `actions/cache`, and the run fails at startup with no message.
- [x] Lint: a job-level `defaults.run` sets `shell: bash`. Job defaults replace workflow defaults (the v0.3.0 bug).
- [x] Lint: an example's `web/index.html` loads `flutter_bootstrap.js`. The legacy loader runs `main.dart.js` in a `--wasm` build.
- [ ] `bin/watch.dart`: stops a command after N minutes with no output, and runs a diagnostics hook first.
- [ ] Action `android-emulator`: KVM permissions, `ANDROID_AVD_HOME`, `adb` on `PATH`, system image, boot wait, emulator log.
- [ ] Action `ios-simulator`: start CoreSimulator, a fresh simulator, log stream, watchdog, one retry only if no test started, cleanup. Wait until the iOS stall is fixed.
- [ ] Action `web-driver`: start chromedriver, geckodriver or safaridriver, wait for `/status`, run `flutter drive`, retry only on `SessionNotCreatedException`.
- [ ] Maybe: an action that caches test downloads by URL and SHA-256 (GGUF models, GPU packs, fonnx models).
- [ ] README: the runner facts below.
- [ ] Later: a shared `kiln_test.yml`, when a second package uses the actions.

### kiln
- [ ] The web files must not depend on the native source key. A change to `src/` makes kiln refuse the released wllama files although they did not change; fllama's web tests broke on it. `scripts/fetch_web_release.dart` is the workaround. Needs a design: a separate key for the web sources.
- [ ] Select `web_build: local` (and `native_build`) without editing the pubspec: a command-line or environment option. CI edits `example/pubspec.yaml` with a Python snippet today.
- [ ] `native_build: local` with `native_build_dir`, as `web_build: local`. Then `kiln_release` can test the binaries it built before it uploads them.
- [ ] `kiln:build` writes unstripped libraries to a fixed directory in `--out`, so the release workflow need not know the cache layout of each package.

### Other packages (after fllama)
- [ ] telosnex_audio: Firefox and Safari (AudioWorklet), Android, iOS, Dart tests on Linux and Windows. A `realtime` tag with one retry for timing tests.
- [ ] fonnx: Firefox and Safari, mobile, model cache.
- [ ] zxing_dart, image_ffmpeg: unit and web cells with the default commands.
- [ ] webcrypto.dart: Safari and the arm runners only. Keep the upstream `test.yml`.
- [ ] super_native_extensions: upstream `check_and_lint.yml` fails (`actions/cache@v3` is blocked, a clippy rule). Fix or replace it, then add smoke tests.
- [ ] Before a design for each package, survey `example/`, `dev/` and removed CI configs (Codemagic). The first survey missed most of fllama's tests.

## Runner facts

- macos-15 has 3 CPUs. ubuntu-24.04, ubuntu-24.04-arm and the Windows runners have 4.
- macos-15's GPU is "Apple Paravirtual device": no Apple6-9 or Metal3 family, so ggml-metal has no simdgroup kernels.
- ubuntu-24.04 has `/dev/kvm`. ubuntu-24.04-arm: not confirmed (the spike job checked only x64 fully).
- Preinstalled: Chrome 155 with `$CHROMEWEBDRIVER`, Firefox 157 with `$GECKOWEBDRIVER` (Linux), Safari 26.6.1 with `safaridriver` (needs `sudo safaridriver --enable`).
- On a fresh macOS runner the first `simctl` call starts CoreSimulator, and can take more than 1 minute.
- `adb` is not on `PATH` on ubuntu-24.04: use `$ANDROID_HOME/platform-tools`.
- Flutter runs dart2wasm builds only in Chromium unless the app sets `wasmAllowList`. Firefox and Safari users get dart2js.
- `flutter drive -d web-server` reads `web_dev_config.yaml`, so it can send COOP/COEP headers.
- Playwright's Firefox runs WebAssembly about 10 times slower than stock Firefox and has no JSPI. Use stock browsers.

## Decisions

- 2026-10-25: Web tests use `flutter drive` with stock browsers, not Playwright.
- 2026-10-25: No dart2wasm cells for Firefox and Safari, also not nightly. Flutter needs an opt-in for them; revisit when Flutter supports them by default.
- 2026-10-25: Android arm emulators, real devices, Edge and mobile browsers are out of the MVP.
- 2026-10-25: fllama fixes from the spike, to merge:
  - Skip a GPU that cannot run matrix multiply, RMS norm and softmax (macOS VM Metal crashed in the image encoder).
  - `mmproj_use_gpu` follows `numGpuLayers`.
  - `params.devices` ends with nullptr.
  - Tests: the pause test leaves a CPU free; long requests are cancelled in tearDown; GPU pack test timeout 10 min, with pack files in the model cache.

## Log

- 2026-10-25: web tests were not testing. `test()` results do not reach `flutter drive`, and the job's `| tee` hid a compile failure for 3 runs. Found with the port. Real fllama bug found: wllama's model cache keys by URL only, so a model cached for a text request loaded again without mmproj and images were ignored.
- 2026-10-25: iOS stall diagnosed: the app launches and its Dart VM service listens 3 s later, but `flutter test` never connects. Next run has `flutter test -v`.

- 2026-10-25: fllama spike started. The failures it found and their causes:
  - A `--wasm` build with the legacy `index.html` stalled: the loader ran `main.dart.js`.
  - The Firefox and Safari Wasm stalls: Flutter's loader rejects Wasm outside Chromium.
  - The linux-arm64 1 s pause and the earlier iOS hang: 4 decode threads on 4 or 3 CPUs.
  - Metal on macos-15: a paravirtual GPU without the kernels, then a crash in the image encoder.
