{
  description = "Kodi/XBMC tooling: hermetic Python binding codegen (SWIG+Groovy) and vendored outputs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # Pins mirrored from xbmc/interfaces/swig/CMakeLists.txt
        groovyVer = "4.0.30";
        groovy = pkgs.fetchurl {
          url = "https://mirrors.kodi.tv/build-deps/sources/apache-groovy-binary-${groovyVer}.zip";
          hash = "sha512-eJ6VbsrTwwLVRaFsrM1FRUNXVWtWbug6v6/hAjcc8hj17V3IPXSFlfuy1GW95scwakmIBuWLUSz8dCq+X1sQHQ==";
        };

        commonsLangVer = "3.20.0";
        commonsLang = pkgs.fetchurl {
          url = "https://mirrors.kodi.tv/build-deps/sources/commons-lang3-${commonsLangVer}-bin.tar.gz";
          hash = "sha512-7q0sBKhchc/IPvioWPlU56v2aDZ9WkLhFS611lbrj0wdXnrQP0aFnpk5PpKw1fxpyScwHBospGajxJ+x8YbOiQ==";
        };

        commonsTextVer = "1.15.0";
        commonsText = pkgs.fetchurl {
          url = "https://mirrors.kodi.tv/build-deps/sources/commons-text-${commonsTextVer}-bin.tar.gz";
          hash = "sha512-bR/L2FqF846V6jPJq39YeYcjsOY1cHckahNcQX51x7OeJ469t3/Mj5tWtSse7/ET7qlGPqqu6NON+a/cFJtkIQ==";
        };

        modules = [
          "AddonModuleXbmcaddon.i"
          "AddonModuleXbmcdrm.i"
          "AddonModuleXbmcgui.i"
          "AddonModuleXbmc.i"
          "AddonModuleXbmcplugin.i"
          "AddonModuleXbmcvfs.i"
          "AddonModuleXbmcwsgi.i"
        ];

        # Full checkout for correct SWIG include closure (headers pull widely under xbmc/).
        python-bindings = pkgs.stdenvNoCC.mkDerivation {
          pname = "kodi-python-bindings";
          version = "0.1.0";

          # Full checkout for correct SWIG include closure (headers pull widely).
          src = pkgs.lib.cleanSource ./.;

          nativeBuildInputs = [
            pkgs.swig
            pkgs.jdk17_headless
            pkgs.unzip
            pkgs.gnutar
            pkgs.gzip
          ];

          dontConfigure = true;

          buildPhase = ''
            runHook preBuild
            set -euo pipefail
            export LC_ALL=C
            export LANG=C

            # $src is the cleaned tree; $PWD is the build directory (copy of src for stdenv).
            # Prefer $PWD contents (stdenv unpack puts sources here).
            ROOT="$PWD"

            TOOLS="$PWD/.codegen-tools"
            mkdir -p "$TOOLS"
            unzip -q ${groovy} -d "$TOOLS"
            mv "$TOOLS/groovy-${groovyVer}" "$TOOLS/groovy"

            mkdir -p "$TOOLS/commons-lang" "$TOOLS/commons-text"
            tar -xzf ${commonsLang} -C "$TOOLS/commons-lang" --strip-components=1
            tar -xzf ${commonsText} -C "$TOOLS/commons-text" --strip-components=1

            shopt -s nullglob
            CP=""
            for j in "$TOOLS"/groovy/lib/*.jar "$TOOLS"/commons-lang/*.jar "$TOOLS"/commons-text/*.jar; do
              CP="''${CP:+$CP:}$j"
            done
            CP="$CP:$ROOT/tools/codegenerator:$ROOT/xbmc/interfaces/python"

            JAVA_OPEN_OPTS=(
              --add-opens java.base/java.util=ALL-UNNAMED
              --add-opens java.base/java.util.regex=ALL-UNNAMED
              --add-opens java.base/java.io=ALL-UNNAMED
              --add-opens java.base/java.lang=ALL-UNNAMED
              --add-opens java.base/java.net=ALL-UNNAMED
            )

            template="$ROOT/xbmc/interfaces/python/PythonSwig.cpp.template"
            generator="$ROOT/tools/codegenerator/Generator.groovy"
            outdir="$PWD/generated-out"
            mkdir -p "$outdir"
            cd "$outdir"

            for mod in ${pkgs.lib.concatStringsSep " " modules}; do
              echo "=== Generating $mod ==="
              swig -w401 -c++ -o "$mod.xml" -xml \
                -I"$ROOT/xbmc" \
                "$ROOT/xbmc/interfaces/swig/$mod"
              java "''${JAVA_OPEN_OPTS[@]}" -cp "$CP" groovy.ui.GroovyMain \
                "$generator" \
                "$mod.xml" \
                "$template" \
                "$mod.cpp"
              test -s "$mod.cpp"
              # Drop intermediate XML from the install set
              rm -f "$mod.xml"
            done

            cd "$ROOT"
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            mkdir -p "$out"
            cp generated-out/AddonModule*.i.cpp "$out/"
            ls -la "$out"
            runHook postInstall
          '';
        };

        updateScript = pkgs.writeShellApplication {
          name = "update-python-bindings";
          runtimeInputs = [ pkgs.nix pkgs.coreutils pkgs.git ];
          text = ''
            set -euo pipefail
            if root=$(git rev-parse --show-toplevel 2>/dev/null); then
              :
            else
              root="$PWD"
            fi
            dest="$root/xbmc/interfaces/python/generated"
            mkdir -p "$dest"
            echo "Building python-bindings…"
            out=$(nix build "$root#python-bindings" --no-link --print-out-paths)
            echo "Copying from $out → $dest"
            cp -f "$out"/AddonModule*.i.cpp "$dest/"
            chmod u+w "$dest"/AddonModule*.i.cpp
            echo "Updated:"
            ls -la "$dest"/AddonModule*.i.cpp
          '';
        };

        checkScript = pkgs.writeShellApplication {
          name = "check-python-bindings";
          runtimeInputs = [ pkgs.nix pkgs.coreutils pkgs.diffutils pkgs.git ];
          text = ''
            set -euo pipefail
            if root=$(git rev-parse --show-toplevel 2>/dev/null); then
              :
            else
              root="$PWD"
            fi
            dest="$root/xbmc/interfaces/python/generated"
            out=$(nix build "$root#python-bindings" --no-link --print-out-paths)
            echo "Diffing $out vs $dest"
            # Compare only the .cpp files (ignore extra files in dest like README)
            fail=0
            for f in "$out"/AddonModule*.i.cpp; do
              base=$(basename "$f")
              if ! diff -u "$f" "$dest/$base"; then
                fail=1
              fi
            done
            if [[ "$fail" -ne 0 ]]; then
              echo "ERROR: vendored python bindings drift from hermetic generator" >&2
              exit 1
            fi
            echo "OK: vendored python bindings match hermetic generator output"
          '';
        };

      in {
        packages.python-bindings = python-bindings;
        packages.default = python-bindings;

        apps.update-python-bindings = {
          type = "app";
          program = "${updateScript}/bin/update-python-bindings";
        };
        apps.check-python-bindings = {
          type = "app";
          program = "${checkScript}/bin/check-python-bindings";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.swig
            pkgs.jdk17_headless
            pkgs.unzip
          ];
        };
      });
}
