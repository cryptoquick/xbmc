# Kodi/XBMC developer commands (bindings + local build/install)
#
# Bindings (no Groovy on the daily path):
#   just bindings-update   # regenerate vendored Python bindings via Nix
#   just bindings-check    # fail if generated/ drifts from hermetic regen
#
# Build / install:
#   just configure
#   just build
#   just install           # configure (if needed) + build + install
#   just clean             # wipe incomplete/failed build dir
#
# Overrides (env or just var=value):
#   just install prefix=$HOME/.local
#   just configure platform=wayland render=gl
#   just build jobs=8
#   just configure force=1

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false

# Out-of-tree build directory (relative to repo root)
build_dir := env_var_or_default("KODI_BUILD_DIR", "build")

# Install prefix (CMAKE_INSTALL_PREFIX)
prefix := env_var_or_default("KODI_PREFIX", "/usr/local")

# Optional DESTDIR for staged installs (empty = install straight to prefix)
destdir := env_var_or_default("KODI_DESTDIR", "")

# Windowing: x11 | wayland | gbm | or space-separated combo in quotes
platform := env_var_or_default("KODI_PLATFORM", "x11")

# Render system: gl | gles
render := env_var_or_default("KODI_RENDER", "gl")

# Parallelism for cmake --build
jobs := env_var_or_default("KODI_JOBS", `nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4`)

# Extra cmake args (appended after defaults), e.g. '-DENABLE_AIRTUNES=OFF'
cmake_args := env_var_or_default("KODI_CMAKE_ARGS", "")

# Build common missing deps from tree when distro packages are absent/outdated.
# Set KODI_INTERNAL_DEPS=0 to rely only on system packages.
internal_deps := env_var_or_default("KODI_INTERNAL_DEPS", "1")

# Use sudo for install when prefix is not writable (default: auto)
# Set KODI_SUDO=0 to never sudo, KODI_SUDO=1 to always sudo
sudo_mode := env_var_or_default("KODI_SUDO", "auto")

root := justfile_directory()

# Default recipe list
default:
    @just --list --unsorted

# ---------------------------------------------------------------------------
# Python bindings (Nix hermetic codegen → vendored generated/)
# ---------------------------------------------------------------------------

# Regenerate xbmc/interfaces/python/generated/*.cpp via the flake
bindings-update:
    nix run "{{ root }}#update-python-bindings"

# Assert vendored bindings match a clean Nix regen
bindings-check:
    nix run "{{ root }}#check-python-bindings"

# Build bindings package only (outputs store path with .cpp files)
bindings-build:
    nix build "{{ root }}#python-bindings" -L

# Alias: update bindings
bindings: bindings-update

# ---------------------------------------------------------------------------
# Configure / build / install
# ---------------------------------------------------------------------------

# Configure out-of-tree build (skips only if configure fully succeeded)
# force=1 always re-runs cmake.
configure force="0":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ root }}"
    bd="{{ build_dir }}"

    is_configured() {
      # Complete configure produces a native build system file.
      [[ -f "$bd/CMakeCache.txt" ]] && { [[ -f "$bd/Makefile" ]] || [[ -f "$bd/build.ninja" ]]; }
    }

    mkdir -p "$bd"

    if [[ "{{ force }}" != "1" ]] && is_configured; then
      echo "Already configured ($bd has Makefile/build.ninja)."
      echo "Re-run with: just configure force=1"
      exit 0
    fi

    # Failed prior configure leaves CMakeCache.txt but no Makefile/build.ninja.
    if [[ -f "$bd/CMakeCache.txt" ]] && ! is_configured; then
      echo "Found incomplete configure in $bd; cleaning it first…"
      rm -rf "$bd"
      mkdir -p "$bd"
    fi

    internal=()
    if [[ "{{ internal_deps }}" == "1" || "{{ internal_deps }}" == "true" || "{{ internal_deps }}" == "yes" ]]; then
      # Common deps missing or too old on many distros (see docs/README.Linux.md §3.2)
      internal+=(
        -DENABLE_INTERNAL_FLATBUFFERS=ON
        -DENABLE_INTERNAL_CROSSGUID=ON
        -DENABLE_INTERNAL_FMT=ON
        -DENABLE_INTERNAL_SPDLOG=ON
        -DENABLE_INTERNAL_FSTRCMP=ON
        -DENABLE_INTERNAL_NLOHMANNJSON=ON
      )
    fi

    echo "Configuring $bd (prefix={{ prefix }} platform={{ platform }} render={{ render }})…"
    # shellcheck disable=SC2086
    cmake -S . -B "$bd" \
      -DCMAKE_INSTALL_PREFIX="{{ prefix }}" \
      -DCORE_PLATFORM_NAME="{{ platform }}" \
      -DAPP_RENDER_SYSTEM="{{ render }}" \
      "${internal[@]}" \
      {{ cmake_args }}

    if ! is_configured; then
      echo "error: cmake finished but $bd has no Makefile/build.ninja" >&2
      exit 1
    fi
    echo "Configured OK → $bd"

