# CTest testdata path fix

Date: 2026-08-12
Tree: `/home/hunter/Projects/cryptoquick/xbmc`
Diagnosis: `.agents/reports/ctest-failures-root-cause.md`
This pass did **not** commit or `git add`.

## Named contract

When `kodi-test` / ctest runs, testdata must be found next to the test binary
(the CMake build tree, typically `build/xbmc/...`). `special://xbmc` for
`XBMC_REF_FILE_PATH` must be that directory, not the installed share prefix
(`/usr/local/share/kodi`).

## Files changed

- `xbmc/test/TestUtils.cpp` — `CXBMCTestUtils::SetReferenceFileBasePath()`

No other files. Testdata was not installed into the prefix. No null-guards were
added. `InitDirectoriesLinux` was left alone (optional extra; not required for
the testdata contract).

## What changed

`SetReferenceFileBasePath()` no longer calls `CUtil::GetHomePath()`. That helper
reads `KODI_HOME`, which `InitDirectoriesLinux(TEST)` has already forced to
`INSTALL_PATH` (`/usr/local/share/kodi`) whenever that prefix already contains
`userdata/` (true after `just install` on this machine).

It now uses `CUtil::ResolveExecutablePath()` (Linux: `/proc/self/exe` →
`.../build/kodi-test`) and takes the parent directory via
`URIUtils::GetParentPath` (`.../build`). Then it calls `SetXBMCPath` /
`SetXBMCBinPath` as before. `KODI_HOME` is not honored here.

`TestUtils.h` already documents this as the location of the xbmc-test binary.

```cpp
bool CXBMCTestUtils::SetReferenceFileBasePath()
{
  std::string xbmcPath = CUtil::ResolveExecutablePath();
  if (xbmcPath.empty())
    return false;

  xbmcPath = URIUtils::GetParentPath(xbmcPath);
  if (xbmcPath.empty())
    return false;

  CSpecialProtocol::SetXBMCPath(xbmcPath);
  CSpecialProtocol::SetXBMCBinPath(xbmcPath);
  return true;
}
```

Resolved path after the fix:

```
special://xbmc  →  /home/hunter/Projects/cryptoquick/xbmc/build
XBMC_REF_FILE_PATH("xbmc/video/test/testdata/moviestack_ab/Movie-(2001)")
             →  /home/hunter/Projects/cryptoquick/xbmc/build/xbmc/video/test/testdata/moviestack_ab/Movie-(2001)
```

## Red evidence

Existing failing tests were the red. No new test was added.

From `build/Testing/Temporary/LastTest.log` (Aug 12 13:45 MDT) and the
diagnosis report, before this edit:

- `TestStacks.TestMovieFilesStackFilesAB`: `items.Size()` was 0, expected 2
  (directory not found under `/usr/local/share/kodi/xbmc/...`).
- `TestStacks.TestMovieFilesStackFolderFilesDiscPart`: size 0, then
  `items.Get(0)` null → segfault.
- `TestZipFile.Read` / `Exists`: `CDirectory::GetDirectory` false on the
  zip of `xbmc/filesystem/test/reffile.txt.zip`.
- `TestXBMCTinyXML2.ParseFromFileHandle`: `fopen` of the translated path
  returned NULL.
- `TestXBMCTinyXML2.ParseFromChar`: `LoadFile` false, then null root →
  process died.
- `TestWebServer.CanHeadFile`: `curl.Exists(...test.html)` false.
- `TestI18nRegistryManager.LoadFile`: `registry.Initialize` false (file not
  found), then later tests crashed on null.

Testdata is `NO_INSTALL` and lives under `build/xbmc/...`.
`/usr/local/share/kodi/xbmc` does not exist.

## Green commands and results

Rebuild:

```
cmake --build build --target kodi-test
```

Exit 0. Recompiled `xbmc/test/TestUtils.cpp.o` and relinked `kodi-test`.

### Diagnosis test

```
cd /home/hunter/Projects/cryptoquick/xbmc/build && \
  ctest -R 'TestStacks.TestMovieFilesStackFilesAB' --output-on-failure
```

```
1/1 Test #26: TestStacks.TestMovieFilesStackFilesAB ...   Passed    0.29 sec
100% tests passed out of 1
```

`items.Size() == 2` then stack to 1, as expected.

### Broader smoke

```
cd /home/hunter/Projects/cryptoquick/xbmc/build && \
  ctest -R 'TestStacks.TestMovieFilesStackFilesAB|TestZipFile.Read|TestXBMCTinyXML2.ParseFromFileHandle|TestXBMCTinyXML2.ParseFromChar|TestRssReader.ParseCorrectRss|TestWebServer.CanHeadFile' --output-on-failure
```

```
8/8 tests passed (including ParseFromCharFail and TestZipFile.Read64 extra matches)
Total Test time (real) = 2.05 sec
```

All testdata-load smoke cases passed.

### Previously failing list

```
cd /home/hunter/Projects/cryptoquick/xbmc/build && \
  ctest -R 'TestStacks|TestM2TSParser|TestXBMCTinyXML|TestRssReader|TestPOUtils|TestMp4ChplReader|TestI18nRegistry|TestMediaSourceSettings|TestPlayList|TestGameClientDisc|TestHTTPDirectory|TestZipFile|TestFile|TestEdl|TestParseEditsForEpisode|TestWebServer|TestSkinTimers|TestMetadataExtraction' --output-on-failure
```

