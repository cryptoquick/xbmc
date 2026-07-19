# Plan: Vendor Python bindings via Nix (sideline Groovy)

## Context

Kodi’s Python addon API is not hand-written C++. At build time, when `ENABLE_PYTHON=ON` (default):

1. **SWIG** parses seven `.i` modules → XML (not stock SWIG-Python).
2. **Groovy** (`Generator.groovy` + helpers + `PythonSwig.cpp.template`) turns that XML into `AddonModule*.i.cpp`.
3. Those sources compile into static lib `python_binding`, linked into `libkodi`.

Groovy is **build-only**, ~2.6k lines of generator/template logic, and pulls a JVM + Groovy 4.0.30 + Commons jars (often downloaded at configure from `mirrors.kodi.tv`). It is widely disliked as a host dependency and is unrelated to Android’s Gradle packaging.

**Goal:** Make the everyday CMake build compile **vendored** binding `.cpp` with **no Java/Groovy/SWIG**, and put the hermetic “run the old generator when APIs change” path behind a **Nix flake**.

**Constraints:**

- Fork/branch `HB` — can diverge from upstream CMake; keep an escape hatch so upstream merges stay sane.
- Do **not** rewrite the media stack or package all of Kodi in Nix on day one.
- Generated C++ is meant to be **portable** (CPython3 + Kodi helpers); regen is host-tooling only.
- `TestSwig.cpp` only tests a type-name helper — **not** a golden-file guard for codegen. We must add our own freshness check.
- Nix is available on this machine (`nix 2.34.8`).

**Non-goals (this plan):**

- Porting Groovy → Python (nice later; not required to ditch daily Groovy).
- Full `flake` packaging of Kodi/FFmpeg/depends.
- Touching Android Gradle.
- Removing generator sources from the tree immediately (keep them for Nix regen until a future rewrite).

**Assumptions:**

- Default product builds want Python ON.
- Vendored sources live in git (reviewable diffs when APIs change).
- One Linux/x86_64 Nix regen is enough for all targets (verify once; `.i` conditionals are source-level, not host-codegen).

## Approach

**Recommended path: vendor-by-default + Nix-only regen.**

```text
                    ┌─────────────────────────────┐
  .i + legacy hdrs  │  nix build .#python-bindings │  (SWIG + Groovy, pinned)
  template/typemaps │  → seven AddonModule*.i.cpp  │
                    └──────────────┬──────────────┘
                                   │ nix run .#update-python-bindings
                                   ▼
              xbmc/interfaces/python/generated/*.cpp   ← committed
                                   │
              CMake (ENABLE_PYTHON) │ no Java/Groovy/SWIG
                                   ▼
                         python_binding (STATIC) → libkodi
```

1. **Check in** generated `AddonModule*.i.cpp` under `xbmc/interfaces/python/generated/`.
2. **CMake:** if vendored files present (or `KODI_VENDORED_PYTHON_BINDINGS=ON`), use them as `python_binding` sources and **skip** `find_package(Java/SWIG)`, downloads, and `generate_file()`.
3. **Escape hatch:** `KODI_GENERATE_PYTHON_BINDINGS=ON` restores classic in-tree SWIG+Groovy (upstream-compatible path for bisect/merge).
4. **Flake** pins SWIG **4.4.0** (matches `tools/depends/native/swig`), Groovy **4.0.30** + Commons hashes from current `CMakeLists.txt`, runs the same pipeline, installs `.cpp` to `$out`.
5. **Update app** copies `$out` → `generated/` for a commit.
6. **CI/check script:** regenerate in Nix and `diff` against git (fails on drift).

**Material alternatives rejected:**

- **Nix devShell only (still run Groovy every build)** — hermetic but still obnoxious daily.
- **Rewrite generator in Python first** — better long-term, larger upfront; can follow after vendoring stabilizes golden outputs.
- **`ENABLE_PYTHON=OFF`** — removes Groovy but kills addon Python; not acceptable as default.
- **Full Kodi flake app** — out of scope; bindings slice is enough.

## Critical files

