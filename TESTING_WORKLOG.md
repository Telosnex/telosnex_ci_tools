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
| web: Chrome dart2js and dart2wasm, Firefox dart2js, Safari dart2js | Pass with `web_llm_integration_test.dart` (run 40235700903): default build in Chrome and Firefox, compat in Safari, `compat_solid_red` in Chrome and Safari, all cross-origin isolated. |
| ios simulator | **Open.** Passed twice, then stalled 18 min after `Xcode build done`, before any test. Run 40231960707 has the diagnostics. |

## TODO

### fllama
- [ ] test.yml run 40241296726: Firefox stalled (no output 600 s after the build; the previous Firefox drive step took 167 s). Watch for a repeat; flutter drive prints nothing while tests run, so web-driver's idle limit is also the test-time limit.
- [x] Windows: `watch` broke flutter (`bash: D:a_tempflutter/bin/internal/exit_with_errorlevel.bat`). Cause, reproduced in the Parallels Windows 11 VM: the step ran `dart` through Flutter's wrapper (bin/dart -> dart.bat), which leaves OS=MINGW64_NT..., FLUTTER_ROOT, EXIT_WITH_ERRORLEVEL etc. in the environment; every flutter that watch's bash started then took the wrong path in flutter.bat. Fix ci_tools e1d108c: start `bin/cache/dart-sdk/bin/dart.exe` directly. The action's real script passes in the VM; fllama bc292ca uses it (push after run 40245072960).
- [ ] **iOS simulator stall.** Read the `ios-diagnostics` artifact of run 40231960707: simulator log, app list, screenshot. Find out whether install, launch or the connection to `flutter test` stalls.
- [x] Thread count: owner changed mind (2026-10-25). Default (numThreads <= 0) is physical cores - 1, at least 1; web CPUs - 1, at most 4. A set value is used as is. fllama spike a6760c8.
- [x] Pause test: the macOS run had a 394 ms gap against a 400 ms limit. Minimum now 750 ms (spike `c38a93c`, not pushed). Good runs: 30-394 ms; a decode thread on every CPU: 605-1012 ms.
- [ ] Safari dart2js was 0.26 tok/s on Qwen 0.8B. Check the thread count against the 3-CPU runner.
- [x] `scripts/serve_test_models.dart` "died" twice locally: the agent's shell ends background processes when a command ends. It survives dropped downloads. No change needed; on CI it runs in the same step as the tests.
- [x] Turn the spike into `.github/workflows/test.yml` (spike 9cb7c49, first run 40239617201). PR: linux-x64, macos-arm64, Chrome dart2js and dart2wasm. main, nightly, manual: every cell. The spike workflow is manual only.
- [ ] Before merging test.yml: remove `spike/test-cells` from its push branches (TODO in the file).
- [ ] Watch test.yml's first nightly runs for flakes (iOS connect, Safari session).
- [x] Port the dev/web_smoke cases (9 of 10; not `compat_solid_red`) to `example/integration_test/web_llm_integration_test.dart`.
- [ ] Force the compat build on Chrome (`compat_solid_red`): Safari covers compat today.
- [x] `image_title` was slow (2-5 min on CI): fllama_header.png at 1280 x 640 is 800 image tokens. Now `test/assets/test_title.png`, 640 x 320, 200 tokens (fllama e4c7424). Not the mmproj cache fix. CI: Chrome 185/128 s to 46 s, Firefox 215 s to 52 s.
- [ ] iOS: from the `flutter test -v` log, find why flutter_tools does not connect to the app's VM service (port forwarding? mDNS?), and fix it.
- [x] iOS watchdog false stall (run 40235095714): attempt 1 was killed during the Xcode build, silent for 500 s against the 480 s limit. Attempt 2 passed (32 tests, 4 min). So the original stall (VM service listens, flutter test never connects) has not been seen again yet. Fix: build in a separate step (`flutter build ios --simulator --debug`) before `flutter test`, or a longer limit until the first test starts. Done: spike 63ca01c builds in its own step (run 40237842614).
- [ ] The real `test.yml` keeps the reporting driver, `pipefail`, and the check that the report has a result for the last test.
- [ ] Check web tests in Chrome and Safari before relying on CI (delegate).
- [x] ggml-metal WIP is in fllama `git stash` ("ggml-metal WIP (not PR-able yet)"); `/tmp/wip_backup.patch` is a second copy.
- [ ] Merge to main: `fllamaWebRuntimeInfoJs`, the mmproj cache fix in `fllama_web_init.js`, `scripts/fetch_web_release.dart`, the reporting driver.
- [x] Make the web cells check the wllama build (default or compat), cross-origin isolation and thread count, and fail on a mismatch.
- [ ] Merge the fllama fixes of the spike to `main` (see Decisions). Leave out the spike workflow and `web_spike_test.dart`.

