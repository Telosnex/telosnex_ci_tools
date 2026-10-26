# Testing worklog

Tests of kiln packages on GitHub-hosted runners: what we learned, and what
to follow up on. The fllama MVP comes first; the other packages follow.

Goal (owner, 2026-10-25): prove fllama **fully** before the next package.
That includes iOS Safari in the simulator and the newest Android. No
"it works, leave it" shortcuts.

## Status (2026-10-25)

fllama: branch `spike/test-cells`, workflow `.github/workflows/test.yml`
(the spike workflow `spike_test_cells.yml` is manual only). Last full run:
40258278183 (fllama 958cf75, ci_tools 1e4c4ce), in progress.

| Job | Status |
|---|---|
| desktop: linux-x64, linux-arm64, macos-arm64 (CPU), macos-arm64-metal, windows-x64, windows-arm64 | Pass (run 40248984708, Windows included after the watch fix) |
| android / emulator | Pass on API 35 (run 40248984708). Now API 37.0: running |
| ios / simulator | Pass, first attempt, runs 40239617201 and 40248984708. The old stall has not come back |
| web: Chrome dart2js and dart2wasm, Firefox dart2js, Safari dart2js | Pass (run 40248984708; again in 40258278183 except Safari, running) |
| web / ios-safari / dart2js | New. Passes locally (iOS 26.0 simulator, 7 threads) after fllama 8563988. CI: running |
| web / android-chrome / dart2js | New. Passes locally (API 36, Chrome 133). **CI failed** in 40258278183: my bug in web-driver, see TODO |
| llama-cpp-pin | Pass |

## TODO

### Next (in order)
- [ ] Run 40285438371 (c0ab8b6): **all green**, the first full green run (iOS Safari and native iOS on macos-26, Android 37.0 ATD 6 GB, Android Chrome 36). Run 40290245554 (6c21e0e, + carry PR 29150; native jobs build from source): the second.
- [x] web-driver android-chrome `tr: write error: Broken pipe` (grep -m1 under pipefail): awk instead (ci_tools 3e7fbb4).
- [ ] **API 37.0 emulator keeps restarting Android** (fllama run 40260614748, logcat artifact): surfaceflinger aborts every ~40 s, `Abort message: 'Assertion failed: !rcEnc->featureInfo()->hasReadColorBufferDma'` (RegionSampling thread), and system_server restarts each time (4 starts in 2.5 min). Effects: `adb install` "Failure calling service package: Broken pipe"; `Activity class {...MainActivity} does not exist`; Chrome's activity missing for chromedriver. The emulator is 37.2.12 with `-gpu swiftshader_indirect`. API 35 never did this. ci_tools 35f07bf: `gpu` input; settled = system_server keeps its pid for 60 s. Probe: ci_tools branch `probe/emulator` (workflow probe_emulator.yml, run 40263066674): API 37.0 and 36 x swiftshader_indirect / guest / swangle_indirect, counts aborts over 3 min. Pick the mode (or API) without aborts, then delete the branch (deleted 2026-10-26).
  - Probe 1 (run 40263066674), 3 min after boot: API 36 with swiftshader_indirect, guest, swangle_indirect: 0 aborts, 1 system_server start each, Chrome 133. API 37.0 with all three: never settled in 12 min, 26-39 surfaceflinger aborts. So it is the 37.0 image, not the GPU mode.
  - Probe 2 (run 40264520515): 37.0 with `-feature -ReadColorBufferDma` or `-GLDirectMem,-ReadColorBufferDma`: still ~30 aborts (the flag does not help). 36.1 (Chrome 134): 35 aborts. 36-ext19: stable (Chrome 133).
  - Probe 3: 37.0 google_atd and aosp_atd: stable, 0 aborts, but no Chrome (headless test images). 37.0 google_apis_playstore: pending.
  - Decision (fllama 7aea8a6, not pushed until run 40265398700 ends): native Android tests on 37.0 google_atd; Android Chrome on 36 (Chrome 133), the newest stable image with Chrome. Revisit 37.x google_apis when a new image revision appears. Maybe report to the emulator tracker.
