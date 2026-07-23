#!/usr/bin/env bash
# Build script for Fritzing on macOS
# Tested target: macOS 12+ (Monterey, Ventura, Sonoma)
# Qt version: 6.5.3 (strict requirement by fritzing-app)
set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
QT_VERSION="6.5.3"
BOOST_VERSION="1_84_0"         # any supported version 1_55_0..1_85_0 (not 1_54_0)
LIBGIT2_VERSION="1.7.1"
QUAZIP_VERSION="1.4"
SVGPP_VERSION="1.3.1"
CLIPPER1_VERSION="6.4.2"
NGSPICE_VERSION="41"

# Number of parallel make jobs
JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"   # parent of this repo
FRITZING_APP="$WORKSPACE/fritzing-app"
QT_ROOT="$WORKSPACE/Qt/${QT_VERSION}/macos"

log()  { echo "[build] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
step() { echo; echo "════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════"; }

# ── 1. Prerequisites ──────────────────────────────────────────────────────────
step "Checking prerequisites"

# Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    log "Installing Xcode Command Line Tools…"
    xcode-select --install
    echo "Please re-run this script after the Xcode CLT installation finishes."
    exit 0
fi

# Homebrew
if ! command -v brew &>/dev/null; then
    log "Installing Homebrew…"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for Apple Silicon
    [[ -f /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
fi

log "Installing Homebrew packages…"
brew install cmake git python3 autoconf automake libtool pkg-config wget || true

# ── 2. Install Qt 6.5.3 via aqtinstall ───────────────────────────────────────
step "Installing Qt ${QT_VERSION}"

if [[ ! -d "$QT_ROOT" ]]; then
    log "Qt ${QT_VERSION} not found at $QT_ROOT — installing with aqtinstall"
    pip3 install aqtinstall --quiet --break-system-packages 2>/dev/null || pip3 install aqtinstall --quiet
    mkdir -p "$WORKSPACE/Qt"
    # aqt installs to: <base>/<version>/macos (for mac desktop)
    python3 -m aqt install-qt mac desktop "${QT_VERSION}" clang_64 \
        --outputdir "$WORKSPACE/Qt" \
        -m qt5compat qtimageformats qtserialport qtsvg
    # aqt uses "macos" as the arch subfolder for Qt 6
    log "Qt installed at $WORKSPACE/Qt/${QT_VERSION}/macos"
else
    log "Qt ${QT_VERSION} already present at $QT_ROOT"
fi

QMAKE="$QT_ROOT/bin/qmake"
[[ -x "$QMAKE" ]] || die "qmake not found at $QMAKE"
log "Using qmake: $QMAKE  ($(${QMAKE} --version | tail -1))"

# ── 3. Clone fritzing-app ─────────────────────────────────────────────────────
step "Cloning fritzing-app"
if [[ ! -d "$FRITZING_APP" ]]; then
    git clone --depth 1 https://github.com/fritzing/fritzing-app.git "$FRITZING_APP"
else
    log "fritzing-app already cloned — pulling latest"
    git -C "$FRITZING_APP" pull
fi

# ── 4. Boost (header-only) ────────────────────────────────────────────────────
step "Fetching Boost ${BOOST_VERSION}"
BOOST_DIR="$WORKSPACE/boost_${BOOST_VERSION}"
BOOST_ARCHIVE="boost_${BOOST_VERSION}.tar.gz"
BOOST_URL="https://archives.boost.io/release/$(echo "$BOOST_VERSION" | tr _ .)/source/${BOOST_ARCHIVE}"

if [[ ! -d "$BOOST_DIR" ]]; then
    log "Downloading Boost…"
    cd "$WORKSPACE"
    wget -q --show-progress "$BOOST_URL" -O "$BOOST_ARCHIVE"
    tar -xzf "$BOOST_ARCHIVE"
    rm "$BOOST_ARCHIVE"
    log "Boost extracted to $BOOST_DIR"
else
    log "Boost already present at $BOOST_DIR"
fi

# ── 5. libgit2 ────────────────────────────────────────────────────────────────
step "Building libgit2 ${LIBGIT2_VERSION}"
LIBGIT2_SRC="$WORKSPACE/libgit2-${LIBGIT2_VERSION}"
LIBGIT2_BUILD="$LIBGIT2_SRC/build"

if [[ ! -d "$LIBGIT2_SRC" ]]; then
    git clone --depth 1 --branch "v${LIBGIT2_VERSION}" \
        https://github.com/libgit2/libgit2.git "$LIBGIT2_SRC"
fi

if [[ ! -f "$LIBGIT2_SRC/lib/libgit2.a" ]]; then
    mkdir -p "$LIBGIT2_BUILD"
    cmake -S "$LIBGIT2_SRC" -B "$LIBGIT2_BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$LIBGIT2_SRC" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_CLI=OFF \
        -DUSE_SSH=OFF
    cmake --build "$LIBGIT2_BUILD" --parallel "$JOBS"
    cmake --install "$LIBGIT2_BUILD"
    log "libgit2 installed to $LIBGIT2_SRC"
else
    log "libgit2 already built"
fi

# ── 6. svgpp (header-only) ────────────────────────────────────────────────────
step "Fetching svgpp ${SVGPP_VERSION}"
SVGPP_DIR="$WORKSPACE/svgpp-${SVGPP_VERSION}"
if [[ ! -d "$SVGPP_DIR" ]]; then
    git clone --depth 1 --branch "v${SVGPP_VERSION}" \
        https://github.com/svgpp/svgpp.git "$SVGPP_DIR"
else
    log "svgpp already present"
fi

# ── 7. Clipper1 ───────────────────────────────────────────────────────────────
step "Building Clipper1 ${CLIPPER1_VERSION}"
CLIPPER1_DIR="$WORKSPACE/Clipper1/${CLIPPER1_VERSION}"
CLIPPER1_SRC="$WORKSPACE/Clipper1-src"
CLIPPER1_BUILD="$CLIPPER1_SRC/build"

if [[ ! -d "$CLIPPER1_SRC" ]]; then
    git clone --depth 1 https://github.com/AngusJohnson/Clipper2.git "$CLIPPER1_SRC" || true
    # Clipper1 is distributed as source via SourceForge; use the Fritzing-bundled version
    git clone --depth 1 https://git.code.sf.net/p/polyclipping/code "$CLIPPER1_SRC" 2>/dev/null || \
    git clone --depth 1 https://github.com/fritzing/fritzing-app.git /tmp/fa-tmp 2>/dev/null || true
fi

if [[ ! -d "$CLIPPER1_DIR" ]]; then
    mkdir -p "$CLIPPER1_DIR"
    # Try SourceForge mirror
    CLIPPER1_TARBALL="clipper_${CLIPPER1_VERSION}.zip"
    CLIPPER1_URL="https://sourceforge.net/projects/polyclipping/files/Clipper6/${CLIPPER1_VERSION}/${CLIPPER1_TARBALL}/download"
    log "Downloading Clipper1 ${CLIPPER1_VERSION}…"
    wget -q --show-progress "$CLIPPER1_URL" -O "/tmp/${CLIPPER1_TARBALL}" || \
        die "Could not download Clipper1. Download manually from https://sourceforge.net/projects/polyclipping/ and extract to $CLIPPER1_DIR"
    TMP_CLIP="$WORKSPACE/clipper_tmp"
    mkdir -p "$TMP_CLIP"
    unzip -q "/tmp/${CLIPPER1_TARBALL}" -d "$TMP_CLIP"
    # The zip contains cpp/ and cs/ subdirs; we want the C++ source
    mkdir -p "$WORKSPACE/Clipper1"
    mv "$TMP_CLIP" "$CLIPPER1_DIR"
    rm -f "/tmp/${CLIPPER1_TARBALL}"

    # Build shared library
    cd "$CLIPPER1_DIR"
    if [[ -f "cpp/CMakeLists.txt" ]]; then
        cmake -S cpp -B build \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$CLIPPER1_DIR"
        cmake --build build --parallel "$JOBS"
        cmake --install build
    fi
    cd "$WORKSPACE"
else
    log "Clipper1 already present at $CLIPPER1_DIR"
fi

# ── 8. QuaZip ─────────────────────────────────────────────────────────────────
step "Building QuaZip ${QUAZIP_VERSION} for Qt ${QT_VERSION}"
QUAZIP_DIR="$WORKSPACE/quazip-${QT_VERSION}-${QUAZIP_VERSION}"
QUAZIP_SRC="$WORKSPACE/quazip-src"

if [[ ! -d "$QUAZIP_SRC" ]]; then
    git clone --depth 1 --branch "v${QUAZIP_VERSION}" \
        https://github.com/stachenov/quazip.git "$QUAZIP_SRC"
fi

if [[ ! -d "$QUAZIP_DIR/lib" ]]; then
    QUAZIP_BUILD="$QUAZIP_SRC/build"
    mkdir -p "$QUAZIP_BUILD"
    cmake -S "$QUAZIP_SRC" -B "$QUAZIP_BUILD" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$QT_ROOT" \
        -DCMAKE_INSTALL_PREFIX="$QUAZIP_DIR" \
        -DQUAZIP_QT_MAJOR_VERSION=6
    cmake --build "$QUAZIP_BUILD" --parallel "$JOBS"
    cmake --install "$QUAZIP_BUILD"
    log "QuaZip installed to $QUAZIP_DIR"
else
    log "QuaZip already built at $QUAZIP_DIR"
fi

# ── 9. ngspice ────────────────────────────────────────────────────────────────
step "Building ngspice ${NGSPICE_VERSION}"
NGSPICE_INSTALL="$WORKSPACE/ngspice"
NGSPICE_SRC="$WORKSPACE/ngspice-src"

if [[ ! -f "$NGSPICE_INSTALL/lib/libngspice.dylib" ]]; then
    if [[ ! -d "$NGSPICE_SRC" ]]; then
        git clone --depth 1 --branch "ngspice-${NGSPICE_VERSION}" \
            https://git.code.sf.net/p/ngspice/ngspice "$NGSPICE_SRC" 2>/dev/null || \
        wget -q "https://sourceforge.net/projects/ngspice/files/ng-spice-rework/${NGSPICE_VERSION}/ngspice-${NGSPICE_VERSION}.tar.gz/download" \
            -O "/tmp/ngspice-${NGSPICE_VERSION}.tar.gz" && \
        tar -xzf "/tmp/ngspice-${NGSPICE_VERSION}.tar.gz" -C "$WORKSPACE" && \
        mv "$WORKSPACE/ngspice-${NGSPICE_VERSION}" "$NGSPICE_SRC"
    fi

    cd "$NGSPICE_SRC"
    mkdir -p release
    cd release
    ../configure \
        --prefix="$NGSPICE_INSTALL" \
        --with-ngshared \
        --disable-debug \
        --enable-openmp \
        CFLAGS="-O2"
    make -j"$JOBS"
    make install
    cd "$WORKSPACE"
    log "ngspice installed to $NGSPICE_INSTALL"
else
    log "ngspice already built at $NGSPICE_INSTALL"
fi

# ── 10. Build Fritzing ────────────────────────────────────────────────────────
step "Building Fritzing"
FRITZING_BUILD="$WORKSPACE/fritzing-build"
mkdir -p "$FRITZING_BUILD"

export PATH="$QT_ROOT/bin:$PATH"

cd "$FRITZING_BUILD"
"$QMAKE" \
    -spec macx-clang \
    CONFIG+=x86_64 \
    "boost_root=$WORKSPACE/boost_${BOOST_VERSION}" \
    "$FRITZING_APP/phoenix.pro"

make -j"$JOBS"

log "Fritzing built successfully!"
APP_BUNDLE="$(find "$FRITZING_BUILD" -name 'Fritzing.app' | head -1)"

if [[ -n "$APP_BUNDLE" ]]; then
    step "Deploying Qt frameworks into app bundle"
    "$QT_ROOT/bin/macdeployqt" "$APP_BUNDLE" -verbose=1

    # Copy ngspice shared library next to the executable
    NGSPICE_LIB="$(find "$NGSPICE_INSTALL/lib" -name 'libngspice*.dylib' | head -1)"
    if [[ -n "$NGSPICE_LIB" ]]; then
        cp "$NGSPICE_LIB" "$APP_BUNDLE/Contents/MacOS/"
        log "Copied ngspice dylib into bundle"
    fi

    echo
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║  Build complete!                                     ║"
    echo "║                                                      ║"
    printf "║  App: %-47s║\n" "$APP_BUNDLE"
    echo "╚══════════════════════════════════════════════════════╝"
    echo
    echo "To open Fritzing:"
    echo "  open \"$APP_BUNDLE\""
else
    die "Build succeeded but Fritzing.app not found under $FRITZING_BUILD"
fi
