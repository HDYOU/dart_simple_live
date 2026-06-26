# Project Experience: dart_simple_live

This file records reusable lessons for this project. Keep entries short, actionable, and free of secrets.

## Project Facts

- Project root: C:\softwares\dart_simple_live
- Created: 2026-05-23

## Entries
### 2026-05-23 | workflow | Self-hosted sync backend

- Lesson: Remote sync no longer uses sync1.nsapps.cn. Backend repo is C:\Files\项目\simple-live-sync-server; Flutter clients keep SignalRService API but use web_socket_channel and 6-char room codes. Deploy Cloudflare first, then update SignalRService.kDefaultUrl in main and TV apps.

### 2026-05-23 | workflow | Build permission rule

- Lesson: Before builds ask whether GitHub should build. Default: Android, Windows, Linux, and TV are built locally; iOS/macOS may use GitHub Actions only after explicit confirmation. Upload network fallback uses local proxy 127.0.0.1:51888; do not trigger GitHub builds just because local upload is slow.

### 2026-05-28 | workflow | Local multi-platform build order

- Lesson: Do not run Windows Flutter and WSL Flutter against `simple_live_app` in the same working tree at the same time. WSL `flutter pub get` rewrites `.dart_tool/package_config.json` with `/root/...` package paths; Windows/Android builds then fail with many “Error when reading '/root/...'” imports. Build Linux in WSL first or in a separate copy/worktree, then run Windows `flutter pub get` before Windows/Android builds.

### 2026-05-28 | failure | media_kit release assets

- Lesson: Windows and Linux release builds can leave truncated GitHub archives in `build/` and then fail CMake integrity checks. Known manual proxy downloads: `mpv-dev-x86_64-20230924-git-652a1dd.7z` MD5 `a832ef24b3a6ff97cd2560b5b9d04cd8`, `ANGLE.7z` MD5 `e866f13e8d552348058afaafe869b1ed`, `mimalloc-2.1.2.tar.gz` MD5 `5179c8f5cf1237d2300e2d8559a7bc55`. Use `curl.exe -L --proxy http://127.0.0.1:51888` to prefill the exact `build/...` path, then rerun Flutter.

### 2026-05-28 | failure | Android 32-bit quickjs asset

- Lesson: `flutter build apk --release` and TV `--split-per-abi` currently fail when installing native assets for `armeabi-v7a`: missing `.dart_tool/hooks_runner/shared/dart_quickjs/.../libdart_quickjs.so`. `--target-platform android-arm64` is a working release path for modern phones/TV; 32-bit APK needs a separate dart_quickjs/native asset fix before publishing.

### 2026-05-28 | failure | Windows CMake install prefix

- Lesson: Windows release can compile successfully but fail at `INSTALL.vcxproj` because `CMAKE_INSTALL_PREFIX` defaults to `C:/Program Files/simple_live_app`, which normal user permissions cannot create. When this happens, inspect `simple_live_app/build/windows/x64/CMakeCache.txt` and redirect `CMAKE_INSTALL_PREFIX` to a project-local bundle/install directory before rerunning the install step; do not require admin rights just for packaging. Verified fix: use Visual Studio bundled CMake at `C:/softwares/Visual Studio Workspace/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe` to set the prefix to `build/windows/x64/runner/Release`, then rerun `flutter build windows --release`.

### 2026-05-28 | failure | Linux CMake install prefix

- Lesson: Linux release can print `Built build/linux/x64/release/bundle` while the actual `CMAKE_INSTALL_PREFIX` remains `/usr/local`, leaving no project-local bundle. If `build/linux/x64/release/bundle` is missing, run WSL Flutter `pub get` first so package paths are Linux-native, then run CMake with `-DCMAKE_INSTALL_PREFIX:PATH=/mnt/c/softwares/dart_simple_live/simple_live_app/build/linux/x64/release/bundle` and `--target install`. Afterward run Windows `flutter pub get` to restore `.dart_tool` for Windows/Android.