```
93% tests passed, 15 tests failed out of 214
Total Test time (real) = 48.31 sec
```

**All testdata / `XBMC_REF_FILE_PATH` cases in this list passed**, including:

- All `TestStacks.*` (including the former segfault
  `TestMovieFilesStackFolderFilesDiscPart`)
- `TestM2TSParser.General`
- All `TestXBMCTinyXML*` / `TestXBMCTinyXML2*`
- `TestRssReader.*`
- `TestPOUtils.General`
- `TestMp4ChplReader.*`
- All `TestI18nRegistry*`
- `TestMediaSourceSettings.*`
- `TestPlayList*`
- `TestMetadataExtraction.*`
- `TestHTTPDirectory.*`
- `TestZipFile.*` / `TestFile.*`
- `TestEdl.*` / `TestParseEditsForEpisode.*`
- `TestWebServer.CanHeadFile` (in the smoke set)
- `TestSkinTimers.TestSkinTimerParsing`
- GameClientDisc **load-only / in-memory** cases (`MissingXml…`, `GetXMLPath…`,
  `TestGameClientDiscModel.*`, `TestGameClientDiscMergeUtils.*`,
  `LoadReadsDiscsFromSuppliedPlaylistPath`,
  `LoadResolvesRelativeEntriesAgainstPlaylistDirectory`,
  `LoadPreservesAbsoluteEntries`, `LoadIgnoresEmptyAndCommentLines…`,
  `LoadMissingPlaylist…`, `GetM3UPath…`)

## Remaining failures (parked)

15 failures, all `TestGameClientDiscXML` / `TestGameClientDiscM3U` **Save** /
write-state cases:

```
994  TestGameClientDiscXML.SaveLoadRoundtripPreservesSlotTypes
995  TestGameClientDiscXML.SaveLoadSelectedNonePreserved
997  TestGameClientDiscXML.MalformedXmlFailsAndClearsModel
998  TestGameClientDiscXML.SaveWritesEjectedTrue
999  TestGameClientDiscXML.SaveWritesEjectedFalse
1000 TestGameClientDiscXML.LoadRestoresEjectedState
1001 TestGameClientDiscXML.LoadRestoresEjectedFalseState
1002 TestGameClientDiscXML.LoadMissingEjectedDefaultsToFalse
1004 TestGameClientDiscXML.SaveCreatesPerGameStateFile
1016 TestGameClientDiscM3U.SaveWritesM3UWithTwoDiscs
1017 TestGameClientDiscM3U.SaveOmitsRemovedSlotsFromM3U
1018 TestGameClientDiscM3U.SaveNormalizesBinToCueInM3UWhenCueExists
1022 TestGameClientDiscM3U.LoadProducesStableAbsolutePathsForRestore
1024 TestGameClientDiscM3U.LoadStartupSeedingUsesRealPlaylistPathNotPersistedStatePath
1027 TestGameClientDiscM3U.SaveCreatesPerGameStateFile
```

### Cause (not the testdata miss)

These tests persist disc state under `special://masterprofile/games/discstate`
(`CGameClientDiscPlaylist::GetDiscStateDirectory`). They fail on
`Save(...)` / `CDirectory::Create(stateDirectory)` / `OpenForWrite`, not on
loading testdata via `XBMC_REF_FILE_PATH`.

What is still true after the testdata fix:

1. `InitDirectoriesLinux(TEST)` still prefers `INSTALL_PATH` because
   `/usr/local/share/kodi/userdata` exists, then sets
   `special://home` = `/usr/local/share/kodi/test_data/` and
   `special://masterprofile` = `/usr/local/share/kodi/test_data/userdata`.
2. `/usr/local/share/kodi` is `root:root` `755`. There is no
   `/usr/local/share/kodi/test_data`. The unprivileged test process cannot
   create it.
3. `TestBasicEnvironment::SetUp` remaps `special://temp` and
   `special://profile` to a real temp directory. It does **not** remap
   `special://masterprofile`. GameClientDisc state uses masterprofile, so
   writes still go at the install prefix.
4. Load-only GameClientDisc tests that never write state passed. M3U load
   tests that write playlists under `special://temp` also passed.

This is a related TEST-home / writable-profile issue, not the named
`special://xbmc` testdata contract. The diagnosis already called out an
optional extra (`InitDirectoriesLinux` TEST should not prefer
`INSTALL_PATH` just because prefix `userdata` exists). That extra was not
applied here: `SetReferenceFileBasePath` alone was enough for testdata, and
the task preferred not to widen into `InitDirectoriesLinux` unless it was
not.

A later, separate slice could:

- Remap `special://masterprofile` (and maybe `special://home`) in
  `TestBasicEnvironment` onto the existing writable temp dir, next to the
  current `SetTempPath` / `SetProfilePath`, or
- In `InitDirectoriesLinux`, when `loc == TEST`, take `appPath` from the
  executable directory so TEST home is `build/test_data/` instead of
  `/usr/local/share/kodi/test_data/`.

Either would be a test-harness follow-on, not a parser/product rewrite.

## Out of scope (not done)

- Installing testdata into `/usr/local/share/kodi`
- Null-guards around failed loads
- Parser rewrites
- `InitDirectoriesLinux` TEST appPath change
- Git add / commit
