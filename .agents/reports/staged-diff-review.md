# Staged-diff review: merge `origin/master` into `HB`

Date: 2026-08-12
Tree: `/home/hunter/Projects/cryptoquick/xbmc`

This pass ran the requested read-only git commands. It did not run
`git add`, `git commit`, `git restore`, `git reset`, or `git push`.

**Verdict: wait / split. Do not merge-commit as-is.**

The merge itself is real and almost ready. The index also contains local
follow-up work and junk that must come out of this commit first.

## 1. Command facts

### `git status` (quoted)

```
On branch HB
Your branch is up to date with 'origin/HB'.

All conflicts fixed but you are still merging.
  (use "git commit" to conclude merge)
```

- `HEAD` (`HB`): `c71da6d4d50c85a88af5347a4967dc870bbb0dff`
  (`refactor to not need groovy to build`)
- `MERGE_HEAD` (incoming master): `55d3a2927116283f2288e115a359f8446d56dca1`
  (`Merge pull request #28938 from MikeSiLVO/doxygen-docs-fixes`)
- merge-base: `2d577c8377b83988ec2b0b39e75bbe260fc6e123`
- `MERGE_MSG`:

```
Merge branch 'master' into HB

# Conflicts:
#       xbmc/interfaces/swig/CMakeLists.txt
```

- `git ls-files -u`: empty (no remaining unmerged stages)
- Unstaged: **none** (`git diff --stat` and `git diff --shortstat` both empty)
- Untracked (exclude-standard): **one file**,
  `.agents/reports/staged-diff-review.md` (this report)

### `git diff --staged --stat` / `--name-only`

```
681 files changed, 31793 insertions(+), 11948 deletions(-)
```

Staged name list is 681 paths. First lines of `--stat` include both the
incoming master merge **and** the extras called out below:

```
 .agents/reports/check-includes-build.md            |   26 +
 .agents/reports/ctest-failures-fix.md              |  232 ++
 .agents/reports/ctest-failures-root-cause.md       |  138 +
 .agents/reports/ctest-gameclientdisc-write-fix.md  |  146 +
 .editorconfig                                      |   13 +
 ...
 Testing/Temporary/CTestCostData.txt                |    1 +
 Testing/Temporary/LastTest.log                     |    3 +
 ...
 justfile                                           |  117 ++++++-----
 ...
 xbmc/interfaces/swig/CMakeLists.txt                |   12 +-
 xbmc/test/TestBasicEnvironment.cpp                 |   12 +-
 xbmc/test/TestUtils.cpp                            |   10 +-
```

### `git diff --stat` (unstaged)

Empty. There is no unstaged follow-up sitting beside the merge. The later
justfile / test-harness work is **already in the index**.

## 2. Previous reconstructed guess: corrected

The earlier report guessed:

- merge of `origin/master` into `HB` is in progress (true)
- `justfile` + `TestUtils.cpp` + `TestBasicEnvironment.cpp` may be
  **unstaged** follow-up that should stay off the merge (false)
- resolved `xbmc/interfaces/swig/CMakeLists.txt` should stay in the merge
  (true)

Those three harness files **are in the staged list**. Worktree matches
index for all four requested paths (`git diff -- <file>` is empty). They
will land in the merge commit unless unstaged first.

## 3. The four requested files

Blob IDs (`git rev-parse` / `git hash-object`):

| Path | HEAD (`HB`) | MERGE_HEAD (master) | INDEX / worktree |
|------|-------------|---------------------|------------------|
| `justfile` | `1a8b9066ac` | **missing** (master has no justfile) | `3a9392b82f` |
| `xbmc/test/TestUtils.cpp` | `af96872522` | `af96872522` (identical) | `76e4cf418b` |
| `xbmc/test/TestBasicEnvironment.cpp` | `c9f70fe8a5` | `3e4885653d` | `a6a057f555` |
| `xbmc/interfaces/swig/CMakeLists.txt` | `4b017a9aa5` | `dc6569a1b9` | `c4c4d30d10` |

Only both-sides-changed path vs merge-base: `xbmc/interfaces/swig/CMakeLists.txt`.

### `justfile` — local follow-up, unstage

Master does not have this file. A clean merge would keep the `HB` tip
blob `1a8b9066ac`. The index is a later rewrite (`3a9392b82f`).