### 2026-05-28 | workflow | Douyin account search and TV fallback

- Lesson: Douyin room/anchor search needs logged-in web cookies when the search API returns login-required status. Main app can obtain cookies through WebView QR login and use them for search; TV should not rely on opening a browser, so it receives Douyin account cookies via LAN sync from the main app.

### 2026-05-29 | failure | Windows apply_patch invocation

- Lesson: In this repo on June's Windows desktop, the temporary `apply_patch.bat` can fail with `Access is denied` because it points at WindowsApps `codex.exe`, and PowerShell/cmd quoting breaks multi-line patches that contain Chinese, quotes, or `$` variables. Use the npm Codex CLI through a Node `spawnSync` wrapper that reads a UTF-8 patch file and passes the patch as a single argv item to `@openai/codex/bin/codex.js --codex-run-as-apply-patch`.

### 2026-05-29 | workflow | Android PiP routing split

- Lesson: Auto PiP must not run from live-room route back actions. In-app back should cancel `OnLeavePiP` and pop to the app home; manual PiP uses `ImmediatePiP`; background auto PiP uses `OnLeavePiP` and is configured only for system leave/Home gestures. Keep player state alive on PiP exit and avoid clearing the video/danmaku layer unless the user explicitly leaves the room.

### 2026-05-29 | workflow | Android 32-bit release build recovery

- Lesson: If `armeabi-v7a` Android/TV release previously failed around native assets, retry a fresh single-ABI build after `flutter pub get`: `flutter build apk --release --target-platform android-arm`. On v1.12.4/tv_1.7.5 both main App and TV 32-bit builds passed this way, and TV x86_64 also passed with `--target-platform android-x64`. Prefer single-ABI builds when split-per-abi is fragile, then copy each `app-release.apk` to the release directory with ABI-specific names.

### 2026-05-29 | workflow | Douyin emoji, subtitle model cache, and global danmaku dedupe

- Lesson: Douyin chat emoji should be parsed from `ChatMessage.rtfContent.piecesList` in order, not by appending background/gift images. Keep `LiveMessage.imageUrls` for old renderers and add ordered spans for chat UI. Main app and TV can share the same duplicate-danmaku fingerprint logic: `userName + content` within a bounded recent window, default off, O(window) memory.
- Model cache: Subtitle recommendation files are stored locally under `C:\softwares\dart_simple_live\models` and ignored by git. Current folders: `advanced-whisper-large-v3-int8`, `middle-paraformer-zh-int8`, `sweet-zipformer-bilingual-zh-en-int8`.
- Network: For GitHub raw/HuggingFace downloads on this machine, use `socks5h://127.0.0.1:51888` explicitly with `curl.exe --proxy socks5h://127.0.0.1:51888 -L ...`.

### 2026-05-31 | workflow | Subtitle ASR boundary and model file UX

- Lesson: Real-time subtitles need two separate pieces: an ASR runtime/model loader and a player audio PCM input. Adding `sherpa_onnx` plus model-file validation is not enough to produce subtitles until media_kit/libmpv audio samples are exported or captured. Do not show fake preview text as if recognition works; show explicit "audio input pending" status.
- Model UX: Let users pick the key ONNX file, then infer and validate sibling files in that directory. Current key files are `model.int8.onnx` for Paraformer, `large-v3-encoder.int8.onnx` for Whisper, and `encoder-epoch-99-avg-1.int8.onnx` for Zipformer.
- UI: Long Windows model paths should show basename plus a two-line truncated status/diagnostic, never the full path in a trailing value that expands the settings row.

### 2026-05-31 | workflow | Danmaku dedupe fingerprints

- Lesson: Duplicate danmaku filtering should fingerprint the normalized user name plus all visible payload pieces, not only `message`: include rich text spans and image URLs so emoji, Douyin expression images, and unusual Unicode text are handled consistently. Keep a bounded queue plus count map and reset it on room refresh/change.

### 2026-06-05 | workflow | Thanks and sponsor attribution

