# CTest file-load / segfault cluster: root cause

Date: 2026-08-12
Tree: `/home/hunter/Projects/cryptoquick/xbmc` branch HB
Build: out-of-tree `build/` (`CMAKE_INSTALL_PREFIX=/usr/local`)
Evidence: `build/Testing/Temporary/LastTest.log` (Aug 12 13:45 MDT), testdata on disk, `InitDirectoriesLinux` + `SetReferenceFileBasePath`

This pass did **not** change product code or the justfile.

## 1. Shared root cause

**One cause covers the listed Failed tests and the listed segfaults.**

`XBMC_REF_FILE_PATH(...)` is `special://xbmc` + the path from the test (usually `xbmc/...`). CMake copies testdata into the **build** tree next to `kodi-test`. At test startup, `special://xbmc` is **not** that build tree.

What actually happens:

1. `TestBasicEnvironment::SetUp` calls `CAppEnvironment::SetUp` first.
2. That initializes settings and runs `InitDirectoriesLinux(UserDirectoriesLocation::TEST)`.
3. On Linux, if `KODI_HOME` is unset, `appPath` is compiled-in `INSTALL_PATH` (`/usr/local/share/kodi` with this cache).
4. That directory **has** `userdata/` because this machine already has Kodi installed at the prefix (`just install` / prior install).
5. So Linux keeps `INSTALL_PATH` instead of falling back to the executable directory.
6. It then `setenv("KODI_HOME", appPath, 0)` (do not overwrite if already set).
7. `SetReferenceFileBasePath()` is supposed to point testdata at the `kodi-test` binary dir. It calls `CUtil::GetHomePath()`, whose default target is `"KODI_HOME"`. After step 6 that is `/usr/local/share/kodi`, **not** `.../xbmc/build`.
8. Tests then look for `/usr/local/share/kodi/xbmc/...`. That tree **does not exist**. Testdata is `NO_INSTALL` (not installed under the prefix).

CWD is already `build/`. The files are there. The special protocol root is wrong.

**Segfaults are the same miss**, not a second parser bug. After a failed load / empty `GetDirectory`, tests dereference a null root or a null `CFileItem` (gtest `EXPECT_*` does not stop the function).

Tests that do not need testdata (for example `TestXBMCTinyXML2.ParseFromString`, `TestURIUtils.GetDirectory`) pass. That matches a path miss, not a totally broken test harness.

## 2. Evidence: resolved paths vs where testdata lives

| What | Path |
|------|------|
| CTest working directory | `/home/hunter/Projects/cryptoquick/xbmc/build` (`LastTest.log`: `Directory: .../build`) |
| Test binary | `/home/hunter/Projects/cryptoquick/xbmc/build/kodi-test` |
| Testdata copy (cmake `test-reference-data.txt`, `NO_INSTALL`) | `/home/hunter/Projects/cryptoquick/xbmc/build/xbmc/...` (confirmed: stacks, zip, tinyxml, i18n, webserver, skin timers, m2ts, playlists) |
| Source testdata (same relative layout) | `/home/hunter/Projects/cryptoquick/xbmc/xbmc/...` |
| `INSTALL_PATH` / installed share | `/usr/local/share/kodi` (exists; has `userdata/`, `system/`, `addons/`) |
| Installed testdata | **`/usr/local/share/kodi/xbmc` does not exist** |

Resolved `XBMC_REF_FILE_PATH` after the sequence above:

```
special://xbmc  →  /usr/local/share/kodi
XBMC_REF_FILE_PATH("xbmc/video/test/testdata/moviestack_ab/Movie-(2001)")
             →  /usr/local/share/kodi/xbmc/video/test/testdata/moviestack_ab/Movie-(2001)
```

What the test needs:

```
/home/hunter/Projects/cryptoquick/xbmc/build/xbmc/video/test/testdata/moviestack_ab/Movie-(2001)
```

(or the same path under the source tree). Dummy/empty media stubs are **not** the issue: `GetDirectory` size 0 is "directory not found", not "files exist but are empty".

### Log matches