Staged vs HEAD (`git diff --staged -- justfile`): 209 diff lines.
Adds `just check` / `just test`, `gtest_filter`, `-DENABLE_TESTING=ON`,
renames `configure force=` to `configure wipe=`, and always runs
`just configure` from `build` / `install`.

This is HB tooling, not merge resolution. **Unstage. Keep worktree.**

```bash
git restore --staged -- justfile
```

### `xbmc/test/TestUtils.cpp` — local follow-up, unstage

HEAD and master share blob `af96872522`. Master did not touch this file.
The staged hunk is entirely local:

- `SetReferenceFileBasePath()` stops using `CUtil::GetHomePath()`
- uses `CUtil::ResolveExecutablePath()` + `URIUtils::GetParentPath()`
- comment: testdata is next to `kodi-test` (`NO_INSTALL`); `KODI_HOME`
  may already be `INSTALL_PATH`

Sensible testdata-root fix. Not merge material. **Unstage. Keep worktree.**

```bash
git restore --staged -- xbmc/test/TestUtils.cpp
```

### `xbmc/test/TestBasicEnvironment.cpp` — mixed; do **not** bare-unstage

Three different blobs. Split the hunks:

1. **Master incoming** (`HEAD` → `MERGE_HEAD`): TearDown order only.
   Delete temp **after** `DeinitTesting()`, with comment
   `Removal after release of all open files`.
2. **Local extra** (`MERGE_HEAD` → index): remap
   `CSpecialProtocol::SetMasterProfilePath(m_tempPath)` and
   `SetHomePath(m_tempPath)`, plus the comment about
   `INSTALL_PATH/test_data` not being writable.

A clean merge of this file is master's blob `3e4885653d`.
`git restore --staged -- xbmc/test/TestBasicEnvironment.cpp` would put
**HEAD** back in the index and **drop master's TearDown change** from
the merge. Wrong.

Put master's version in the index only; leave the remaps in the worktree
for a second commit:

```bash
git restore --source=MERGE_HEAD --staged -- xbmc/test/TestBasicEnvironment.cpp
```

### `xbmc/interfaces/swig/CMakeLists.txt` — resolved merge, keep

Index is neither parent. Staged vs HEAD is only the generate-path
download helper (12 lines):

```diff
-    # file wont be downloaded if EXPECTED_HASH matches existing archive
-    file(DOWNLOAD ${GROOVY_URL} ... SHOW_PROGRESS EXPECTED_HASH ${GROOVY_URL_HASH})
+    # file won't be downloaded if HASH matches existing archive
+    core_file_download(${GROOVY_URL} ... HASH ${GROOVY_URL_HASH})
```

Same swap for commons-lang and commons-text.

That is HB's vendored-bindings / `ENABLE_GENERATE_PYTHON_BINDINGS`
structure plus master's `core_file_download`. No conflict markers.
**Keep staged.**

## 4. Other staged extras (not in the previous guess)

### Must not be in the merge commit

| Path | Why |
|------|-----|
| `.agents/reports/check-includes-build.md` | New; neither parent. Agent report. |
| `.agents/reports/ctest-failures-fix.md` | Same. |
| `.agents/reports/ctest-failures-root-cause.md` | Same. |
| `.agents/reports/ctest-gameclientdisc-write-fix.md` | Same. |
| `Testing/Temporary/CTestCostData.txt` | CTest cost cache. Neither parent. |
| `Testing/Temporary/LastTest.log` | CTest log (`Start testing: Aug 12 14:02 MDT`). |

`build/` is **not** staged (`git diff --staged --name-only -- build` empty).

Unstage those six paths (they become untracked again; they were never
on `HB` tip):

```bash
git restore --staged -- \
  .agents/reports/check-includes-build.md \
  .agents/reports/ctest-failures-fix.md \
  .agents/reports/ctest-failures-root-cause.md \
  .agents/reports/ctest-gameclientdisc-write-fix.md \
  Testing/Temporary/CTestCostData.txt \
  Testing/Temporary/LastTest.log
```

### Keep: incoming master + HB-only files that belong

- `.editorconfig` is new on this branch vs `HB`, but it **is** on master.
  INDEX blob `78062f8f43` == `MERGE_HEAD:.editorconfig`. Keep.
- `flake.nix`, `flake.lock`, `.gitignore`, and the other vendored
  `generated/*.i.cpp` files are **not** in `git diff --staged --name-only`.
  They stay at `HB` tip. Correct (master does not have them; merge keeps ours).