- Lesson: `THANKS.md` is for original/upstream projects, public resource references, and sponsors. Do not add people just because they filed issues or requested features. Sponsor names are opt-in: if a WeChat sponsor wants anonymity, write “匿名微信用户” / “一位赞助用户” and never infer or publish a GitHub handle. Only use `@username` after explicit consent; issue links may be included only as background for a sponsor’s related feedback.

### 2026-06-06 | workflow | Fix release upload and Action artifact proxy

- Lesson: For dart_simple_live fix releases, keep tag and app version unchanged, force tags to the fix commit, build Android/Windows/Linux/TV locally, and only trigger macOS/iOS Actions with upload_release=false. Download Action artifacts through 127.0.0.1:51888; gh run download can hang on large artifacts, so prefer artifact API zip URLs plus curl.exe --proxy http://127.0.0.1:51888, then rename files with -fix before gh release upload. Upload new -fix assets first, verify them, then delete old non-fix assets only from the current release tags.

### 2026-06-06 | failure | Live-room SmartDialog loading can leave gray overlay

- Lesson: Do not use a global SmartDialog loading barrier for live-room loadData on desktop. If a load is superseded, refreshed, or disposed before finally runs as current generation, the barrier can remain over an otherwise loaded room and look like a Windows white/gray screen. Use in-page system messages/logs for live-room loading instead.

### 2026-06-06 | workflow | Follow status refresh concurrency policy

- Source: C:\softwares\dart_simple_live
- Lesson: 关注状态刷新保持后台自动并发，不开放给用户手调。当前阈值：关注数 <=300 用 48，301-1000 用 32，1001-3000 用 20，3001-5000 用 12，>5000 用 8；手动刷新可以绕过 30 秒关注状态冷却，定时/自动刷新仍受冷却保护，避免大量关注用户反复叠加网络任务。TV 和主 App 要保持同一套阈值。

### 2026-06-06 | failure | WSL Linux deb packaging from PowerShell

- Source: C:\softwares\dart_simple_live release packaging.
- Lesson: 从 PowerShell 调 WSL 打 Linux deb 时，不要在一行命令里混用 Bash `$变量`、here-doc、管道和 Windows 临时脚本默认编码。PowerShell 可能吞掉 `$变量`，`Set-Content -Encoding UTF8` 会写 BOM，CRLF 会让 Bash 路径末尾带 `\r`，而在 `/mnt/c` 直接搭 deb 目录会因 NTFS 权限映射成 777 导致 `dpkg-deb` 拒绝。
- Next action: Linux zip 可在 WSL bundle 目录显式压 `data lib simple_live_app`。deb 应在 WSL `/tmp` 组装包目录，脚本用 ASCII/UTF-8 no BOM 且 LF 行尾，保留 `/opt/simple-live`、`/usr/bin/simple-live`、desktop 文件和 icon，`dpkg-deb --build` 后再把成品移回 `release/fix-*`。

### 2026-06-10 | workflow | TV-windows build is not main Windows or Android TV

- Source: User correction after rebuilding `SimpleLiveTV-Windows.zip`.
- Lesson: When the user says `build TV-windows`, `TV Windows`, or asks for the TV Windows package, use `C:\softwares\dart_simple_live\simple_live_tv_app`, not `simple_live_app`, and not Android TV. Run Windows Flutter there: `flutter build windows --release`.
- Packaging rule: The distributable folder is `simple_live_tv_app\build\windows\x64\install`. Zip the contents of `install`, not `runner\Release` and not the parent build folder. Output path: `simple_live_tv_app\build\windows\x64\SimpleLiveTV-Windows.zip`.
- Sanity check: after packaging, inspect the zip and confirm it contains `simple_live_tv_app.exe`, `flutter_windows.dll`, `libmpv-2.dll`, plugin DLLs, and `data\flutter_assets`. Also report the zip `CreationTime`, `LastWriteTime`, size, and SHA256.
- Distinguish names: `Windows build` without TV usually means main app under `simple_live_app`; `TV build` usually means Android TV APK under `simple_live_tv_app`; `Android build` usually means main app APK under `simple_live_app`; `TV-windows` means TV app compiled for Windows under `simple_live_tv_app`.