- Xcode: CI's simulator is iOS 26.2 (Xcode 26.2); this Mac has Xcode 26.0.1 / iOS 26.0.1 on macOS 15.7.1. App Store has only Xcode 27.1 (needs macOS 26.6). `xcodes` sign-in said "account locked" (account is fine): not used, uninstalled. Owner may download Xcode 26.2 .xip + iOS 26.2 runtime .dmg from developer.apple.com; then install as /Applications/Xcode-26.2.app and use DEVELOPER_DIR for repro runs only.
- [x] **iOS Safari OOM, round 2: fixed by loading in the same worker** (fllama b0c74d4). See "Investigation: iOS Safari out of memory", round 2.
- [ ] **iOS simulator (native): flutter test misses the VM service line** (run 40265398700, both attempts): the app logged "The Dart VM service is listening" 2 s after launch (our own log stream has it), but flutter_tools' `simctl spawn log stream` never delivered it; flutter waits forever. fllama a677a7a (not pushed yet): an attempt ends 150 s after "Waiting for VM Service port", 3 attempts, `connect_N.txt` diagnostics (log stream processes, `log show` of the line). Real fix candidates: start our own log stream and pass `--host-vmservice-port`? Or report to flutter (simulators.dart starts the log reader on listen, after `simctl launch` is called).
- [ ] **iOS Safari CI (macos-15) is not the code**: with the same-worker fix, all other web cells pass (runs 40273945763, 40278900547); locally iOS 26.3.1 passes even with 13 of 16 host cores busy. On CI: the first request stops after `attach_threadpool` and the page stops answering the 20 s progress script (2 runs); on another job `simctl launch com.apple.mobilesafari` did not return in 5 min, and safaridriver timed out finding Safari 3 times. GitHub: Xcode 26 simulators are "extremely resource-intensive and quite fragile" in its macOS VMs (actions/runner-images 13264, duplicates 13096 etc.). macos-15 has Xcode 26.0.1-26.3 (default 16.4), iOS 26.2 simulators; macos-26 has Xcode 26.6 (default), iOS 26.5. Probe (fllama 0a3ae01): the job on macos-15 and macos-26, with a monitor (top processes, screenshots every 2 min).
  - Result (run 40280431726): **macos-26 passes** (iOS 26.5, 4 CPUs, 3 threads, 6 same-worker loads, no retries, 8 min; Safari's first launch 18 s + 73 s step). macos-15: Safari's first launch did not return again. fllama 9b2b0a4+: the job runs on macos-26 only. Consider native iOS on macos-26 too (its VM-service misses were all on macos-15).
- [ ] **iOS Safari on CI hangs in the first request** (run 40260614748): progress shows `bare_hi`, last console line `attach_threadpool` for 15 min, then the next request waits behind it; the page sometimes did not answer the 20 s progress script. Locally (8-CPU Mac) 1, 2, 4-7 threads all pass. CI simulator: 3 CPUs, default 2 threads. Next run (fllama ca355f9+): matrix default / 1 thread, and `build/web_console.log` in the artifact (the driver now writes the console as it goes).
- [ ] iOS simulator (native) attempt 1 again never got a VM service (8 min); attempt 2 passed (run 40260614748). 2 of the last 4 runs. The retry works; the cause is still unknown.
- [ ] Finish run 40258278183: ios-safari on CI (first run), Android tests on API 37.0, Safari.
- [ ] Two more full runs green in a row before the merge.
- [ ] Merge to `main`, hand-crafted commit by commit (owner). **Draft ready**: local branch `merge/test-cells` (worktree `/tmp/fllama_merge`, not pushed), 8 commits on origin/main 015ff36; its tree = spike minus `spike_test_cells.yml`, minus the kiln_check/kiln_release pin changes, test.yml push branches `[main]`. Rebuild it from the spike when the spike changes (the steps are in "Merge plan"). Open: the kiln_check.yml / kiln_release.yml ci_tools pins (spike has 7c9f879 # main; main has v0.2.2): tag ci_tools and pin the tag at the merge?: separate commits for each fix, one commit for the new test flow. Cleanup at merge: the spike workflow, `web_spike_test.dart`, `spike/test-cells` in test.yml's push branches (TODO in the file), the spike-only commits. See "Merge plan".

### fllama
- [ ] Product question: `contextSize: 0` (the trained size) on Android made a 178,688-token context, a 2 GB KV cache; in a 4 GB emulator (API 37) the low-memory killer ended the app. On a 4 GB phone the same. Should native cap context 0 by free RAM? (CI: 6 GB RAM, fllama test.yml.)
- [x] Carry llama.cpp PR 29150: local branch `carry/llama-cpp-29150` (fllama 6c21e0e, worktree /tmp/fllama_carry, not pushed). `patches/llama.cpp/*.patch`, applied in src/llama.cpp and by build_web.dart; the pin test checks it; the JS log check is gone; web-files cache key covers patches/. Chrome and iOS 26.3.1 pass locally. Push it after the spike run is green; it changes the source key (native jobs build from source, `native_build: auto`) and touches no ggml path (no CUDA pack). Native needs a release before main. Maybe comment on the PR with our iOS case (ask owner).
- [ ] Report the iOS teardown delay to wllama (ngxson), with the repro numbers below. A fix there lets fllama drop the load retry. Ask the owner first.
- [ ] Each load after a model switch costs about 3 s on iOS Safari (retry at 1 s fails, at 2 s succeeds). Find a cheaper signal than retrying: for example avoid the exit/reload (same instance, new params), or poll for free memory as the probe did (`new WebAssembly.Memory` with a 2 GB maximum, ~250 ms per try).
- [ ] **iOS WebGPU support.** Today every iOS Safari test runs on the CPU. In the iOS 26.0 simulator `navigator.gpu` exists, but `requestAdapter()` returns null (`ggml_webgpu: Failed to get an adapter: WebGPU not available on this browser`), so wllama falls back to CPU silently and the report says `webGpu: true`. To find out and do:
  - Is WebGPU on by default in iOS 26 Safari on devices, and is the simulator's null adapter a simulator limit (no Metal device passthrough?) or a setting (Feature Flags)? Check WebKit release notes / bug tracker before testing.
  - Facts (2026-10-25): WebGPU ships in Safari 26 on iOS/iPadOS/visionOS (WebKit blog, Safari 26.0 notes); MacRumors: needs iPhone 15 Pro or later. iOS 27 is out (2026-09-14): check which simulator runtimes macos-15 has, and Safari 27 notes.
  - reeselevine's wllama fork: d605117 is only its example app's model filter (`IOS_WEBGPU_MEMORY_LIMIT = 384 MB`: `min(adapter.limits.maxBufferSize, 384 MB)` on iPhone/iPad UAs), not a library change. Also 37b546e/ecb83ae/7c2fd76 (2026-04-13) "command batching for iOS" in its llama.cpp ggml-webgpu: read those, they may be the real iOS WebGPU fixes.
  - The web test should report whether a GPU adapter was found (not only `navigator.gpu`), and a GPU cell should fail when it ran on the CPU.
  - Memory: WebGPU buffers count against the same tab limit as the WebAssembly heap; recheck the teardown retry with WebGPU.
  - Likely needs a real device (no Metal in CI simulators, see the paravirtual GPU fact): decide with the owner.
- [ ] Real iPhones: hardwareConcurrency is 6, so 5 threads; real-device tab limits are stricter than the simulator (WebKit 291677). Out of the MVP, but the retry/thread default should be checked on a device once.
- [ ] Firefox stalled once (run 40241296726: no output 600 s after the build; normally 167 s). Not seen again in 40245072960, 40248984708, 40258278183. flutter drive prints nothing while tests run, so web-driver's idle limit is also the test-time limit.
- [ ] Watch the first nightly runs for flakes (iOS connect, Safari session, Firefox stall).
- [ ] Force the compat build on Chrome is `compat_solid_red`: done. Safari dart2js tok/s (0.26 on Qwen 0.8B, 3-CPU runner): recheck now that the web default is CPUs - 1.
- [ ] The uncommitted ggml-metal WIP is in fllama `git stash` ("ggml-metal WIP (not PR-able yet)"); `/tmp/wip_backup.patch` is a second copy. Owner: cannot PR it now.

### telosnex_ci_tools
- [ ] Action `ios-simulator`: start CoreSimulator, a fresh simulator, log stream, watchdog, one retry only if no test started, cleanup. Now also needed by web / ios-safari (fllama uses `scripts/boot_ios_simulator.dart --fresh`).
- [ ] Never `git commit -a` in a package checkout that has someone's local work (fllama: uncommitted ggml-metal changes went into 73898ff and started CUDA pack / publish; cancelled before it published).
- [ ] Maybe: an action that caches test downloads by URL and SHA-256 (GGUF models, GPU packs, fonnx models).
- [ ] README: the runner facts below.
- [ ] Later: a shared `kiln_test.yml`, when a second package uses the actions.

### kiln
- [ ] The web files and the native source key. A change to `src/` makes kiln refuse the released wllama files. Owner: web *does* depend on llama.cpp, so no key that ignores `src/`. Done so far: fllama 44bc091 `test/llama_cpp_pin_test.dart` (job llama-cpp-pin) checks that `src/llama.cpp/FLLAMA_LLAMA_CPP_DROP.txt` and `web_build/wllama.json` pin one commit. Open: a web key that covers `src/llama.cpp` and `web_build/` but not `src/fllama*.cpp` (native-only glue). Background: `tool/kiln/build_web.dart` reads only `web_build/` and itself, and clones its own llama.cpp at the pinned commit; local patches in `src/llama.cpp` do not reach web.
- [ ] `native_build: local` with `native_build_dir`, as `web_build: local`. Then `kiln_release` can test the binaries it built before it uploads them.
- [ ] `kiln:build` writes unstripped libraries to a fixed directory in `--out`, so the release workflow need not know the cache layout of each package.

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
- [ ] webcrypto.dart: Safari and the arm runners only. Keep the upstream `test.yml`. Survey (2026-10-25): upstream `test.yml` runs `dart test -p vm,chrome,firefox -c dart2js,dart2wasm` on Linux (xvfb), vm+chrome on macos-15, vm+chrome+firefox on Windows, plus iOS and Android jobs. No Safari, no arm runners.
- [ ] super_native_extensions: upstream `check_and_lint.yml` fails (`actions/cache@v3` is blocked, a clippy rule). Fix or replace it, then add smoke tests. Survey (2026-10-25, native-prebuilt ec61bda): upstream runs `melos exec flutter test` (Linux), cargo clippy (host, Android, iOS) and `cargo test` on an OS matrix. Dart tests are few and shallow; no integration tests. Clipboard and drag-and-drop need a desktop session: a smoke test is an example app on macOS/Windows/Linux (xvfb) that writes and reads the clipboard. The 3 legacy `index.html` files: fixed on local branch `example-flutter-bootstrap` (8bc1a43), not pushed.

## Merge plan (fllama)

**MERGED 2026-10-26:** main 015ff36..14be8d8 (fast-forward, the 11 draft commits). First main run: 40340468816. Deleted: kiln-release, kiln-manifest/native-3741625c6cb9b61d, local carry/merge branches and /tmp worktrees. Keep spike/test-cells until main's run is green, then delete it.

**Status 2026-10-26:** ci_tools tagged v0.4.0 (c77f43a); fllama pins it in test.yml, kiln_check.yml, kiln_release.yml (spike 3b0d1c5-ish, "Workflows: Telosnex/telosnex_ci_tools v0.4.0"). Two full green runs (40285438371, 40290245554). Release native-3741625c6cb9b61d published from the draft tree 7ac88b0 (run 40335981965, all jobs green incl. web-test); its manifest commit 14be8d8 is on the local draft, `kiln:check` ok. The draft (11 commits on origin/main 015ff36) is ready for the owner to merge; not pushed to main. contextSize 0 stays as is (owner). No upstream contact (owner).

Draft branch `merge/test-cells` (local, worktree /tmp/fllama_merge), made by `/tmp/build_merge.sh` (rerun it after each spike change; copy it into the repo's dev/ if it must last). From origin/main it applies only the `lib/`/`src/`/`web_build/` parts of the spike's library commits (`git diff C^ C -- paths | git apply --3way`, then `kiln:web stamp`), whole files at the spike's state for the rest, then the carry branch. 10 commits (2026-10-26):
1. Native: skip a GPU that cannot run the ops of every model; the image encoder follows numGpuLayers (5487175).
2. Web: fllamaWebRuntimeInfoJs (7f33590).
3. Web: mmproj from the wllama cache (d19f341).
4. Thread defaults (a6760c8, aee2ac8).
5. Web: load again after an out-of-memory; reject an mmproj load without its compute buffer (8563988).
6. Web: load in the same worker (b0c74d4).
7. Test: llama.cpp pin check.
8. Example: index.html loads flutter_bootstrap.js.
9. CI: test.yml and the test files (push branches `[main]`).
10. Carry llama.cpp PR 29150 (6c21e0e).
Checked: lib/src/native_artifacts/web_build/patches/tool/test/docs equal the spike + carry; the JS of every commit parses; analyze clean. Left out: spike_test_cells.yml, the kiln_check/kiln_release pin changes, generated_plugins.cmake (a spike commit swept in a regenerated file; main's is kept). Open: tag ci_tools and pin the tag in kiln_check/kiln_release at the merge? A native release before the merge (src changed).

## Investigation: iOS Safari out of memory (2026-10-25)

Setup: iOS 26.0 simulator (iPhone 16), `flutter drive --browser-name ios-safari`, safaridriver, web files from `/tmp/fllama_web` (`web_build: local`). Runner script `/tmp/ios_run.sh <tag> [--dart-define=FLLAMA_TEST_THREADS=n]`; the report has the page console under `console`. hardwareConcurrency is the Mac's 8.

Symptoms (before the fix), by the test's thread count:
- 7 (the new default): `mmproj_hi` ABORT, then every later load "Cannot allocate WebAssembly.Memory". Sometimes only `compat_solid_red` fails: it varies run to run.
- 5 and 6: only `compat_solid_red` (the 7th load) ABORTs. 4: all pass. The old cap of 4 (made up in 727e779; wllama's own default is CPUs / 2) hid this.
- Desktop Safari, same Mac, 7 threads: all pass. Chrome, 15 threads: all pass, no retries.

Measured:
- Fresh page: one shared memory can grow to ~2624 MB; a second one while the first is alive cannot be created. After dropping the first, space is back only later (5 s later: a 4 GB maximum is reservable again).
- Logged in the compat glue: with 7 threads the heap fails to grow at 1330-1441 MB (`RangeError: Out of memory`), so `ggml_aligned_malloc: insufficient memory` / ABORT. With 4 threads it reaches 1790 MB.
- `getWasmMemory` reserves the full 4096 MB on the first try: not the old wllama #18/#23 problem.

Ruled out, one at a time: the 4 GB reservation; idle workers (28 idle workers do not change headroom); pthread pool 1x vs 2x the threads; a 2 MB pthread stack instead of 16 MB (`STACK_SIZE=16MB` is also emscripten's pthread default); `PThread.terminateAllThreads()` before `worker.terminate()`.

Cause: after `wllama.exit()` (worker terminate) iOS WebKit returns the old instance's shared WebAssembly memory only some seconds later; fllama exits and reloads whenever the request needs other load params. A 5 s wait before each load fixed every case; 1 s did not; 1 + 2 s did. Fits WebKit bug 250569 (terminated worker memory) and Kandelo's note on JSC not freeing workers blocked in `Atomics.wait`. Upstream wllama (ngxson, 19 commits after our pin 766d28e) has nothing about memory or exit; reeselevine's fork caps iOS *WebGPU* buffers at 384 MB (d605117), not CPU.

Second bug found on the way: with no memory for the mmproj compute buffer (161 MB), clip.cpp ignores `ggml_backend_sched_reserve`'s result, the load reports success, and every image request aborts (`GGML_ASSERT(buffer)`). llama.cpp PR 29150, open. Native has the same bug.

Fix (fllama 8563988): `fllama_web_init.js` loads again after 1, 2, 4 s on a WebAssembly memory error, and fails a load whose log has `failed to allocate` / `insufficient memory`. Result: iOS Safari passes with 7 threads, 2 of 2 runs (each reload after a model switch: retry at 1 s fails, at 2 s succeeds). Chrome: no retries.

Temporary experiment edits were all reverted (`/tmp/fllama_web` restored from `/tmp/fllama_web_index.js.orig` and `/tmp/compat_wllama.js.orig`; the probe test removed).

### Round 2 (2026-10-25 evening): iOS 26.3.1

- Xcode 26.2 (owner downloaded the .xip) at `/Applications/Xcode-26.2.app`, only via `DEVELOPER_DIR`. Apple no longer offers the iOS 26.2 simulator; Xcode 26.2 installs iOS 26.3.1 (23D8133). Simulator `fl-263`.
- On 26.3.1 the fix of round 1 fails: the 3rd load and every later one cannot reserve memory (`getWasmMemory`), retries at 1/2/4 s do not help, and the next request hangs ("Downloading model files", no progress): this is the CI hang.
- Measured: free memory after each ended wllama worker 4096, 3840, 2816, 768, 0 MB; waiting 90 s or forcing GC does not bring it back. A plain worker with a 1.5 GB shared memory and 7 threads in `Atomics.wait`, ended 4 times: memory comes back every time. So it is specific to the wllama/emscripten worker, not plain workers.
- Most reloads were only `nParallel` 1 <-> 2 (same files).
- wllama head (ngxson 3bb2a46) has the same teardown: `exit()` = `worker.terminate()`; `wllama_exit()` only `llama_backend_free()`, `app.unload()` commented out. Head has, from PR 270: one wasm call at a time (`runWasmCall`), `noWebGPU` with n_gpu_layers 0, n_parallel/kv_unified upstream, a cancel action. Rebase on head later.
- Fix (fllama b0c74d4, in web_build/wllama.patch): `wllama_unload` (C++; `app` is a pointer, deleted and made new; a JSPI/Asyncify export, as WebGPU teardown suspends: without it Chrome aborted in `llama_free`); `ProxyToWorker.replaceFiles` (async file reads only: files are read from the blobs, no heap copy); `Wllama.reuseWorker`: `loadModel()` on a live instance unloads and loads in the same worker; refuses (before unloading) more threads or another build (compat). fllama sets `reuseWorker`, reuses when GPU layers are the same and threads not more, else (or on a failure) a new worker as before. The start/load key is now logged in full.
- Results, 7 threads, all pass: iOS 26.3.1 2 of 2 (1-2 workers per run, no retries), iOS 26.0, Chrome (6 same-worker loads; 2 new workers: the compat test, the invalid-URL test).
- Local web build: OrbStack, image `fllama-emsdk-dart` (the pinned emsdk image + Dart 3.13.1, arm64), `/tmp/build_web.sh <out> [patch]` (~4-5 min; `FLLAMA_SRC=` for another checkout). **Reproducible** (2026-10-26): with `--work /tmp/fllama_web_build` (as the release; `__FILE__` paths go into the wasm) and the linux/amd64 image (`fllama-emsdk-dart:amd64`, under emulation, ~19 min), all 5 files are byte-identical to release native-47a361cf63e78751. On arm64 the compat wasm is identical too; the default (JSPI/Memory64) wasm differs in 43 bytes of one function (code generation differs by host arch). Daily work: arm64; a release check: amd64.
- CI: job `web-files` builds the wllama files of the commit in the emsdk image (cache key: web_build/** and build_web.dart); the web jobs download them. `scripts/fetch_web_release.dart` is now only for local use.
- Rebase on wllama head: our patch has conflicts in CMakeLists.txt, glue.hpp, wllama-context.h, types.ts, wllama.ts; head pins another llama.cpp, and native and web pin one llama.cpp (llama-cpp-pin test), so it is a llama.cpp update for native too. A separate change.
- Open: the 4.0 retry code stays as a fallback. A new mmproj (other files) still uses the same worker now (replaceFiles), so only a build/thread change ends a worker.

## Mobile browsers (fllama web)

- iOS Safari: `flutter drive --browser-name ios-safari` (safaridriver, `safari:useSimulator`), in a booted simulator; localhost is the Mac's. Compat build, cross-origin isolated, about 1 min locally. ci_tools 1e4c4ce `web-driver` takes `ios-safari`; fllama test.yml job `web-ios-safari` boots with `scripts/boot_ios_simulator.dart --fresh`. The simulator does not enforce iPhone tab memory limits (WebKit 291677), so it catches less than a device.
- Android Chrome: works locally (API 36 Play image, arm64, Chrome 133: compat build, 3 threads, all pass). Needs:
  - `adb reverse tcp:P tcp:P` with `--web-port P --no-android-emulator`. Flutter's `--android-emulator` mode rewrites the URL to 10.0.2.2: not cross-origin isolated ("No supported storage backend").
  - `/data/local/tmp/chrome-command-line` with `--disable-fre --no-first-run`.
  - chromedriver: Chrome for Testing, latest of the device's milestone (the exact build can be missing: 133.0.6943.137 was, 133.0.6943.141 works).
  - An 8 GB data partition: Chrome 154 on the default AVD failed with QuotaExceededError in OPFS (model copy).
  - ci_tools 1e4c4ce `web-driver` takes `android-chrome`; fllama job `web-android-chrome` on API 37.0 (Chrome 145).
- Emulator images (sdkmanager, 2026-10-25): newest stable x86_64 is android-37.0 google_apis / google_apis_playstore (rev 8); 37.2 is arm64 beta only. Chrome built in: API 35 124, API 36 133, API 37.0 145. Local arm64 37.0 images segfault on boot on this Mac (QEMU threads hang), with and without swiftshader.
- Play Store image: has the Play Store, but updating Chrome needs a Google sign-in. Not a CI path. Owner: track the newest Android image instead.
- Real-device memory, thermals and GPU need real devices: out of the MVP.

## Runner facts

- macos-15 has 3 CPUs. ubuntu-24.04, ubuntu-24.04-arm and the Windows runners have 4.
- macos-15's GPU is "Apple Paravirtual device": no Apple6-9 or Metal3 family, so ggml-metal has no simdgroup kernels.
- ubuntu-24.04 has `/dev/kvm`. ubuntu-24.04-arm has none, so no Android emulator cell there.
- Preinstalled: Chrome 155 with `$CHROMEWEBDRIVER`, Firefox 157 with `$GECKOWEBDRIVER` (Linux), Safari 26.6.1 with `safaridriver` (needs `sudo safaridriver --enable`).
- On a fresh macOS runner the first `simctl` call starts CoreSimulator, and can take more than 1 minute.
- `adb` is not on `PATH` on ubuntu-24.04: use `$ANDROID_HOME/platform-tools`.
- Flutter runs dart2wasm builds only in Chromium unless the app sets `wasmAllowList`. Firefox and Safari users get dart2js.
- `flutter drive -d web-server` reads `web_dev_config.yaml`, so it can send COOP/COEP headers. `flutter drive` does not capture the browser console: the web test keeps it itself.
- Playwright's Firefox runs WebAssembly about 10 times slower than stock Firefox and has no JSPI. Use stock browsers.
- Windows: on a `shell: bash` step, `dart` is Flutter's wrapper (bin/dart, then dart.bat). It leaves `OS=MINGW64_NT...`, `FLUTTER_ROOT` etc. in the environment, and every `flutter` started below it then fails in flutter.bat (`bash: D:a_tempflutter/bin/internal/exit_with_errorlevel.bat`). Start `bin/cache/dart-sdk/bin/dart.exe` directly (ci_tools e1d108c).
- kiln reads `web_build` / `web_build_dir` from `<kiln cache>/defaults.json` since 0.1.2 (`~/Library/Caches/kiln` on macOS, `~/.cache/kiln` on Linux). `web_build_dir` there must be absolute.

## Local machine facts

- Windows debugging: the Parallels `Windows 11` VM (ARM64), Git and Flutter installed. Use telosnex `dev/prlctl.dart run --vm "Windows 11" ...` (base64 scripts and files; `prlctl exec` mangles quotes and fails over ~4,000 characters). Clone repos there from GitHub.
- Desktop Safari automation takes over the whole Mac: avoid it unless it settles a Safari question (owner). Remote automation is enabled in Safari's settings.
- iOS simulator: iOS 26.0 runtime, `xcrun simctl create fl-safari "iPhone 16"` (4BD400A8-...).
- Android: SDK at `~/Library/Android/sdk`; AVD `Medium_Phone_API_36.0` (Play image, 1 core, small disk); `/tmp/avd36` has `ci36` (4 cores, 8 GB disk). The emulator dies when the agent's command ends: boot and test in one command. Downloaded arm64 37.0 images (8 GB) do not boot here; can be deleted.
- wllama checkouts: `~/dev/wllama` and `~/dev/wllama-stock` track reeselevine's fork; `~/dev/wllama-stock` has remote `ngxson` (upstream, where our pin is).

## Decisions

- 2026-10-25: No version tag for telosnex_ci_tools until the first consumer (fllama) is through. Consumers pin the commit SHA with `# main`.
- 2026-10-25: Web tests use `flutter drive` with stock browsers, not Playwright.
- 2026-10-25: No dart2wasm cells for Firefox and Safari, also not nightly. Flutter needs an opt-in for them; revisit when Flutter supports them by default.
- 2026-10-25: Android arm emulators, real devices and Edge are out of the MVP. Mobile browsers are **in** (owner changed this): iOS Safari in the simulator, Chrome on the newest Android emulator image.
- 2026-10-25: Track the newest Android emulator image (37.0 today); no Play Store updates, no third-party APKs.
- 2026-10-25: Thread default: native physical cores - 1 (at least 1), web logical CPUs - 1, no cap. A set `numThreads` is used as is.
- 2026-10-25: Native and web pin one llama.cpp commit, checked by a test (not a web key that ignores `src/`).
- 2026-10-25: `web_build: local` for CI comes from kiln's `defaults.json`, as `native_build` (kiln 0.1.2, published).
- 2026-10-25: Carry llama.cpp PR 29150 eventually.
- 2026-10-25: Merge to `main` commit by commit, with cleanup at the merge.

## Log

- 2026-10-25: fllama spike started. The failures it found and their causes:
  - A `--wasm` build with the legacy `index.html` stalled: the loader ran `main.dart.js`.
  - The Firefox and Safari Wasm stalls: Flutter's loader rejects Wasm outside Chromium.
  - The linux-arm64 1 s pause and the earlier iOS hang: 4 decode threads on 4 or 3 CPUs.
  - Metal on macos-15: a paravirtual GPU without the kernels, then a crash in the image encoder.
- 2026-10-25: web tests were not testing. `test()` results do not reach `flutter drive`, and the job's `| tee` hid a compile failure for 3 runs. Real fllama bug found: wllama's model cache keys by URL only, so a model cached for a text request loaded again without mmproj and images were ignored.
- 2026-10-25: iOS simulator stall: once, the app's VM service listened but `flutter test` never connected; a later false stall was the watchdog timing the Xcode build. Fix: build in its own step (63ca01c). Not seen since.
- 2026-10-25: Windows `watch` failures: two wrong fixes (which bash) before the VM reproduced it; the cause was Flutter's dart wrapper environment (above).
- 2026-10-25: iOS Safari OOM: the deep dive above. Lesson: read the upstream repos, issues and history first (owner).
