# Vendored Python binding sources

These `AddonModule*.i.cpp` files are the C++ Python addon API glue that used to
be generated on every CMake configure/build via **SWIG + Groovy**.

They are **generated code**. Do not edit by hand.

## Regenerate (Nix)

From the repository root (requires Nix with flakes):

```bash
nix run .#update-python-bindings
```

Check that git matches a clean hermetic regen:

```bash
nix run .#check-python-bindings
```

The flake pins Groovy **4.0.30** and Apache Commons jars to the same
versions/hashes as the legacy CMake generator path. SWIG comes from the
flake’s nixpkgs pin (currently 4.x). After changing generator inputs, commit
the updated files in this directory.

## CMake behaviour

With these files present, `xbmc/interfaces/swig/CMakeLists.txt` compiles them
directly and does **not** require Java, Groovy, or SWIG.

Force the classic in-tree generator (needs JRE + SWIG):

```bash
cmake -DENABLE_GENERATE_PYTHON_BINDINGS=ON ...
```

## When to regenerate

Re-run the updater after changing any of:

- `xbmc/interfaces/swig/*.i`
- Headers `%include`d by those interfaces (`xbmc/interfaces/legacy/**`, etc.)
- `xbmc/interfaces/python/PythonSwig.cpp.template`
- `xbmc/interfaces/python/typemaps/*`
- `xbmc/interfaces/python/*.groovy`
- `tools/codegenerator/*.groovy`