### 2026-06-10 | workflow | One-click release build script

- Source: C:\softwares\dart_simple_live\tools\build-release.ps1
- Lesson: Use `tools\build-release.ps1` as the local release build entry. `-Target AllLocal` builds Windows, Android, TV-Windows, and Android TV into `release\<version-dir>`; `-KeepBuild` keeps intermediate build directories; default cleanup removes touched `simple_live_app\build` / `simple_live_tv_app\build` only after successful artifact copy and verification. iOS/macOS/Linux Actions require explicit `-AllowGitHubActions`.

### 2026-06-10 | workflow | Release cleanup must preserve final artifacts

- Source: User correction after TV-Windows verification cleanup and Gradle hold-open cleanup.
- Lesson: `release` is the final artifact station, not a disposable verification folder. After any successful build, leave at least one final usable artifact under `release\<version-dir>`; only delete temporary verification directories when another final artifact has been preserved. Build and Gradle can keep files open briefly, so treat late `Remove-Item` failures as cleanup problems and retry after stopping daemons; never remove the newly produced release zip/apk/dmg/deb/ipa.

### 2026-06-10 | failure | TV-Windows multi-open gray screen

- Source: TV-Windows runner and secondary-instance debugging.
- Lesson: TV-Windows multi-open needs both Dart-side secondary handling and Windows-runner secondary detection. The Dart side can pass `--simple-live-secondary-instance`, create `tv_instances\<timestamp>_<pid>` Hive snapshots, and open startup rooms, but manual/external second launches still need `simple_live_tv_app\windows\runner\main.cpp` to use a TV-specific primary mutex (`June6699.SimpleLiveTV.PrimaryInstance`) and append `--simple-live-secondary-instance`.
- Diagnostic: TV-Windows startup writes `tv-windows-startup.log` under the app support `log` directory with args, secondary flag, Hive snapshot path, window bounds, and startup room. If gray screen returns, check this log first to see whether the second process entered secondary mode and copied Hive files.

### 2026-06-10 | failure | Desktop mpv profile can spawn external player window

- Source: TV-Windows embedded player fix after `Simple Live Player` appeared beside `Simple Live TV`.
- Lesson: On Windows/Linux/macOS, `media_kit_video` must keep `VideoControllerConfiguration.vo` unset so the native backend defaults to `libmpv` and renders inside Flutter. Passing profile values such as `vo=gpu` or `vo=gpu-next` into `VideoControllerConfiguration` makes mpv open its own `Simple Live Player` window, separating video from the Flutter danmaku layer.
- Rule: Desktop mpv profiles may still apply quality options (`profile`, `scale`, `cscale`, `deband`, etc.) to the `Player`, but do not override `vo` for embedded Flutter playback. Android can still pass Android-specific `vo` values through `VideoControllerConfiguration`.

### 2026-06-11 | workflow | Gradle cleanup can lag behind successful release builds

- Source: `tools\build-release.ps1` after successful Windows + Android v1.12.6 build.
- Lesson: Flutter/Gradle may finish APK generation but keep a lint cache jar handle open briefly, causing `Remove-Item simple_live_app\build -Recurse` to fail and making the whole release script look failed even though artifacts were already copied. Stop Gradle daemons with `android\gradlew.bat --stop` before cleanup and retry Windows directory deletion a few times.
- Rule: Successful release builds should leave artifacts and `RELEASE_NOTES.md` in `release\<version>`, but successful transient logs can be removed; failed builds keep `logs` and build directories for inspection.

### 2026-06-12 | failure | Windows release install prefix must be local

- Source: tools\build-release.ps1 and direct `flutter build windows --release`.
- Lesson: Windows release can compile but fail at `INSTALL.vcxproj` because `CMAKE_INSTALL_PREFIX` still points to `C:/Program Files/simple_live_app`. Inspect `simple_live_app/build/windows/x64/CMakeCache.txt`, redirect the prefix to a project-local package directory, and keep the build tree for inspection until the fix is verified.