- `TestStacks.TestMovieFilesStackFilesAB`: `items.Size()` is 0, expected 2.
- `TestZipFile.Read` / `Exists`: `CDirectory::GetDirectory` false on `zip://` of `xbmc/filesystem/test/reffile.txt.zip`.
- `TestXBMCTinyXML2.ParseFromFileHandle`: `fopen` of the translated path returns `NULL`.
- `TestXBMCTinyXML2.ParseFromChar`: `LoadFile` false, then `strcmp(root->Value(), ...)` with a null root (process dies; log cuts off before the usual FAILED footer).
- `TestStacks.TestMovieFilesStackFolderFilesDiscPart`: size 0, then `items.Get(0)` is null and `item->IsStack()` crashes.
- `TestWebServer.CanHeadFile`: `curl.Exists(...test.html)` false. Source files are `build/xbmc/network/test/data/webserver/`.
- `TestI18nRegistryManager.LoadFile`: `registry.Initialize` false (registry file not found). Type/Scope/Date/Strings crashes are the same load-then-use-null pattern.

`SetReferenceFileBasePath` / `ReferenceFilePath` (`xbmc/test/TestUtils.cpp`):

```cpp
std::string CXBMCTestUtils::ReferenceFilePath(const std::string& path)
{
  return CSpecialProtocol::TranslatePath(URIUtils::AddFileToFolder("special://xbmc", path));
}

bool CXBMCTestUtils::SetReferenceFileBasePath()
{
  std::string xbmcPath = CUtil::GetHomePath(); // getenv("KODI_HOME") after InitDirectories
  ...
  CSpecialProtocol::SetXBMCPath(xbmcPath);
}
```

`InitDirectoriesLinux` (`xbmc/settings/SettingsComponent.cpp`): TEST only changes `special://home` to `.../test_data/`. It still binds `special://xbmc` to `INSTALL_PATH` when that prefix already has `userdata`.

`CUtil::GetHomePath` default target is `"KODI_HOME"`. POSIX remap of bin vs share only runs when `strTarget` is **empty**, so it does not save this case.

## 3. Smallest product fix

**Fix the test home root so `special://xbmc` is the directory that contains the copied testdata (`build/`), not the installed share.**

Preferred (small, matches `TestUtils.h`: "location to the xbmc-test binary"):

In `CXBMCTestUtils::SetReferenceFileBasePath()`, stop using `CUtil::GetHomePath()`. Use `CUtil::ResolveExecutablePath()` and take its parent directory (`/proc/self/exe` → `.../build/kodi-test` → `.../build`). Then `SetXBMCPath` / `SetXBMCBinPath` as today.

That still runs **after** `InitDirectoriesLinux`, so it overwrites the wrong `INSTALL_PATH` mapping. Do not honor `KODI_HOME` here; InitDirectories has just forced that env to the install prefix.

Optional extra (slightly larger, still right):

In `InitDirectoriesLinux`, when `loc == UserDirectoriesLocation::TEST`, set `appPath` from the executable directory (or require testdata/`xbmc/` under the candidate) instead of preferring `INSTALL_PATH` just because `userdata` exists. That also stops tests from creating `/usr/local/share/kodi/test_data/` under the install prefix.

Do **not** install testdata into `/usr/local/share/kodi`. `NO_INSTALL` is correct.

Do **not** rewrite parsers for the segfaults until file-load tests pass. Null checks would only hide the path bug.

## 4. Is `just check` cwd / env wrong?

**CWD is not wrong.** `just check` / `just test` run `ctest --test-dir build` from the repo root. CTest sets the test working directory to `build/`. `LastTest.log` confirms that. Testdata is already copied into that tree.

**Env is incomplete, not a justfile syntax bug.** The justfile does not set `KODI_HOME`. Unsetting `KODI_HOME` would **not** fix this: `InitDirectoriesLinux` would still pick `/usr/local/share/kodi` because `userdata` is there.

A justfile-only workaround that would unblock `just test` (not raw `ctest` / IDEs):

```bash
export KODI_HOME="{{ root }}/{{ build_dir }}"
```

before `ctest`. InitDirectories uses a pre-set `KODI_HOME`. That is a workaround. The product fix in `SetReferenceFileBasePath` is the one that makes any ctest invocation work after an install to the prefix.

This pass did not apply the justfile workaround.

## 5. Re-run after the fix

```bash
cd /home/hunter/Projects/cryptoquick/xbmc/build && ctest -R 'TestStacks.TestMovieFilesStackFilesAB' --output-on-failure
```

Expect `items.Size() == 2` then stack to 1.

Broader smoke:

```bash
cd /home/hunter/Projects/cryptoquick/xbmc/build && ctest -R 'TestStacks.TestMovieFilesStackFilesAB|TestZipFile.Read|TestXBMCTinyXML2.ParseFromFileHandle' --output-on-failure
```

If those three pass, the listed file-load and segfault clusters should go green together.
