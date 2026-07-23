#!/usr/bin/env bash
# Build Fritzing from source on macOS (Monterey 12+ / Apple Silicon or Intel).
#
# Pinned to the 'develop' branch of fritzing-app (Qt 6.5.x era).
# Last confirmed working: develop @ Oct 2025, Qt 6.5.3.
#
# ngspice (circuit simulator) is OPTIONAL — Fritzing runs without it;
# pass --with-ngspice to build and bundle it.
set -euo pipefail

# ── Options ───────────────────────────────────────────────────────────────────
WITH_NGSPICE=false
for arg in "$@"; do
    [[ "$arg" == "--with-ngspice" ]] && WITH_NGSPICE=true
done

# ── Pinned versions ───────────────────────────────────────────────────────────
FRITZING_BRANCH="develop"
QT_VERSION="6.5.3"
BOOST_VERSION="1_84_0"
LIBGIT2_VERSION="1.7.1"
QUAZIP_VERSION="1.4"
SVGPP_VERSION="1.3.1"
CLIPPER1_VERSION="6.4.2"
NGSPICE_VERSION="41"

JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

# ── Paths (all siblings of this repo's parent) ────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
FRITZING_APP="$WORKSPACE/fritzing-app"
QT_ROOT="$WORKSPACE/Qt/${QT_VERSION}/macos"

# ── Helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[build] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
step() {
    echo
    echo "════════════════════════════════════════════════════════"
    echo "  $*"
    echo "════════════════════════════════════════════════════════"
}

# Safe download: fetch URL to destination file, abort on failure.
# Usage: fetch <url> <dest_file>
fetch() {
    local url="$1" dest="$2"
    curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" \
        || die "Download failed: $url"
}

# ── 1. Xcode Command Line Tools ───────────────────────────────────────────────
step "Checking prerequisites"

if ! xcode-select -p &>/dev/null; then
    xcode-select --install
    echo
    echo "Xcode Command Line Tools installation started."
    echo "Re-run this script after it completes."
    exit 0
fi
log "Xcode CLT: $(xcode-select -p)"

# ── 2. Homebrew ───────────────────────────────────────────────────────────────
if ! command -v brew &>/dev/null; then
    log "Installing Homebrew…"
    fetch https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh /tmp/brew_install.sh
    bash /tmp/brew_install.sh
    rm /tmp/brew_install.sh
fi
# Apple Silicon: add brew to PATH if not already there
if [[ -x /opt/homebrew/bin/brew ]] && ! command -v brew &>/dev/null; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
fi

log "Installing required Homebrew packages…"
BREW_PKGS=(cmake git python3 autoconf automake libtool pkg-config unzip)
for pkg in "${BREW_PKGS[@]}"; do
    brew list "$pkg" &>/dev/null || brew install "$pkg"
done

# ── 3. Qt 6.5.3 via aqtinstall ───────────────────────────────────────────────
step "Qt ${QT_VERSION}"

if [[ ! -x "$QT_ROOT/bin/qmake" ]]; then
    log "Installing Qt ${QT_VERSION} with aqtinstall…"
    # Use a venv to avoid touching the system Python environment
    VENV="$WORKSPACE/.venv-aqt"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet aqtinstall
    mkdir -p "$WORKSPACE/Qt"
    "$VENV/bin/python" -m aqt install-qt mac desktop "${QT_VERSION}" clang_64 \
        --outputdir "$WORKSPACE/Qt" \
        -m qt5compat qtimageformats qtserialport
else
    log "Qt ${QT_VERSION} already present"
fi

QMAKE="$QT_ROOT/bin/qmake"
[[ -x "$QMAKE" ]] || die "qmake not found at $QMAKE"
log "qmake: $("$QMAKE" --version | tail -1)"

# ── 4. fritzing-app (pinned branch) ──────────────────────────────────────────
step "fritzing-app (branch: ${FRITZING_BRANCH})"

if [[ ! -d "$FRITZING_APP" ]]; then
    git clone --depth 1 --branch "$FRITZING_BRANCH" \
        https://github.com/fritzing/fritzing-app.git "$FRITZING_APP"
else
    git -C "$FRITZING_APP" pull --ff-only
fi
log "HEAD: $(git -C "$FRITZING_APP" log -1 --format='%h %ai %s')"

