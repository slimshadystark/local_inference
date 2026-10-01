# Vendored llamadart natives

llamadart 0.8.23 runs on the prebuilt llama.cpp libraries of [leehack/llamadart-native](https://github.com/leehack/llamadart-native) release `v0.4.0`. Its build hook downloads them from GitHub and checks none of them: LiteRT-LM archives have a SHA-256 table in the hook, llama.cpp archives do not. A build that must use checked binaries points the hook at a local copy that this folder fetches and checks, file by file, against the manifest kept here.

| File | What it is |
|---|---|
| `bundles.txt` | The bundles vendored by default, one per line, in the upstream naming. |
| `llamadart-native-v0.4.0.sha256` | The manifest: every archive and every file it unpacks to, in `shasum -a 256 -c` format. |
| `fetch_llamadart_native.sh` | Downloads, checks, unpacks and installs the bundles; `--verify-only` re-checks them offline. |

## Use

```sh
packages/local_inference/tool/native/fetch_llamadart_native.sh                          # every bundle in bundles.txt
packages/local_inference/tool/native/fetch_llamadart_native.sh macos-arm64 ios-arm64    # only these
packages/local_inference/tool/native/fetch_llamadart_native.sh --verify-only            # offline, changes nothing
NATIVES_DIR=/elsewhere/.natives packages/local_inference/tool/native/fetch_llamadart_native.sh
packages/local_inference/tool/native/fetch_llamadart_native.sh --dest third_party/llamadart-native/v0.4.0
```

- In a checkout of this repository the default folder is `<repo>/.natives/llamadart-native/v0.4.0`, which git ignores. Elsewhere, name the folder with `--dest` or `NATIVES_DIR`.
- A run skips every bundle that is already in place and verifies. It rebuilds any other bundle, from its archive when that still verifies, else from a fresh download.
- Each download goes to a temporary folder next to the destination, is checked, unpacked and checked again, and only then moved in. The destination therefore only ever holds complete, verified bundles.
- A download that does not match the manifest is deleted, reported as `ALARM`, and the run exits 1. `--verify-only` exits 1 on any missing or different file, and changes nothing.
- Exit status 2 means a usage or environment error: an unknown option, no `shasum`/`sha256sum`, or a malformed manifest.
- `SHA256_CMD` overrides the checksum command. The default is `shasum -a 256` on macOS and `sha256sum` elsewhere.
- `LLAMADART_NATIVE_MIRROR` replaces the download base; `file://` URLs work.

The root pubspec of the app points the hook at the folder (relative to that pubspec, or absolute):

```yaml
hooks:
  user_defines:
    llamadart:
      llamadart_native_runtimes: [llama_cpp]
      llamadart_native_path: .natives/llamadart-native/v0.4.0
```

After changing files in the folder, run `flutter clean` (or delete `.dart_tool/hooks_runner`). The hook never declares the folder as a dependency: its only `output.dependencies` are at `build.dart:562, 623, 656, 698`. The hooks runner may therefore reuse a cached result.

## Layout

```
.natives/llamadart-native/v0.4.0/                   the folder llamadart_native_path points at
├── macos-arm64/
│   ├── llamadart-native-macos-arm64-v0.4.0.tar.gz  the release archive, byte for byte
│   └── extracted/libllamadart.dylib                what it unpacks to; the hook bundles these files
├── macos-x86_64/ ios-arm64/ ios-arm64-sim/         the same, 1 file each in extracted/
├── android-arm64/  android-x64/  linux-x64/        15, 9 and 21 files in extracted/
└── extracted/target-bundle-not-vendored.so         empty guard file (see "The guard file")
```

- **Manifest.** Its 57 lines give each file's path relative to `v0.4.0/`. From that folder, `shasum -a 256 -c <manifest>` re-checks everything.
- **Header.** The five header lines start with `#`. Perl `shasum` and GNU `sha256sum` skip them silently, `--strict` included. macOS `/sbin/sha256sum` warns "5 lines are improperly formatted" and still exits 0.
- **Checks.** The fetch script checks each bundle folder for exactly the files the manifest lists. An extra file fails the check (`.DS_Store` excepted), because the hook bundles every library it finds in the folder. A symlink also fails, and so does any top-level entry the manifest does not cover.
- **Symlinks.** The linux-x64 archive holds 10 symlinks (`libllama.so -> libllama.so.0 -> libllama.so.0.4.0`, …). The hook's own extraction writes them as copies (`build.dart:2285-2305`), and the fetch script does the same, so the vendored folder holds no symlinks.
- **Same layout as the hook's cache.** Each bundle folder matches the hook's own download cache, `<llamadart>/.dart_tool/llamadart/native_bundles/v0.4.0/<bundle>/{<archive>,extracted/}` (`build.dart:1362-1368, 1497-1505`). The manifest therefore also checks a cache the hook filled by itself: `cd "$PUB_CACHE/hosted/pub.dev/llamadart-0.8.23/.dart_tool/llamadart/native_bundles/v0.4.0" && shasum -a 256 -c --ignore-missing <manifest>`. On 2026-09-29 that check passed for the macos-arm64, macos-x86_64 and ios-arm64 bundles the hook had downloaded on a development Mac on 8 and 16 Sep.
- **Size.** About 854 MiB in all. linux-x64 alone takes 508 MiB (a 172 MiB archive and 337 MiB unpacked), mostly the CUDA and HIP backends. The hook does not bundle those by default: on Linux and Android it keeps `cpu` and `vulkan` (`config:282-293, 306-317`).

## How the hook consumes the folder

References are to llamadart 0.8.23: `hook/build.dart`, `lib/src/hook/native_bundle_config.dart` (`config`), and hooks 2.0.2 `lib/src/config.dart` (`hooks`). hooks 2.2.0 resolves paths the same way (`config.dart:285-294`).

1. **Release and keys.** The release is pinned at `build.dart:17-18` (`v0.4.0`, `leehack/llamadart-native`). The user-define keys are at `config:32-46`.
2. **Where defines are read.** Only the root package's pubspec, or the workspace root's, is read (`hooks:229-238`).
3. **Path resolution.** `llamadart_native_path` goes through `_resolveNativePath` (`build.dart:1324-1352`). It resolves relative to the directory of the pubspec that declares it, and accepts an absolute path as is (`hooks:272-297`).
4. **Runtimes.** `llamadart_native_runtimes: [llama_cpp]` selects the runtimes (`build.dart:258-302`, `config:538-560`); the hook logs `Selected native runtimes: llama_cpp.`. LiteRT-LM is then never fetched or bundled: that happens only when it is selected (`build.dart:429-438`), in a `litert_lm` cache folder (`build.dart:958-969`).
5. **Bundle per target.** The target OS and architecture pick the bundle: `macos-arm64`, `ios-arm64-sim`, … (`config:276-345`).
6. **No cache, no download.** With a native path, `_acquireBundleDirectory` returns from `_acquireLocalBundleDirectory` before it looks at any cache or download (`build.dart:1371-1382`). The hook logs `Using native runtime source: local path …` (`build.dart:328`).
7. **Lookup order.** `_acquireLocalBundleDirectory` (`build.dart:1522-1586`) tries, in order:
   - a direct archive path (`1533-1542`);
   - the directories `<path>/v0.4.0/<bundle>/extracted`, `<path>/v0.4.0/<bundle>`, `<path>/<bundle>/extracted`, `<path>/<bundle>`, `<path>/extracted` and `<path>` (`1544-1560`, list at `1588-1601`). The first one holding a dynamic library wins. The scan is recursive and matches `.so`, `.dylib`, `.dll` and `.so.N` (`1726-1755`, `163-166`).
   - the archives `<path>/<archive>`, `<path>/v0.4.0/<bundle>/<archive>` and `<path>/<bundle>/<archive>` (`1562-1579`, list at `1603-1614`). An archive is unpacked into `<llamadart>/.dart_tool/llamadart/native_bundles/local/<sha1 of the path>/v0.4.0/<bundle>/extracted` (`1482-1495`, `1628-1652`, `1839-1871`).
   - If nothing matches, the build fails with "No compatible native bundle found" (`1581-1585`).
8. **This layout.** The layout of this folder hits `<path>/<bundle>/extracted`, which the hook uses as it is. Nothing is unpacked or written into the pub cache for llama.cpp, and the hook logs `Using local native bundle directory: …/<bundle>/extracted` (`1557`). Every build with a native path also logs a harmless warning that overrides do not regenerate the FFI bindings (`329-335`).
9. **Bundling.** The hook needs a primary `libllamadart` (`build.dart:360-370`). On Android and Linux it filters the backend modules (`build.dart:372-377`, `config:919-990`). It copies the libraries to `<hook output>/llamadart_bin` (`build.dart:337-345, 379-404`) and reports them as code assets (`407-427`).
10. **No checksum on downloads.** Without a native path, the hook downloads the archive (`build.dart:1452-1460`, `1873-1890`, `1892-1961`) with no checksum anywhere. The LiteRT-LM table (`build.dart:58-161`) is checked at `1018-1041`.
11. **Flutter Apple companion.** When a Flutter app depends on `llamadart_llama_cpp_flutter`, the companion's SwiftPM binaries replace all of this and the native path is ignored (`build.dart:475-481, 527-590`). local_inference does not use the companion.
12. **What reaches the build.** The files the hook copies into `.dart_tool/hooks_runner/shared/llamadart/build/<hash>/llamadart_bin/` match the manifest byte for byte. On Linux, `dart build cli` copies them unchanged into `bundle/lib`. On macOS it rewrites the install name (`@rpath/libllamadart.dylib` → `@rpath/lib/libllamadart.dylib`) and signs the library again ad hoc, so `bundle/lib/libllamadart.dylib` no longer matches the manifest. It keeps the same LC_UUID and the same `__TEXT,__text`; once both copies are unsigned and share the install name, only the `__LINKEDIT` size differs. Check the hook's output, not the app bundle.

## The guard file

For a bundle that is not vendored, the lookup above falls through to `<path>/extracted` and then to `<path>` itself (`build.dart:1598-1599`). `<path>` is scanned recursively. Without the guard, a build for such a target (for example `linux-arm64`, or an x86_64 iOS simulator) would take every library of every vendored platform from `v0.4.0/` and bundle a wrong mix.

`extracted/target-bundle-not-vendored.so` is an empty file with a library extension. It makes `<path>/extracted` the match for any missing bundle. That folder holds no primary library, so the build stops with `No primary libllamadart library found in …/v0.4.0/extracted.` (`build.dart:366-370`). The hook never opens the file (`config:426-451`). The fetch script creates the guard, and the manifest covers it. To support another target, add its bundle to `bundles.txt` and to the manifest.

## Trust record (2026-09-29)

Upstream release `v0.4.0` was published on 2026-09-06T14:52:12Z. It carries a `SHA256SUMS` file (sha256 `8f79a7853741ec9772afb7cf3e4d379e8a8db776c195917117c8d58284a3f630`) and an `assets.json` file. `assets.json` records `llama_cpp_commit 5266f24da75dc449bd56cbed7addb9c8e4a6a73e`, `native_commit 236d369512eedbd564b5b1b839c2a6d0f9dd654e` and workflow run `34035208935`. Every archive below was downloaded three times on 2026-09-29, once by `--write-manifest`, and all copies were byte-identical. Each archive hash equals the `SHA256SUMS` line, the GitHub API asset `digest` and the `assets.json` entry. Those three sources all come from the same publisher, so they are one source of trust, not three.

| Bundle | Size (bytes) | Archive SHA-256 | Where the hash was checked | Unpacked files |
|---|---|---|---|---|
| macos-arm64 | 4,479,068 | `95e76865fb444f3187da47398cfab03a0af3ad46da6a9026e1d490401401355a` | known digest, plus the upstream sources above | 1 |
| macos-x86_64 | 4,849,250 | `454009101d97349d69545eca07b7f91a436e971a6a06d9bda6ca6270c67102f2` | known digest, plus the upstream sources above | 1 |
| ios-arm64 | 4,286,905 | `eee5a4c61c35557afd029fc953bbfe600ea965049ac5833f2f990e7f30dacff7` | known digest, plus the upstream sources above | 1 |
| ios-arm64-sim | 4,468,407 | `4164b7860c2e8390057b7fff536afada64062edfe3592d91c75a626823bec96f` | upstream `SHA256SUMS`, trusted on first use | 1 |
| android-arm64 | 38,610,514 | `756f4d3c4d020e2de4e26b029ebe9aad26073b4f14c425ce76d10e1c6922a73f` | upstream `SHA256SUMS`, trusted on first use | 15 |
| android-x64 | 23,166,403 | `44a413588dd420500ff290b139d63758499a907285932349cc5dc8200194be2d` | upstream `SHA256SUMS`, trusted on first use | 9 |
| linux-x64 | 180,153,593 | `8384cc54c4404630229fe248da6d74cbb820959c4f231fc6a0c8221560cf964f` | upstream `SHA256SUMS`, trusted on first use | 21 |

- **Known digests.** The three known digests are those of the archives the hook itself downloaded on a development Mac on 2026-09-08 (macos-arm64, macos-x86_64) and 2026-09-16 (ios-arm64). They predate this manifest and matched on 2026-09-29.
- **Unpacked files.** The hashes of the unpacked files were computed on 2026-09-29 from the verified archives, so they are trusted on first use by construction. For the three known bundles, they equal the files the hook's own extraction left in the pub cache in September.
- **Drift check.** `curl -fsSL https://github.com/leehack/llamadart-native/releases/download/v0.4.0/SHA256SUMS | shasum -a 256` must keep printing the `SHA256SUMS` hash above. A different value means the tag was republished.

## Checked on 2026-09-29

**Offline builds.** Each consumer depended on `llamadart: 0.8.23` alone, with the hooks block above and an absolute native path, and used a fresh `PUB_CACHE`. `dart build cli` ran with outbound network denied (`sandbox-exec`, localhost allowed) on:
- Dart 3.13.2 on macOS arm64;
- the standalone Dart 3.10.7, with `FLUTTER_ROOT` unset;
- the x64 Dart 3.13.2 under Rosetta, which used the macos-x86_64 bundle;
- a cross build for linux-x64.

**What each build showed.**
- The hook logged `Selected native runtimes: llama_cpp.` and `Using local native bundle directory: …/<bundle>/extracted`.
- llamadart's `.dart_tool` was never created in the fresh pub cache: no `native_bundles`, no `litert_lm`.
- Every emitted library matched the manifest.
- The macOS executables loaded the library through llamadart's exported bindings (`llama_backend_init`, `llama_print_system_info`, `ggml_backend_dev_*`) and listed the Metal and CPU devices.

**Relative path.** `../../.natives/llamadart-native/v0.4.0`, declared in a pubspec two levels down, worked the same.

**Guard.** A linux-arm64 build stopped on the guard. The same build against a copy of the folder without the guard succeeded, and put android-x64 and ios-arm64 libraries into a linux-arm64 bundle.

**Fetch script.** It passed 27 checks on copies of the folder, covering tampered, extra and symlinked files, tampered and missing downloads, strays, the guard, and usage errors. A GNU userland run (coreutils 9.12, tar 1.35, `sha256sum`) built a folder identical to the macOS one.

## Updating to a new llamadart-native version

1. **Read the new llamadart's hook.** Note the pinned tag (`_llamaCppTag`, `build.dart:17`). Check that the lookup order (`1522-1614`), the library scan (`1726-1755`), the primary-library check (`360-370`) and the extraction (`2204-2306`) still behave as described above. The guard depends on the lookup order and the primary-library check.
2. **Set the tag.** In `fetch_llamadart_native.sh`, set `TAG` and `LLAMADART`. The manifest name follows `TAG`.
3. **Compare upstream's hashes.** Compare upstream's `SHA256SUMS` with the GitHub asset digests: `gh api repos/leehack/llamadart-native/releases/tags/<tag> --jq '.assets[] | "\(.digest) \(.name)"'`.
4. **Write the manifest.** Run `fetch_llamadart_native.sh --write-manifest`. It downloads every bundle in `bundles.txt` and checks each archive against `SHA256SUMS`. It then unpacks the archives, writes `llamadart-native-<tag>.sha256` and installs the bundles.
5. **Review the diff.** Review `git diff`. When you only add a bundle to the current tag, no existing line may change.
6. **Move the pointers.** Point `llamadart_native_path` at `.natives/llamadart-native/<tag>` wherever it is set (pubspecs and CI). Then run `flutter clean` (or delete `.dart_tool/hooks_runner`) in each app that builds with it.
7. **Record the trust.** Add a trust record for the new tag here, with the date and the `SHA256SUMS` hash. Delete the old manifest once nothing points at it.
8. **Smoke-test a consumer.** Build a consumer with a fresh `PUB_CACHE`. Its hook log must say `Selected native runtimes: llama_cpp.` and `Using local native bundle directory`, and must show no `Downloading` line. A build for a bundle that is not vendored must stop on the guard.
