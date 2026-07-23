# Fritzing on macOS

The fastest, safest way to run [Fritzing](https://fritzing.org) on macOS is to
install the **official prebuilt app** — not to build from source. Building is
only worth it if you intend to modify Fritzing itself.

## Recommended: install the prebuilt app

**Option A — Homebrew (recommended).** The cask downloads the official release
and verifies its SHA-256 checksum, so nothing unverified is installed:

```bash
brew install --cask fritzing
```

Launch it from Applications or with `open -a Fritzing`.

**Option B — Official site.** Download the `.dmg` directly from the first-party
source, [fritzing.org/download](https://fritzing.org/download) (pay-what-you-want),
then drag Fritzing into Applications.

Both are Apple-notarized and run on Intel and Apple Silicon.

---

## Advanced: building from source

> ⚠️ **Only if you want to modify Fritzing.** The build pulls a specific pinned
> set of dependencies, one of which (Clipper1 6.4.2) is only distributed via
> SourceForge and may be unreachable on some networks. Prefer the prebuilt app
> above unless you have a reason to compile.

```bash
git clone https://github.com/AguiMr/Fritzing-macos.git
cd Fritzing-macos
chmod +x build_fritzing_macos.sh
./build_fritzing_macos.sh
```

To also build the circuit simulator (ngspice), add the flag:

```bash
./build_fritzing_macos.sh --with-ngspice
```

Re-run after the first run if Xcode CLT prompts an install dialog — the script exits early and resumes cleanly on the next run.

---

## What the Script Does

| Step | Action |
|------|--------|
| 1 | Verifies / installs **Xcode Command Line Tools** |
| 2 | Installs **Homebrew** packages (`cmake`, `git`, `python3`, etc.) |
| 3 | Installs **Qt 6.5.3** via `aqtinstall` in a venv (no Qt account needed) |
| 4 | Clones **fritzing-app** pinned to the `develop` branch |
| 5 | Downloads **Boost 1.84** headers |
| 6 | Clones and builds **libgit2 1.7.1** (static) |
| 7 | Clones **svgpp 1.3.1** (header-only) |
| 8 | Downloads **Clipper1 6.4.2** headers from SourceForge |
| 9 | Clones and builds **QuaZip 1.4** against Qt 6.5.3 |
| 10 | *(optional)* Builds **ngspice 41** — pass `--with-ngspice` to enable |
| 11 | Runs `qmake` + `make` to build **Fritzing** |
| 12 | Runs `macdeployqt` to bundle Qt frameworks into a self-contained `.app` |

---

## System Requirements

| Requirement | Version |
|-------------|---------|
| macOS | 12 Monterey or later |
| Xcode CLT | Latest (via `xcode-select --install`) |
| Homebrew | Any current version |
| Disk space | ~10 GB (sources + build artifacts) |
| RAM | 8 GB minimum, 16 GB recommended |

---

## Directory Layout

The script creates the following structure **next to** the cloned repo:

```
~/projects/                       ← wherever you cloned Fritzing-macos
├── Fritzing-macos/               ← this repo
│   └── build_fritzing_macos.sh
├── fritzing-app/                 ← cloned by the script
├── fritzing-build/               ← qmake build output
├── Qt/6.5.3/macos/              ← Qt installed by aqtinstall
├── boost_1_84_0/                 ← Boost headers
├── libgit2-1.7.1/                ← libgit2 source + static lib
├── svgpp-1.3.1/                  ← svgpp headers
├── Clipper1/6.4.2/               ← Clipper1 source + lib
├── quazip-6.5.3-1.4/            ← QuaZip built against Qt 6.5.3
└── ngspice/                      ← ngspice shared library
```

> **Note:** Fritzing's `.pro` file expects dependencies to be siblings of `fritzing-app/`.  
> This script handles all of that automatically.

---

## Troubleshooting

### `xcode-select --install` opens a dialog but script exits
Re-run the script after the installation completes. It will pick up where it left off.

### Qt version mismatch error during qmake
Fritzing requires **Qt 6.5.3 – 6.5.10** exactly. If you already have a different Qt installed, the script will install 6.5.3 via aqtinstall in the `Qt/` sibling directory and use that.

### `libgit2` build fails with OpenSSL error
Install OpenSSL: `brew install openssl` then re-run.

### ngspice `./configure` fails
Ensure autotools are installed: `brew install autoconf automake libtool`. Then re-run.

### `macdeployqt` fails or app crashes on launch
Make sure you're running macdeployqt from the same Qt installation used to build (`$WORKSPACE/Qt/6.5.3/macos/bin/macdeployqt`). The script does this automatically.

### Apple Silicon (M1/M2/M3)
The script targets `x86_64` (matches aqtinstall's `clang_64`). On Apple Silicon, this runs via Rosetta 2. To build a native arm64 binary, change `CONFIG+=x86_64` to `CONFIG+=arm64` in the script and install `aqt install-qt mac desktop 6.5.3 clang_64` — note that the universal/arm64 Qt 6.5.x binaries are available as `clang_64` from aqt on Apple Silicon.

---

## Manual Build Steps

If you prefer to run steps manually, install the dependencies above, then:

```bash
cd /path/to/fritzing-build
/path/to/Qt/6.5.3/macos/bin/qmake \
    -spec macx-clang \
    CONFIG+=x86_64 \
    "boost_root=/path/to/boost_1_84_0" \
    /path/to/fritzing-app/phoenix.pro

make -j$(sysctl -n hw.logicalcpu)
```

---

## References

- [Fritzing Build Wiki](https://github.com/fritzing/fritzing-app/wiki/1.-Building-Fritzing)
- [Mac-specific Notes](https://github.com/fritzing/fritzing-app/wiki/1.1-Mac-notes)
- [fritzing-app repository](https://github.com/fritzing/fritzing-app)
- [aqtinstall (Qt offline installer)](https://github.com/miurahr/aqtinstall)
