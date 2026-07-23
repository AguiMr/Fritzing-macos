# Vendored dependency: Clipper1 (polyclipping) 6.4.2

Fritzing 1.0.7 pins **Clipper1 version 6.4.2**, which is only officially
distributed via SourceForge. Because SourceForge git/downloads are unreachable
on some networks (and to avoid fetching build-time code from third parties),
the C++ source is vendored here so the build uses a local, reviewable copy.

## What this is

The original, **unmodified** upstream Clipper 6.4.2 C++ library by Angus Johnson:

- `cpp/clipper.hpp`  — original header (`struct IntPoint { cInt X, Y; }`, no Eigen/TBB)
- `cpp/clipper.cpp`  — original implementation
- `cpp/CMakeLists.txt` — upstream CMake that installs `libpolyclipping` and
  headers to `include/polyclipping/` (exactly what `pri/clipper1detect.pri` expects)
- `cpp/polyclipping.pc.cmakein` — upstream pkg-config template

Header banner confirms: `Version : 6.4.2`, `Date : 27 February 2017`.

## Source

Fetched from the GitHub mirror
[`bimpp/polyclipping`](https://github.com/bimpp/polyclipping) (`cpp/` directory),
which mirrors the SourceForge release verbatim. Verified against the original by
checking the version banner, the original `IntPoint` struct, and the absence of
any downstream modifications (no `Eigen`, `tbb`, or `scalable_allocator`
references — unlike, e.g., the PrusaSlicer fork).

## Integrity (SHA-256)

```
734eba9dc9d399089b2b467017074bd24728a1b9e64c7429e827806ed10e54cc  cpp/clipper.hpp
5c642a3668311701f72572443aa42c1a981edb037298efc015166d9d90be0755  cpp/clipper.cpp
a911abbf27918aabe8702d5aea041783ac92ee6313f7700052ba5e5f629ea49d  cpp/CMakeLists.txt
bd72af8190c3157f2b29ea0b473ae5db72df21b829f2f88294604e4f971adea6  cpp/polyclipping.pc.cmakein
```

Verify locally with:

```bash
shasum -a 256 -c <<'EOF'
734eba9dc9d399089b2b467017074bd24728a1b9e64c7429e827806ed10e54cc  cpp/clipper.hpp
5c642a3668311701f72572443aa42c1a981edb037298efc015166d9d90be0755  cpp/clipper.cpp
EOF
```

## License

Clipper is released under the **Boost Software License 1.0** (permissive;
redistribution allowed). See the license header at the top of `clipper.hpp`.