# ── 5. Boost (headers only) ───────────────────────────────────────────────────
step "Boost ${BOOST_VERSION} (headers only)"

BOOST_DIR="$WORKSPACE/boost_${BOOST_VERSION}"
if [[ ! -d "$BOOST_DIR/boost" ]]; then
    DOT_VER="$(echo "$BOOST_VERSION" | tr _ .)"
    BOOST_ARCHIVE="/tmp/boost_${BOOST_VERSION}.tar.gz"
    fetch "https://archives.boost.io/release/${DOT_VER}/source/boost_${BOOST_VERSION}.tar.gz" \
        "$BOOST_ARCHIVE"
    tar -xzf "$BOOST_ARCHIVE" -C "$WORKSPACE"
    rm "$BOOST_ARCHIVE"
    log "Boost extracted to $BOOST_DIR"
else
    log "Boost already present"
fi

# ── 6. libgit2 (static) ───────────────────────────────────────────────────────
step "libgit2 ${LIBGIT2_VERSION}"

LIBGIT2_DIR="$WORKSPACE/libgit2-${LIBGIT2_VERSION}"
if [[ ! -f "$LIBGIT2_DIR/lib/libgit2.a" ]]; then
    [[ -d "$LIBGIT2_DIR" ]] || \
        git clone --depth 1 --branch "v${LIBGIT2_VERSION}" \
            https://github.com/libgit2/libgit2.git "$LIBGIT2_DIR"

    cmake -S "$LIBGIT2_DIR" -B "$LIBGIT2_DIR/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$LIBGIT2_DIR" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_TESTS=OFF \
        -DBUILD_CLI=OFF \
        -DUSE_SSH=OFF
    cmake --build "$LIBGIT2_DIR/build" --parallel "$JOBS"
    cmake --install "$LIBGIT2_DIR/build"
    log "libgit2 installed"
else
    log "libgit2 already built"
fi

# ── 7. svgpp (headers only) ───────────────────────────────────────────────────
step "svgpp ${SVGPP_VERSION} (headers only)"

SVGPP_DIR="$WORKSPACE/svgpp-${SVGPP_VERSION}"
if [[ ! -d "$SVGPP_DIR/include" ]]; then
    git clone --depth 1 --branch "v${SVGPP_VERSION}" \
        https://github.com/svgpp/svgpp.git "$SVGPP_DIR"
    log "svgpp cloned"
else
    log "svgpp already present"
fi

# ── 8. Clipper1 6.4.2 ────────────────────────────────────────────────────────
# Clipper1 is header+source only (no CMake in v6); fritzing-app compiles
# the two .cpp files directly.  We just need them at the expected path.
step "Clipper1 ${CLIPPER1_VERSION}"

CLIPPER1_DIR="$WORKSPACE/Clipper1/${CLIPPER1_VERSION}"
if [[ ! -f "$CLIPPER1_DIR/cpp/clipper.hpp" ]]; then
    mkdir -p "$WORKSPACE/Clipper1"
    CLIPPER1_ZIP="/tmp/clipper_${CLIPPER1_VERSION}.zip"
    fetch \
        "https://sourceforge.net/projects/polyclipping/files/Clipper6/${CLIPPER1_VERSION}/clipper_${CLIPPER1_VERSION}.zip/download" \
        "$CLIPPER1_ZIP"
    TMP_CLIP="/tmp/clipper_extract_$$"
    mkdir -p "$TMP_CLIP"
    unzip -q "$CLIPPER1_ZIP" -d "$TMP_CLIP"
    # The zip extracts to its own subdirectory or flat — find cpp/clipper.hpp
    CLIP_SRC="$(find "$TMP_CLIP" -name 'clipper.hpp' -exec dirname {} \; | head -1)"
    [[ -n "$CLIP_SRC" ]] || die "clipper.hpp not found inside downloaded zip"
    mkdir -p "$CLIPPER1_DIR/cpp"
    cp "$CLIP_SRC"/clipper.{hpp,cpp} "$CLIPPER1_DIR/cpp/"
    rm -rf "$TMP_CLIP" "$CLIPPER1_ZIP"
    log "Clipper1 sources at $CLIPPER1_DIR"
else
    log "Clipper1 already present"
fi

# ── 9. QuaZip 1.4 ────────────────────────────────────────────────────────────
step "QuaZip ${QUAZIP_VERSION} for Qt ${QT_VERSION}"