| Path | Why |
|------|-----|
| `xbmc/interfaces/swig/CMakeLists.txt` | Entire generate + `python_binding` target; main edit |
| `xbmc/interfaces/swig/AddonModule*.i` | Module boundaries / `%include` list (regen inputs) |
| `xbmc/interfaces/python/PythonSwig.cpp.template` | Emission template |
| `xbmc/interfaces/python/{PythonTools,MethodType}.groovy` | Classpath helpers |
| `xbmc/interfaces/python/typemaps/*` | In/out conversion snippets |
| `tools/codegenerator/{Generator,Helper,SwigTypeParser}.groovy` | Generator kept for Nix only |
| `xbmc/interfaces/python/AddonPythonInvoker.cpp` | Expects `PyInit_Module_*` from generated code |
| `xbmc/interfaces/legacy/**` | Headers SWIG parses; changes force regen |
| `cmake/treedata/optional/common/python.txt` | `ENABLE_PYTHON` → swig subdir |
| `tools/depends/native/swig/SWIG-VERSION` | Pin SWIG 4.4.0 in flake |
| **New** `xbmc/interfaces/python/generated/` | Vendored `.cpp` + short README |
| **New** `flake.nix` (+ `flake.lock`) | Hermetic regen |
| **New** `tools/codegenerator/nix/` (optional scripts) | `update-bindings.sh`, `check-bindings.sh` |
| **New** `.github/workflows/python-bindings.yml` (optional) | Drift CI if GH Actions is used |

## Reuse

| Symbol / module | Path | How |
|-----------------|------|-----|
| `generate_file()` / `INPUTS` list | `xbmc/interfaces/swig/CMakeLists.txt` | Split: vendored branch vs generate branch; keep module list as single source of truth |
| `GROOVY_VER` / URL hashes | same file | Copy pins into `flake.nix` (or share a tiny `versions.json` both read) |
| `SWIG_ARGS` | same file | Mirror exactly in Nix derivation |
| `groovy_SOURCE_DIR` overrides | same file | Flake can set these if we ever call CMake for regen; prefer direct `java`/`swig` like custom command |
| `python_binding` target props | same file | Unchanged PIC / warn flags / `core_target_link_libraries` |
| `ENABLE_PYTHON` | root `CMakeLists.txt` | Unchanged gate |
| Depends SWIG 4.4.0 | `tools/depends/native/swig/` | Flake pin alignment |

## Steps

### 1. Spike: capture a golden generation once

- Configure a normal Python-ON build **or** run SWIG+Groovy by hand with pinned tools into a temp dir.
- Produce the seven files:  
  `AddonModuleXbmc.i.cpp`, `…addon`, `…drm`, `…gui`, `…plugin`, `…vfs`, `…wsgi`.
- **Disable clang-format** for this capture (CMake only formats if `CLANGFORMAT_FOUND` — avoid host format skew).
- Note approximate size; confirm symbols `PyInit_Module_xbmc` etc. exist (`nm`/`grep`).
- *Depends on: nothing.*

### 2. Add vendored tree layout

```text
xbmc/interfaces/python/generated/
  README.md          # how to regen (nix run …); do not edit by hand
  AddonModuleXbmc.i.cpp
  AddonModuleXbmcaddon.i.cpp
  ...
```

- Commit generated sources from step 1.
- `.gitignore`: do **not** ignore this directory (explicitly document).
- *Depends on: 1.*

### 3. CMake: prefer vendored, optional classic codegen

Edit `xbmc/interfaces/swig/CMakeLists.txt`:

- Introduce options (names bikeshed-ok at implement time):

  - `KODI_VENDORED_PYTHON_BINDINGS` — default **ON** if all seven files exist under `generated/`, else OFF.
  - `KODI_GENERATE_PYTHON_BINDINGS` — default **OFF**; when ON, force classic SWIG+Groovy path (implies ignore vendored).

- **Vendored path:**

  - `set(SOURCES …/generated/AddonModule….i.cpp)` (absolute/`CMAKE_SOURCE_DIR` paths).
  - `add_library(python_binding STATIC ${SOURCES})` + existing properties/link lines.
  - **Do not** `find_package(Java)`, **do not** download Groovy/Commons, **do not** `find_package(SWIG)`.

- **Generate path:** keep current `generate_file()` logic largely intact for escape hatch / upstream parity.

- Single list of module basenames shared by both branches.