### 2026-06-12 | failure | Build-release network and asset retries need proxy sanity

- Source: tools\build-release.ps1
- Command: `cd C:\softwares\dart_simple_live\simple_live_app; & C:\softwares\flutter\bin\flutter.bat pub get`
- Lesson: `pub get` and release asset fetches can fail on this machine when the local proxy is down, a path is wrong, or a generated host string is malformed. Confirm v2rayN is running on 127.0.0.1:51888, then check ref/auth/path/release/tag/cache before retrying.

### 2026-06-12 | failure | TV release asset downloads are proxy-sensitive

- Source: tools\build-release.ps1
- Command: `Target=TVWindows,TVAndroid; ReleaseDir=C:\softwares\dart_simple_live\release\tv_v1.7.7`
- Lesson: TVWindows and TVAndroid release runs may spend time downloading Flutter and media-kit assets before the real failure appears. When this happens, keep the logs, verify the proxy and remote asset availability, then rerun the failed target instead of assuming the first download warning was the root cause.

### 2026-06-12 | workflow | Release rebuild decision and cleanup-failure triage

- Lesson: 判断 `release` 目录里的 APK/zip 要不要重建时，至少同时核对源码 `LastWriteTime`、产物 `LastWriteTime`、以及最新构建的 `SHA256`。只看文件存在与否不够。
- Lesson: `tools\build-release.ps1` 如果在产物已经复制完成后，最后因为删除 `release\<tag>\logs\*.log` 这类被占用文件而报错，应先把它归类为“清理失败”而不是“编译失败”。先验收最终产物，再决定是否需要补跑。

### 2026-06-12 | workflow | Windows follow page large-list first paint

- Source: Windows follow page debugging after v1.12.6 rebuild.
- Lesson: For 7000+ follows, entering the follow page must not auto-trigger a full status refresh. Load the local list first, and only refresh statuses on explicit user action.
- Lesson: On Windows desktop, a fixed `GridView` is more stable than `MasonryGridView` for very large follow lists and reduces first-page stalls.

### 2026-06-12 | failure | Windows quickjs DLL can be missing from final package

- Source: Windows Douyin category error `Couldn't resolve native function 'JS_NewRuntime'` with missing `dart_quickjs.dll`.
- Lesson: Do not trust `build\native_assets\windows` as the only source of `dart_quickjs.dll`. In this repo the DLL may exist only under `simple_live_app\.dart_tool\hooks_runner\shared\dart_quickjs\build\...\dart_quickjs.dll`.
- Packaging rule: before publishing a Windows main-app zip, verify the zip contains `simple_live_app.exe`, `dart_quickjs.dll`, and `data\flutter_assets\NativeAssetsManifest.json`.
- TV-Windows has the same requirement: verify `simple_live_tv_app.exe`, `dart_quickjs.dll`, and `data\flutter_assets\NativeAssetsManifest.json`. If the final TV-Windows zip reports `JS_NewRuntime` / error 126, copy the newest TV `.dart_tool\hooks_runner\shared\dart_quickjs\...\dart_quickjs.dll` into the package root and rezip before publishing.

### 2026-06-12 | workflow | Temporary combined release directory is staging only

- Source: local multi-target build output under `release\v1.12.6_tv_v1.7.7`.
- Lesson: Treat combined release directories as temporary staging only. If artifacts are later copied into formal release directories (`release\v1.12.6`, `release\tv_v1.7.7`), update the final `RELEASE_NOTES.md` files to match the real final artifacts and SHA256 values, then delete the combined staging directory.

### 2026-06-13 | failure | Android quickjs native asset missing from APK