### telosnex_ci_tools
- [x] drive-test-widgets flagged `flutter build -t` targets (35 false findings in fllama). Fixed in c23e4fd; fllama still pins 7c9f879, bump with the next pin.
- [ ] Prove `actions/watch`, `android-emulator` and `web-driver` on runners. fllama spike ad4048c switched web and android to them (run 40238004336). `watch` runs inside `web-driver`; iOS still has its inline watchdog.
- [x] Lint: a workflow `run:` that pipes into `tee` needs `pipefail` (workflow `defaults.run.shell: bash`). Without it a failed `flutter drive` passed.
- [x] Lint or check: an integration test run with `flutter drive` uses `testWidgets`. `test()` failures are not reported to the driver.
- [ ] Never `git commit -a` in a package checkout that has someone's local work (fllama: uncommitted ggml-metal changes went into 73898ff and started CUDA pack / publish; cancelled before it published).
- [x] Lint rules released on main (7c9f879, c23e4fd). super_native_extensions' 3 legacy `index.html`: fixed on local branch `example-flutter-bootstrap` (8bc1a43), not pushed; `flutter build web` of super_drag_and_drop/example passes.
- [x] Lint: no `actions/cache/restore` or `actions/cache/save`. The org allow list has only `actions/cache`, and the run fails at startup with no message.
- [x] Lint: a job-level `defaults.run` sets `shell: bash`. Job defaults replace workflow defaults (the v0.3.0 bug).
- [x] Lint: an example's `web/index.html` loads `flutter_bootstrap.js`. The legacy loader runs `main.dart.js` in a `--wasm` build.
- [x] `actions/watch` (`watch.dart`, dart:io only, no pub get; was planned as `bin/watch.dart`): stops a command after N minutes with no output, and runs a diagnostics hook first.
- [x] Action `android-emulator`: KVM permissions, `ANDROID_AVD_HOME`, `adb` on `PATH`, system image, boot wait, emulator log.
- [ ] Action `ios-simulator`: start CoreSimulator, a fresh simulator, log stream, watchdog, one retry only if no test started, cleanup. Wait until the iOS stall is fixed.
- [x] Action `web-driver`: start chromedriver, geckodriver or safaridriver, wait for `/status`, run `flutter drive`, retry only on `SessionNotCreatedException`.
- [ ] Maybe: an action that caches test downloads by URL and SHA-256 (GGUF models, GPU packs, fonnx models).
- [ ] README: the runner facts below.
- [ ] Later: a shared `kiln_test.yml`, when a second package uses the actions.

### kiln
- [ ] The web files must not depend on the native source key. A change to `src/` makes kiln refuse the released wllama files although they did not change; fllama's web tests broke on it. `scripts/fetch_web_release.dart` is the workaround. Needs a design: a separate key for the web sources.
  - Research (2026-10-25): fllama's web build (`tool/kiln/build_web.dart`) reads only `web_build/wllama.json`, `web_build/wllama.patch` and itself. It clones wllama and llama.cpp at the commits in wllama.json, with the Dawn zip and emsdk image pinned there. It never reads `src/`. So no change under `src/` can change the web files, but kiln's one source key (kiln `lib/src/source_key.dart`: every git file minus excludes) covers `src/`, and `web_install.dart:151` refuses the release on a mismatch.
  - Options: (a) a web key over a package-declared list (fllama: `web_build/`, `tool/kiln/build_web.dart`), stored in web.json and checked instead of the native key; (b) a `web_source` glob list in the kiln config, defaulting to today's behaviour; (c) leave the native key and add a `web_build: release` mode that skips the check. (a)/(b) keep the safety; (c) does not.
  - Owner (2026-10-25): web does depend on llama.cpp. Fact: `src/llama.cpp` is a vendored copy at ece963f, the same commit `wllama.json` pins, but the web build clones its own copy: local patches in `src/llama.cpp` (for example the uncommitted ggml-metal work) do not reach web. A key that ignores `src/` hides that. Owner chose the check: fllama 44bc091 `test/llama_cpp_pin_test.dart`, job llama-cpp-pin in test.yml (local, not pushed). `src/fllama*.cpp` (native-only glue) stays out of the web key.
- [x] Select `web_build: local` without editing the pubspec: kiln 4cbb363 (local, not pushed) reads web_build and web_build_dir from `<cache root>/defaults.json`, as native_build already did. Next: CI writes defaults.json instead of the Python pubspec edit, once fllama uses that kiln.
- [ ] `native_build: local` with `native_build_dir`, as `web_build: local`. Then `kiln_release` can test the binaries it built before it uploads them.
- [ ] `kiln:build` writes unstripped libraries to a fixed directory in `--out`, so the release workflow need not know the cache layout of each package.