QUAZIP_DIR="$WORKSPACE/quazip-${QT_VERSION}-${QUAZIP_VERSION}"
if [[ ! -d "$QUAZIP_DIR/lib" ]]; then
    QUAZIP_SRC="$WORKSPACE/quazip-src"
    [[ -d "$QUAZIP_SRC" ]] || \
        git clone --depth 1 --branch "v${QUAZIP_VERSION}" \
            https://github.com/stachenov/quazip.git "$QUAZIP_SRC"

    cmake -S "$QUAZIP_SRC" -B "$QUAZIP_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_PREFIX_PATH="$QT_ROOT" \
        -DCMAKE_INSTALL_PREFIX="$QUAZIP_DIR" \
        -DQUAZIP_QT_MAJOR_VERSION=6
    cmake --build "$QUAZIP_SRC/build" --parallel "$JOBS"
    cmake --install "$QUAZIP_SRC/build"
    log "QuaZip installed to $QUAZIP_DIR"
else
    log "QuaZip already built"
fi

# ── 10. ngspice (optional) ────────────────────────────────────────────────────
NGSPICE_INSTALL="$WORKSPACE/ngspice"

if $WITH_NGSPICE; then
    step "ngspice ${NGSPICE_VERSION} (circuit simulator)"

    if [[ ! -f "$NGSPICE_INSTALL/lib/libngspice.dylib" ]]; then
        NGSPICE_SRC="$WORKSPACE/ngspice-src"
        if [[ ! -d "$NGSPICE_SRC" ]]; then
            NGSPICE_TAR="/tmp/ngspice-${NGSPICE_VERSION}.tar.gz"
            fetch \
                "https://sourceforge.net/projects/ngspice/files/ng-spice-rework/${NGSPICE_VERSION}/ngspice-${NGSPICE_VERSION}.tar.gz/download" \
                "$NGSPICE_TAR"
            mkdir -p "$NGSPICE_SRC"
            tar -xzf "$NGSPICE_TAR" --strip-components=1 -C "$NGSPICE_SRC"
            rm "$NGSPICE_TAR"
        fi

        mkdir -p "$NGSPICE_SRC/release"
        (
            cd "$NGSPICE_SRC/release"
            ../configure \
                --prefix="$NGSPICE_INSTALL" \
                --with-ngshared \
                --disable-debug \
                --enable-openmp \
                CFLAGS="-O2"
            make -j"$JOBS"
            make install
        )
        log "ngspice installed to $NGSPICE_INSTALL"
    else
        log "ngspice already built"
    fi
else
    step "ngspice — skipped (pass --with-ngspice to enable circuit simulation)"
fi

# ── 11. Build Fritzing ────────────────────────────────────────────────────────
step "Building Fritzing"

FRITZING_BUILD="$WORKSPACE/fritzing-build"
mkdir -p "$FRITZING_BUILD"

(
    export PATH="$QT_ROOT/bin:$PATH"
    cd "$FRITZING_BUILD"
    "$QMAKE" \
        -spec macx-clang \
        "boost_root=$WORKSPACE/boost_${BOOST_VERSION}" \
        "$FRITZING_APP/phoenix.pro"
    make -j"$JOBS"
)

APP_BUNDLE="$(find "$FRITZING_BUILD" -name 'Fritzing.app' -maxdepth 3 | head -1)"
[[ -n "$APP_BUNDLE" ]] || die "Build succeeded but Fritzing.app not found under $FRITZING_BUILD"

# ── 12. Deploy Qt frameworks ──────────────────────────────────────────────────
step "Running macdeployqt"
"$QT_ROOT/bin/macdeployqt" "$APP_BUNDLE" -verbose=1

if $WITH_NGSPICE; then
    NGSPICE_LIB="$(find "$NGSPICE_INSTALL/lib" -name 'libngspice*.dylib' | head -1)"
    if [[ -n "$NGSPICE_LIB" ]]; then
        cp "$NGSPICE_LIB" "$APP_BUNDLE/Contents/MacOS/"
        log "ngspice dylib bundled"
    fi
fi

echo
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Build complete!                                         ║"
printf "║  App: %-51s║\n" "$APP_BUNDLE"
echo "╚══════════════════════════════════════════════════════════╝"
echo
echo "  open \"$APP_BUNDLE\""