- Source: TV Android runtime error `Couldn't resolve native function 'JS_NewRuntime'` / `libdart_quickjs.so not found`.
- Lesson: Windows quickjs packaging checks do not cover Android. After every Android or TVAndroid release, inspect each APK and verify it contains `lib/<abi>/libdart_quickjs.so` for `armeabi-v7a`, `arm64-v8a`, and `x86_64`. The dart_quickjs hook can compile the `.so` under `.dart_tool\hooks_runner\shared\dart_quickjs\build\<id>\libdart_quickjs.so` while Gradle still omits it from the final APK unless it is synced into `android\app\build\generated\dart_quickjs\jniLibs`.
- Fix: `simple_live_app` and `simple_live_tv_app` Gradle configs now include generated quickjs `jniLibs`, and `tools\build-release.ps1` syncs/verifies quickjs APK entries before copying release APKs.

### 2026-06-19 | failure | Build script: windows-build

- Source: tools\build-release.ps1
- Command: `cd C:\softwares\dart_simple_live\simple_live_app; & C:\softwares\flutter\bin\flutter.bat build windows --release`
- Log: `C:\softwares\dart_simple_live\release\v1.12.6\logs\windows-build.log`
- Symptom: ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(55,22): error G297C951C: Can't find ')' to match '('. [C:\ softwares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(55,15): error G297C951C: Can't find ')' to match '('. [C:\ softwares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(59,18): error G67247B7E: Expected ':' before this. [C:\sof twares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(59,18): error G25387D61: Expected an identifier, but got ' ;'. [C:\softwares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/...
- Next action: If INSTALL.vcxproj fails, inspect CMAKE_INSTALL_PREFIX and redirect it to a project-local package directory.

### 2026-06-19 | failure | Build script: build-release.ps1

- Source: tools\build-release.ps1
- Command: `Target=Windows; ReleaseDir=C:\softwares\dart_simple_live\release\v1.12.6`
- Log: `C:\softwares\dart_simple_live\release\v1.12.6\logs`
- Symptom: ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(55,22): error G297C951C: Can't find ')' to match '('. [C:\ softwares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(55,15): error G297C951C: Can't find ')' to match '('. [C:\ softwares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(59,18): error G67247B7E: Expected ':' before this. [C:\sof twares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/douyin_cookie_helper.dart(59,18): error G25387D61: Expected an identifier, but got ' ;'. [C:\softwares\dart_simple_live\simple_live_app\build\windows\x64\flutter\flutter_assemble.vcxproj] ../simple_live_core/lib/src/common/...
- Next action: Read the printed error and logs, keep build directories for inspection, then rerun the failed target.

### 2026-06-19 | failure | Build script: build-release.ps1

- Source: tools\build-release.ps1
- Command: `Target=Windows; ReleaseDir=C:\softwares\dart_simple_live\release\v1.12.6`
- Log: `C:\softwares\dart_simple_live\release\v1.12.6\logs`
- Symptom: ple_live\simple_live_app\build\windows\x64\plugins\flutter_inappwebview_windows\flutter_inappwebview_windows_plugin.vcx proj] C:\softwares\dart_simple_live\simple_live_app\windows\flutter\ephemeral\.plugin_symlinks\flutter_inappwebview_windows\w indows\types\web_resource_response.cpp(54,28): warning C4244: “参数”: 从“__int64”转换到“int”，可能丢失数据 [C:\softwares\dart_simple _live\simple_live_app\build\windows\x64\plugins\flutter_inappwebview_windows\flutter_inappwebview_windows_plugin.vcxpro j] C:\softwares\dart_simple_live\simple_live_app\build\windows\x64\packages\Microsoft.Web.WebView2\build\native\include\We bView2EnvironmentOptions.h(194,3): warning C4458: “value”的声明隐藏了类成员 [C:\softwares\dart_simple_live\simple_live_app\build \windows\x64\plugins\flutter_inappwebview_windows\flutter_inappwebview_windows_plugin.vcxproj] C:\softwares\dart_simple_live\simple_live_app\build\windows\x64\packages\Mic...
- Next action: Read the printed error and logs, keep build directories for inspection, then rerun the failed target.