### Mobile browsers (fllama web)
- 2026-10-25 test.yml run 40248984708: every job passed, Windows included (watch fix e1d108c).
- iOS Safari, local (iOS 26.0 simulator, `flutter drive --browser-name ios-safari`, safaridriver): runs end to end in about 1 min, compat build, cross-origin isolated. hardwareConcurrency is the Mac's 8. Failures by thread count (the test's count; default is now CPUs - 1 = 7): 7 threads, mmproj_hi ABORT, then every later load "Cannot allocate WebAssembly.Memory" (memory not freed after the abort); 5 and 6, only compat_solid_red (the 7th load) ABORTs; 4, all pass. Desktop Safari on the same Mac, 7 threads: all pass (twice). So the old cap of 4 hid an iOS WebKit memory limit.
- sdkmanager (2026-10-25): newest stable x86_64 images are android-37.0 google_apis / google_apis_playstore (rev 8); 37.2 is arm64 beta only. Local arm64 37.0 images segfault on boot on this Mac (QEMU threads hang), with and without swiftshader. Local API 36 Play image: ships Chrome 133, was updated to 154 by the Play Store. CI probe (run 40245072960): x86_64 android-37.0 google_apis has Chrome 145.0.7632.218 (WebView same) and the Play Store (com.android.vending); booted in 108 s.
- [ ] iOS Safari: `flutter drive --browser-name ios-safari` (safaridriver with `safari:useSimulator`). Reuses the iOS simulator setup; localhost is shared with the Mac. Same WebKit as desktop Safari, so likely the compat build again. The simulator does not enforce iPhone tab memory limits (WebKit bug 291677: iOS kills WebContent at its high-water mark; three.js #30047, WebKit 284752: crashes on device only), so it cannot catch out-of-memory reloads. It does catch some iOS WebAssembly bugs (emscripten #24600 reproduced in the 18.0 simulator).
- [ ] Android Chrome: `flutter drive --browser-name android-chrome` (chromedriver `androidPackage: com.android.chrome`). Unknown: whether the google_apis image has Chrome, and which version. Spike 5a5752e lists it. Emulator Chrome can be very old (Bitrise: 83 against chromedriver 104); the usual fix installs an APK from APKMirror, which needs the owner's OK. chromedriver must match the device Chrome; the page needs `adb reverse` for localhost unless flutter drive does it. Result (test.yml run 40239617201): the google_apis API 35 image has `com.android.chrome` 124.0.6367.219 (WebView the same). No APK needed. chromedriver 124 comes from Chrome for Testing (official). Chrome 124 predates JSPI and Memory64 shipping, so this cell would run the compat build on an Android browser. The Android job passed: emulator booted in 75 s, 32 tests in 6:50.
- Real-device memory, thermals and GPU need real devices: out of the MVP.

### Other packages (after fllama)
- [ ] telosnex_audio. Survey (2026-10-25, main de64d41): CI already runs native gtest on macOS (with TSan), Linux x64 and arm64, Windows x64; `flutter test` engine/licenses/hook on macOS; example builds (desktop, apk); web engine cases in Chrome plus the AudioWorklet check (`tool/kiln/test_web.dart`, JS and Wasm). Gaps:
  - Web: Firefox and Safari. `tool/web_check.dart` already supports both, but Safari needs a click (AudioContext user gesture): with safaridriver, the click can be scripted.
  - Android emulator and iOS simulator: `example/lib/device_check.dart` is an app entry that prints `TSNX_DEVICE` lines and PASS/FAIL to logcat/console. Run it with `flutter run --release -t lib/device_check.dart` on the emulator/simulator, read the log. The emulator has no earpiece (routes differ).
  - `flutter test` on Linux and Windows (only macOS today).
  - Uses `Telosnex/flutter-action` and old checkout pins, not `setup-flutter`; lint finds nothing because ci.yml is not a kiln workflow name. Move to ci_tools actions when tests are added.
- [ ] fonnx. Survey (2026-10-25, main 39f651b): `native_assets_smoke.yml` runs on Linux x64, macOS arm64, Windows x64: `tool/test_web_runtime.mjs` (Node), sanitizers, the operation corpus, ORT sessions, FUTO Swipe. Not in CI:
  - `tool/test_all.sh`, the "authoritative package gate": 38 model test files in one serialized process. Needs the models: `tool/fetch_hf_models.dart` downloads 1.5 GB (2.3 GB on disk), pinned to Hugging Face commits and SHA-256 in `native_artifacts/manifest.json`. A cache keyed on that manifest is the cached-downloads action.
  - `tool/test_ios_simulator_artifacts.sh` and `tool/test_android_artifacts.sh` (ORT session on the simulator / an AVD with `FONNX_ANDROID_AVD`): ready for the ios-simulator and android-emulator actions.
  - `example/integration_test`: 2 files, 3 tests (plugin, keyword spotter). Not run anywhere.
  - Web: 3 `@TestOn('browser')` files (web runtime, kokoro web, misaki web), Chrome only if at all.
  - `codemagic.yaml` still in the repo (builds and signing only, no tests).
- [ ] zxing_dart, image_ffmpeg. Survey (2026-10-25): the same shape. CI is only kiln: `kiln_check.yml` and `kiln_release.yml`, which runs `tool/kiln/test_build.dart` (Dart API tests on macos-arm64) and `tool/kiln/test_web.dart` (browser tests in Chrome, dart2js and dart2wasm). These are `dart test -p` browser tests, not `flutter drive`. Not in CI:
  - Firefox and Safari: `dart_test.yaml` already overrides Safari with `tool/safari_test_launcher.sh` (Safari refuses package:test's redirect file). `dart test -p firefox,safari` on the runners is the cell.
  - Dart tests on Linux and Windows, and arm64: only macos-arm64. Local docker/Wine scripts exist (`tool/test_linux_*docker.sh`, `tool/test_windows_*wine*.sh`); native runners replace them.
  - Mobile: `tool/test_android_device.sh` / `test_android_artifact.sh` and `tool/test_ios_simulator*.sh` exist, not in CI.
  - `tool/test_all.*` and `tool/test_native_sanitizers.sh` (local gates).
  - No PR test workflow: tests run only in a release.
- [ ] webcrypto.dart: Safari and the arm runners only. Keep the upstream `test.yml`. Survey (2026-10-25): confirmed. Upstream `test.yml` runs `dart test -p vm,chrome,firefox -c dart2js,dart2wasm` on Linux (xvfb), vm+chrome on macos-15, vm+chrome+firefox on Windows, plus iOS and Android jobs. No Safari, no arm runners.
- [ ] super_native_extensions: upstream `check_and_lint.yml` fails (`actions/cache@v3` is blocked, a clippy rule). Fix or replace it, then add smoke tests. Survey (2026-10-25, native-prebuilt ec61bda): upstream `check_and_lint.yml` runs `melos exec flutter test` (Linux), cargo clippy (host, Android, iOS) and `cargo test` on an OS matrix. Dart tests are few and shallow (one file per package, 2 web drop tests); no integration tests. Clipboard and drag-and-drop need a desktop session: a smoke test is an example app on macOS/Windows/Linux (xvfb) that writes and reads the clipboard.
- [x] Before a design for each package, survey `example/`, `dev/` and removed CI configs (Codemagic). Done 2026-10-25 for all 6 (above). Common gaps: Firefox/Safari, Linux/Windows/arm Dart tests, mobile scripts that exist but are not in CI, and no PR test workflow outside kiln.

## Runner facts

- Windows debugging: the Parallels `Windows 11` VM (ARM64). Send scripts with `powershell -EncodedCommand` (prlctl mangles quotes; long commands fail), clone repos there from GitHub.

- macos-15 has 3 CPUs. ubuntu-24.04, ubuntu-24.04-arm and the Windows runners have 4.
- macos-15's GPU is "Apple Paravirtual device": no Apple6-9 or Metal3 family, so ggml-metal has no simdgroup kernels.
- ubuntu-24.04 has `/dev/kvm`. ubuntu-24.04-arm has none (run 40226383012), so no Android emulator cell there.
- Preinstalled: Chrome 155 with `$CHROMEWEBDRIVER`, Firefox 157 with `$GECKOWEBDRIVER` (Linux), Safari 26.6.1 with `safaridriver` (needs `sudo safaridriver --enable`).
- On a fresh macOS runner the first `simctl` call starts CoreSimulator, and can take more than 1 minute.
- `adb` is not on `PATH` on ubuntu-24.04: use `$ANDROID_HOME/platform-tools`.
- Flutter runs dart2wasm builds only in Chromium unless the app sets `wasmAllowList`. Firefox and Safari users get dart2js.
- `flutter drive -d web-server` reads `web_dev_config.yaml`, so it can send COOP/COEP headers.
- Playwright's Firefox runs WebAssembly about 10 times slower than stock Firefox and has no JSPI. Use stock browsers.

## Decisions

- 2026-10-25: No version tag for telosnex_ci_tools until the first consumer (fllama) is through. Consumers pin the commit SHA with `# main`.

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