- Master deletions (p8-platform, old cec patches, in-tree dvdnav headers,
  old `RenderCapture*`, etc.) are staged as deletions. That is the merge.

### Keep: two regenerated vendored bindings

These are HB-only files (missing on master) whose index **differs** from
`HEAD`:

- `xbmc/interfaces/python/generated/AddonModuleXbmc.i.cpp`
  (`68e6d3c3c6` → `6ce80c8853`, +172): wraps master's new
  `xbmc.getDatabaseName` and `xbmc.getDevicePowerStatus`
- `xbmc/interfaces/python/generated/AddonModuleXbmcgui.i.cpp`
  (`d289d4fcbd` → `5467c1f62d`, +143): wraps master's new
  `ControlVideoWindow`

That is merge-related codegen so HB's no-Groovy vendored sources match
incoming Python API. **Leave them in this merge.** They are not the
justfile / testdata / discstate follow-up.

Other generated modules (`AddonModuleXbmcaddon.i.cpp`, `…drm`,
`…plugin`, `…vfs`, `…wsgi`) still match `HEAD`. Good.

## 5. Conflict markers

```
git diff --staged | rg -n '^(<<<<<<<|=======|>>>>>>>)'
# → no matches
```

No markers in the four requested worktree files either.

## 6. What to do on the TTY (no agent git)

Unstage extras; put master's `TestBasicEnvironment.cpp` in the index;
do **not** touch the worktree copies of the harness files:

```bash
git restore --staged -- \
  justfile \
  xbmc/test/TestUtils.cpp \
  .agents/reports/check-includes-build.md \
  .agents/reports/ctest-failures-fix.md \
  .agents/reports/ctest-failures-root-cause.md \
  .agents/reports/ctest-gameclientdisc-write-fix.md \
  Testing/Temporary/CTestCostData.txt \
  Testing/Temporary/LastTest.log

git restore --source=MERGE_HEAD --staged -- xbmc/test/TestBasicEnvironment.cpp
```

Then re-check:

```bash
git diff --staged --name-only | rg 'justfile|TestUtils|TestBasicEnvironment|\.agents/|Testing/'
# expect only: xbmc/test/TestBasicEnvironment.cpp
# and that staged hunk should be TearDown-only vs HEAD

git diff --stat
# expect justfile + TestUtils + TestBasicEnvironment remaps as unstaged
```

After that, **OK to conclude the merge** with the existing
`Merge branch 'master' into HB` message (signed, on a real TTY).

Second commit (after the merge, not in it):

- `justfile` rewrite
- `xbmc/test/TestUtils.cpp` testdata root
- `xbmc/test/TestBasicEnvironment.cpp` home / masterprofile remaps

## 7. Sensibility notes (not merge blockers)

- Swig resolution keeps the HB default (compile vendored `generated/`)
  and only takes master's download helper on the generate escape hatch.
- `just check` building `--target kodi-test` then `ctest` is consistent
  with `kodi-test` being `EXCLUDE_FROM_ALL`.
- TestUtils executable-dir root is the right fix for `NO_INSTALL`
  testdata when `KODI_HOME` is a system prefix.
- TestBasicEnvironment remaps both `home` and `masterprofile` onto the
  **same** temp path. Upstream TEST layout is
  `home = …/test_data` and `masterprofile = …/test_data/userdata`.
  Fine if every writer uses `special://masterprofile/...` directly.
  Wrong if something still assumes masterprofile is `home/userdata`.
  That is a second-commit nit, not a reason to keep the remaps in the
  merge.

## 8. Verdict (short)

**Wait / split.**

- Merge in progress, conflicts cleared, 681 staged files, 0 unstaged.
- Keep: incoming master, resolved `xbmc/interfaces/swig/CMakeLists.txt`,
  regenerated `AddonModuleXbmc.i.cpp` and `AddonModuleXbmcgui.i.cpp`.
- Unstage first: `justfile`, `TestUtils.cpp`, the four `.agents/reports/*`
  files, and `Testing/Temporary/*`.
- For `TestBasicEnvironment.cpp`, restore the **master** blob into the
  index (`--source=MERGE_HEAD --staged`), do not bare-unstage.
- `build/` is not staged. This report file is untracked only.
