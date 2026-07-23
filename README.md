# Build Fritzing 1.0.7 on macOS

Fritzing only ships prebuilt binaries behind a paid download, so this repo
builds **Fritzing 1.0.7** from source. One script handles everything; every
dependency comes from a **first-party or official source**, or is vendored and
checksummed in this repo. **Nothing is fetched from SourceForge.**

## Usage

```bash
git clone https://github.com/AguiMr/Fritzing-macos.git
cd Fritzing-macos
chmod +x build_fritzing_macos.sh
./build_fritzing_macos.sh
```

Requires [Homebrew](https://brew.sh) and Xcode Command Line Tools (the script
triggers the CLT install and asks you to re-run if they're missing). Runs on
Intel and Apple Silicon. Build takes ~20–40 min the first time; re-running
skips anything already built.

When it finishes:

```bash
open "$(find .. -name Fritzing.app | head -1)"
```

## Dependencies and where each comes from

| Dependency | Version | Source |
|------------|---------|--------|
| Qt | 6.5.3 | official Qt servers via `aqtinstall` (isolated venv) |
| fritzing-app | tag **1.0.7** | github.com/fritzing/fritzing-app |
| Boost (headers) | 1.84 | archives.boost.io (official) |
| libgit2 (static) | 1.7.1 | github.com/libgit2 |
| svgpp (headers) | 1.3.1 | github.com/svgpp |
| QuaZip | 1.4 | github.com/stachenov/quazip |
| **Clipper1** | **6.4.2** | **vendored in [`deps/`](deps/polyclipping-6.4.2/)** — verified original, see [PROVENANCE.md](deps/polyclipping-6.4.2/PROVENANCE.md) |
| ngspice | 42 | github.com/imr/ngspice (official maintainers' mirror) |

### Why Clipper1 is vendored

Fritzing 1.0.7 pins Clipper1 6.4.2, which upstream distributes **only** via
SourceForge — unreachable on many networks. Rather than fetch build-time code
from an arbitrary third party, the original unmodified 6.4.2 source is committed
here with recorded SHA-256 checksums so you can review exactly what compiles.
See [`deps/polyclipping-6.4.2/PROVENANCE.md`](deps/polyclipping-6.4.2/PROVENANCE.md).

## Directory layout

The script installs dependencies as **siblings of `fritzing-app/`**, which is
what Fritzing's `pri/*detect.pri` scripts expect:

```
<parent>/
├── Fritzing-macos/            ← this repo (script + vendored Clipper)
├── fritzing-app/              ← cloned at tag 1.0.7
├── fritzing-build/            ← qmake/make output → Fritzing.app
├── Qt/6.5.3/macos/
├── boost_1_84_0/
├── libgit2-1.7.1/
├── svgpp-1.3.1/
├── quazip-6.5.3-1.4/
├── Clipper1-6.4.2/            ← built from deps/polyclipping-6.4.2
└── ngspice-42/
```

## Troubleshooting

- **Xcode CLT dialog appears, script exits** — let it finish, then re-run.
- **`qmake` Qt-version error** — 1.0.7 requires Qt 6.5.3–6.10.10; the script
  installs 6.5.3 into the `Qt/` sibling dir and uses that one specifically.
- **`ngspice not found`** — the build needs `ngspice-42/` present (its headers).
  Re-run so step 9 completes; simulation at runtime uses the bundled
  `libngspice.dylib`.
- **Apple Silicon** — Qt is installed as `clang_64` and the app runs natively
  or via Rosetta. To force an Intel build if you hit an arch mismatch, add
  `CONFIG+=x86_64` to the `qmake` line in the script.

## License note

Fritzing is GPLv3. Clipper (vendored) is Boost Software License 1.0. This repo
only contains build tooling plus the vendored Clipper source; it does not
redistribute Fritzing itself.
