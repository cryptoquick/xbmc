# `just check` now includes the full `just build`

## What changed

`justfile` recipe `check` no longer stops at configure + `kodi-test`. After the cheap local checks it now runs the same full build as `just build`, then the existing unit-test steps.

`just install` is unchanged: configure + full `cmake --build` + install.

## How check invokes build

`check` is still a shebang recipe (not a just dependency of `build`). Order:

1. `just --fmt --unstable --check`
2. `just bindings-check`
3. `just build` (composes the existing recipe; no duplicated cmake flags)
4. `cmake --build <build_dir> --target kodi-test`
5. `ctest` (same `KODI_GTEST_FILTER` / `gtest_filter` handling as before)

`just build` itself is still `just configure` then default `cmake --build` (kodi binary + deps). That is why `check` dropped its standalone `just configure`: `build` already configures.

## Recipe dependency notes

- **Not** `check: build` as a just dependency. That would run the full compile before fmt/bindings, and would invert the cheap-fail order.
- `kodi-test` is `EXCLUDE_FROM_ALL` in root `CMakeLists.txt`, so the default `just build` target does **not** produce the test binary. Check still builds `--target kodi-test` after `just build`, then runs `ctest`.
- `just test` is unchanged: configure + `kodi-test` + `ctest` only (no fmt, no bindings, no full kodi binary).
- `just install` still does its own configure + full `cmake --build` + install; it does not call `just check`.