- Optional: `message(STATUS "python_binding: using vendored sources")` vs `generating via SWIG+Groovy`.

- *Depends on: 2.*

### 4. Flake: hermetic generator package

Add root `flake.nix` / `flake.lock`:

```nix
# conceptual attributes
packages.${system}.python-bindings  # derivation output: seven .cpp
apps.${system}.update-python-bindings
apps.${system}.check-python-bindings
devShells.${system}.default         # optional: swig+jdk+groovy for debugging
```

**Derivation outline:**

- Inputs: `swig` (prefer 4.4.x; overlay/pin if nixpkgs differs), `jdk` (17+), fetchurl Groovy zip + Commons (same hashes as CMake), source tree (or filtered `src` with only interfaces + tools/codegenerator + headers SWIG needs).
- `buildPhase` per module (cwd = work dir):

  ```bash
  swig -w401 -c++ -o "$mod.xml" -xml -I"$src/xbmc" "$src/xbmc/interfaces/swig/$mod"
  java $JAVA_OPEN_OPTS -cp "$CP" groovy.ui.GroovyMain \
    "$src/tools/codegenerator/Generator.groovy" \
    "$mod.xml" \
    "$src/xbmc/interfaces/python/PythonSwig.cpp.template" \
    "$mod.cpp"
  ```

- Classpath must include: groovy `lib/*`, commons jars, `tools/codegenerator`, `xbmc/interfaces/python` (typemap resolution uses template parent + `typemaps/`).
- **No** clang-format in the derivation.
- `installPhase`: copy `*.cpp` → `$out/`.
- Use a **filtered src** or careful `src = ./.;` with `builtins.path` filter to avoid copying huge unrelated trees if possible; correctness first (full repo src is OK for v1).

**Apps:**

- `update-python-bindings`: `cp -f result/*.cpp $REPO/xbmc/interfaces/python/generated/`
- `check-python-bindings`: build package, `diff -ru` against `generated/`; exit non-zero on drift.

Document in `generated/README.md` and a short `docs/` or root note only if the fork already documents build forks — prefer README in `generated/` + flake description to avoid doc sprawl.

- *Depends on: 1–2 for path contracts; can parallelize with 3.*

### 5. Wire developer UX

- `nix run .#update-python-bindings` after changing `.i`, legacy headers in the SWIG include set, template, typemaps, or Groovy helpers.
- Document failure mode: forgot to regen → compile errors or subtle API mismatch; CI check catches drift when generator inputs change **and** someone runs check (input-file hash stamp optional enhancement).

Optional small helper:

```bash
# tools/codegenerator/nix/check-bindings.sh
nix build .#python-bindings --print-out-paths | xargs -I{} diff -ru {} xbmc/interfaces/python/generated
```

- *Depends on: 4.*

### 6. Freshness / CI

- Add a lightweight check runnable locally and in CI:
  - **Minimum:** `nix run .#check-python-bindings` on PRs that touch `interfaces/swig`, `interfaces/legacy`, `interfaces/python/PythonSwig*`, `typemaps`, `tools/codegenerator`.
  - **Path filter** workflow under `.github/workflows/` if this fork uses GHA for real builds; sonarqube already installs JRE+swig and would benefit from vendored default (no Groovy download during configure).
- Optional stamp file `generated/INPUTS.sha256` listing hashes of `.i`+template+groovy+typemaps for a fast pre-diff bailout — nice-to-have, not required for v1.

- *Depends on: 4–5.*

### 7. Verification build

- Cold configure with **no** Java on `PATH` (or `JAVA_HOME` unset):  
  `cmake -DENABLE_PYTHON=ON …` must succeed and build `python_binding` from vendored sources.
- Confirm `libkodi` links `PyInit_Module_*`.
- Smoke: run Kodi (or existing unit tests) with a trivial Python addon import (`import xbmc`, `xbmcgui`) if an environment exists.
- Escape hatch: `-DKODI_GENERATE_PYTHON_BINDINGS=ON` still works when JRE+SWIG+network/pins available.
- `nix run .#check-python-bindings` clean on committed tree.

- *Depends on: 3–6.*

### 8. (Follow-up, separate PR) Soft-deprecation of in-tree Groovy path

