# CTest GameClientDisc write-state fix

Date: 2026-08-12
Tree: `/home/hunter/Projects/cryptoquick/xbmc`
Prior testdata pass: `.agents/reports/ctest-failures-fix.md`
This pass did **not** commit or `git add`.

## Named contract

`kodi-test` must be able to write TEST profile / masterprofile state under a
writable temp directory. It must not try to mkdir
`/usr/local/share/kodi/test_data` when the install prefix is not writable.

## Files changed

- `xbmc/test/TestBasicEnvironment.cpp` — `TestBasicEnvironment::SetUp`

No other files. `InitDirectoriesLinux` was left alone. Testdata was not
installed. `/usr/local` was not chmod'd.

## What changed

`InitDirectoriesLinux(TEST)` still prefers `INSTALL_PATH` when
`/usr/local/share/kodi/userdata` exists, then maps:

- `special://home` → `/usr/local/share/kodi/test_data/`
- `special://masterprofile` → `/usr/local/share/kodi/test_data/userdata`

That prefix is `root:root` `755`. The unprivileged test process cannot create
`test_data`.

`TestBasicEnvironment::SetUp` already remapped `special://temp` and
`special://profile` onto a real temp directory from
`fs::create_temp_directory`. GameClientDisc Save / write-state tests persist
under `special://masterprofile/games/discstate`
(`CGameClientDiscPlaylist::GetDiscStateDirectory`), so they still hit the
install prefix.

This pass remaps `special://masterprofile` and `special://home` onto that
same writable temp tree, after `CAppEnvironment::SetUp` (which runs
`InitDirectoriesLinux(TEST)`):

```cpp
CSpecialProtocol::SetTempPath(m_tempPath);
CSpecialProtocol::SetProfilePath(m_tempPath);
CSpecialProtocol::SetMasterProfilePath(m_tempPath);
CSpecialProtocol::SetHomePath(m_tempPath);
```

`special://home` is remapped with masterprofile so later tests that write
user dirs (`CreateUserDirs`, savestates, addons) do not hit the same
unwritable prefix. `SetReferenceFileBasePath` still owns `special://xbmc`.

## Red evidence

Existing failing GameClientDisc Save tests were the red. No new test was
added.

From `.agents/reports/ctest-failures-fix.md` (after the testdata path fix):

```
93% tests passed, 15 tests failed out of 214
```

All 15 were `TestGameClientDiscXML` / `TestGameClientDiscM3U` Save /
write-state cases. `Save(...)` / `CDirectory::Create(stateDirectory)` /
`OpenForWrite` failed because masterprofile still pointed at
`/usr/local/share/kodi/test_data/userdata`.

## Green commands and results

Rebuild:

```
cmake --build /home/hunter/Projects/cryptoquick/xbmc/build --target kodi-test
```

Exit 0. Recompiled `xbmc/test/TestBasicEnvironment.cpp.o` and relinked
`kodi-test`.

### Remaining 15 (plus the rest of those two suites)

```
cd /home/hunter/Projects/cryptoquick/xbmc/build && \
  ctest -R 'TestGameClientDiscXML|TestGameClientDiscM3U' --output-on-failure
```

```
100% tests passed out of 23
Total Test time (real) =   3.55 sec
```

All previously failing Save / write-state cases passed:

- `TestGameClientDiscXML.SaveLoadRoundtripPreservesSlotTypes`
- `TestGameClientDiscXML.SaveLoadSelectedNonePreserved`
- `TestGameClientDiscXML.MalformedXmlFailsAndClearsModel`
- `TestGameClientDiscXML.SaveWritesEjectedTrue`
- `TestGameClientDiscXML.SaveWritesEjectedFalse`
- `TestGameClientDiscXML.LoadRestoresEjectedState`
- `TestGameClientDiscXML.LoadRestoresEjectedFalseState`
- `TestGameClientDiscXML.LoadMissingEjectedDefaultsToFalse`
- `TestGameClientDiscXML.SaveCreatesPerGameStateFile`
- `TestGameClientDiscM3U.SaveWritesM3UWithTwoDiscs`
- `TestGameClientDiscM3U.SaveOmitsRemovedSlotsFromM3U`
- `TestGameClientDiscM3U.SaveNormalizesBinToCueInM3UWhenCueExists`
- `TestGameClientDiscM3U.LoadProducesStableAbsolutePathsForRestore`
- `TestGameClientDiscM3U.LoadStartupSeedingUsesRealPlaylistPathNotPersistedStatePath`
- `TestGameClientDiscM3U.SaveCreatesPerGameStateFile`

The 8 already-green load-only / path-only cases in those two suites stayed
green.

### Testdata smoke (special://xbmc still the build tree)

```
cd /home/hunter/Projects/cryptoquick/xbmc/build && \
  ctest -R 'TestStacks.TestMovieFilesStackFilesAB|TestZipFile.Read|TestXBMCTinyXML2.ParseFromChar' \
  --output-on-failure
```

```
100% tests passed out of 5
Total Test time (real) =   1.00 sec
```

(`ParseFromCharFail` and `TestZipFile.Read64` extra-matched the regex.)

Remapping masterprofile / home did not break the testdata `special://xbmc`
mapping from the prior pass.

## Remaining failures

None in the requested GameClientDisc XML/M3U set or the testdata smoke set.

`InitDirectoriesLinux(TEST)` still prefers `INSTALL_PATH` when prefix
`userdata/` exists. That is unused by the remapped test process after
`TestBasicEnvironment::SetUp`. Left alone on purpose.

## Out of scope (not done)

- `InitDirectoriesLinux` TEST appPath change
- Installing testdata into `/usr/local/share/kodi`
- chmod of `/usr/local`
- Production disc-state path changes
- Git add / commit