# Build Kodi (configures first if needed)
build:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ root }}"
    bd="{{ build_dir }}"
    is_configured() {
      [[ -f "$bd/CMakeCache.txt" ]] && { [[ -f "$bd/Makefile" ]] || [[ -f "$bd/build.ninja" ]]; }
    }
    if ! is_configured; then
      if [[ -f "$bd/CMakeCache.txt" ]]; then
        echo "Build dir exists but configure did not finish (no Makefile/build.ninja)."
        echo "Re-running configure…"
      fi
      just configure force=1
    fi
    cmake --build "{{ root }}/{{ build_dir }}" -j"{{ jobs }}"

# Build only the python_binding static lib (uses vendored sources by default)
build-python-binding:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ root }}"
    bd="{{ build_dir }}"
    is_configured() {
      [[ -f "$bd/CMakeCache.txt" ]] && { [[ -f "$bd/Makefile" ]] || [[ -f "$bd/build.ninja" ]]; }
    }
    if ! is_configured; then
      just configure force=1
    fi
    cmake --build "{{ root }}/{{ build_dir }}" --target python_binding -j"{{ jobs }}"

# Install a Kodi build into prefix (configure + build + install)
install: build
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ root }}"

    if [[ -n "{{ destdir }}" ]]; then
      export DESTDIR="{{ destdir }}"
    fi

    need_sudo=0
    case "{{ sudo_mode }}" in
      1|true|yes) need_sudo=1 ;;
      0|false|no) need_sudo=0 ;;
      auto)
        if [[ -n "${DESTDIR:-}" ]]; then
          dest_root="$DESTDIR"
        else
          dest_root="{{ prefix }}"
        fi
        mkdir -p "$dest_root" 2>/dev/null || true
        if [[ ! -w "$dest_root" ]]; then
          need_sudo=1
        fi
        ;;
      *)
        echo "Unknown KODI_SUDO/sudo_mode={{ sudo_mode }} (use auto|0|1)" >&2
        exit 1
        ;;
    esac

    echo "Installing to prefix={{ prefix }}${DESTDIR:+ (DESTDIR=$DESTDIR)}"
    if [[ "$need_sudo" -eq 1 ]]; then
      if [[ -n "${DESTDIR:-}" ]]; then
        sudo --preserve-env=DESTDIR cmake --install "{{ build_dir }}"
      else
        sudo cmake --install "{{ build_dir }}"
      fi
    else
      cmake --install "{{ build_dir }}"
    fi
    echo "Install complete. Binary (typical): {{ prefix }}/bin/kodi"

# Uninstall via cmake's uninstall target if present
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{ root }}"
    bd="{{ build_dir }}"
    if [[ ! -f "$bd/Makefile" && ! -f "$bd/build.ninja" ]]; then
      echo "No complete build at $bd; nothing to uninstall via build tree." >&2
      exit 1
    fi
    need_sudo=0
    case "{{ sudo_mode }}" in
      1|true|yes) need_sudo=1 ;;
      0|false|no) need_sudo=0 ;;
      auto)
        if [[ ! -w "{{ prefix }}" ]]; then
          need_sudo=1
        fi
        ;;
    esac
    if [[ "$need_sudo" -eq 1 ]]; then
      sudo cmake --build "{{ build_dir }}" --target uninstall
    else
      cmake --build "{{ build_dir }}" --target uninstall
    fi

# Remove the build directory
clean:
    rm -rf "{{ root }}/{{ build_dir }}"

# Configure (force) + build + install
reinstall: (configure "1") install