- After vendored path is default and trusted: leave generator sources + flake only; mark CMake generate path as “maintainer escape hatch”.
- Later epic: replace Groovy with Python using vendored `.cpp` as golden tests — out of this plan’s implementation steps but unblocked by it.

## Risks

| Risk | Mitigation |
|------|------------|
| Stale vendored `.cpp` after API header edits | `check-python-bindings` + docs; optional INPUTS hash; code review culture on `generated/` |
| Non-deterministic Groovy/JVM output | Pin Groovy/Java/SWIG; no clang-format; normalize newlines (`LC_ALL=C`, avoid `Helper.newline` host skew if it affects output — verify in spike) |
| SWIG XML differs across versions | Pin **4.4.0** to match depends |
| Flake `src` incomplete (missing headers for SWIG `-MM` set) | First version: pass full repo src; tighten filter after first green regen |
| Huge noisy diffs in git | Isolate under `generated/`; single “regen bindings” commits; `.gitattributes` linguist-generated optional |
| Upstream merge conflicts in `swig/CMakeLists.txt` | Keep classic path behind one clear `if()`; minimize churn in generate branch |
| Cross-compile / Windows | Vendored C++ should compile everywhere; **regen** is Linux/Nix-first; Windows devs use vendored only |
| Sonar/CI still installs JRE | Harmless; can drop JRE from python-ON jobs later once vendored is proven |
| Director / multi-module type bugs only show at runtime | Keep escape hatch; smoke-import modules; don’t claim full addon suite in v1 |

## Verification

1. **No-JVM configure**
   ```bash
   # PATH without java/groovy/swig
   cmake -B build -DENABLE_PYTHON=ON … 
   cmake --build build --target python_binding
   ```
   Expect: configure does not download Groovy; build compiles `generated/*.cpp`.

2. **Symbol check**
   ```bash
   nm -C build/.../libpython_binding.a | grep PyInit_Module_
   ```
   Expect all of: `xbmc`, `xbmcgui`, `xbmcaddon`, `xbmcplugin`, `xbmcvfs`, `xbmcdrm` (wsgi may be registered differently — match `AddonPythonInvoker.cpp`).

3. **Nix round-trip**
   ```bash
   nix build .#python-bindings
   nix run .#check-python-bindings   # exit 0 on clean tree
   ```

4. **Escape hatch**
   ```bash
   cmake -B build-gen -DKODI_GENERATE_PYTHON_BINDINGS=ON -DENABLE_PYTHON=ON …
   # requires SWIG+Java; produces build/swig/*.cpp
   ```

5. **Drift signal**
   Edit a typemap or `.i` comment that affects output → check must fail until `update-python-bindings` is run.

6. **Existing test**
   `TestSwig.TypeConversion` still passes (unaffected, sanity only).

## Open questions

- **Commit generated files in the first PR vs flake-only artifacts:** Plan assumes **commit to git** so non-Nix builders work offline without JVM. Confirm if any builder must remain fully generate-from-scratch without vendored sources (then default OFF on those — unlikely for this fork).
- **Flake location:** repo root `flake.nix` (recommended) vs `tools/codegenerator/nix/flake.nix` (narrower, awkward `src` paths).
- **Option naming:** `KODI_*` vs `ENABLE_VENDORED_PYTHON_BINDINGS` to match existing `ENABLE_PYTHON` style — prefer `ENABLE_VENDORED_PYTHON_BINDINGS` default ON when files exist for consistency with Kodi option naming.
- **wsgi module:** generated and in `INPUTS`, but `AddonPythonInvoker` module table may not list wsgi the same way — keep generating all seven regardless; don’t drop modules.
- **Whether to add GHA workflow now** or only local `nix run` checks — recommend script in-repo first, workflow if CI is actually used for this fork.

## Implementation todo seeds (post-approval)

- `impl:spike-golden` — Generate once; verify symbols; note determinism
- `impl:vendor-tree` — Add `generated/` + README + commit cpp
- `impl:cmake-vendored` — Dual-path `swig/CMakeLists.txt`
- `impl:flake` — `flake.nix` package + update/check apps + lock
- `impl:docs-ux` — README + developer one-liner
- `impl:verify` — No-JVM build, nix check, escape hatch
- `impl:ci-optional` — Path-filtered check workflow or document manual gate
