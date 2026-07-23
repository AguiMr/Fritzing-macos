#!/usr/bin/env bash
# Build Fritzing 1.0.7 from source on macOS (Intel or Apple Silicon).
#
# Every dependency comes from a first-party or official-mirror source, or is
# vendored+checksummed in this repo (deps/). Nothing is fetched from SourceForge.
#
#   Qt 6.5.3 ....... official Qt servers (aqtinstall)
#   fritzing-app ... github.com/fritzing  (tag 1.0.7)
#   Boost 1.84 ..... archives.boost.io    (official, headers only)
#   libgit2 1.7.1 .. github.com/libgit2   (built static)
#   svgpp 1.3.1 .... github.com/svgpp     (headers only)
#   QuaZip 1.4 ..... github.com/stachenov (built)
#   Clipper1 6.4.2 . vendored in deps/    (verified original, see PROVENANCE.md)
#   ngspice 42 ..... github.com/imr/ngspice (official maintainers' mirror, built)
set -euo pipefail

# ── Pinned versions (must match fritzing-app 1.0.7 pri/*detect.pri) ───────────
FRITZING_REF="1.0.7"
QT_VERSION="6.5.3"          # 1.0.7 accepts 6.5.3 .. 6.10.10; we pin 6.5.3
BOOST_VERSION="1_84_0"
LIBGIT2_VERSION="1.7.1"
QUAZIP_VERSION="1.4"
SVGPP_VERSION="1.3.1"
CLIPPER1_VERSION="6.4.2"
NGSPICE_VERSION="42"

JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"     # deps are installed as siblings of fritzing-app
FRITZING_APP="$WORKSPACE/fritzing-app"
QT_ROOT="$WORKSPACE/Qt/${QT_VERSION}/macos"
VENDORED_CLIPPER="$SCRIPT_DIR/deps/polyclipping-${CLIPPER1_VERSION}/cpp"

log()  { echo "[build] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }
step() { echo; echo "════════════════════════════════════════════════════════"; echo "  $*"; echo "════════════════════════════════════════════════════════"; }
fetch(){ curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || die "download failed: $1"; }

# ── 1. Toolchain (Xcode CLT + Homebrew packages) ─────────────────────────────
step "Prerequisites"

if ! xcode-select -p &>/dev/null; then
    xcode-select --install
    echo "Xcode Command Line Tools install started — re-run this script when it finishes."
    exit 0
fi
log "Xcode CLT: $(xcode-select -p)"

if ! command -v brew &>/dev/null; then
    [[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
fi
command -v brew &>/dev/null || die "Homebrew is required. Install from https://brew.sh then re-run."

log "Installing build tools via Homebrew…"
for pkg in cmake git python3 autoconf automake libtool pkg-config openssl@3 bison; do
    brew list "$pkg" &>/dev/null || brew install "$pkg"
done

# ── 2. Qt 6.5.3 (official servers via aqtinstall, in an isolated venv) ────────
step "Qt ${QT_VERSION}"
if [[ ! -x "$QT_ROOT/bin/qmake" ]]; then
    VENV="$WORKSPACE/.venv-aqt"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet aqtinstall
    mkdir -p "$WORKSPACE/Qt"
    "$VENV/bin/python" -m aqt install-qt mac desktop "$QT_VERSION" clang_64 \
        --outputdir "$WORKSPACE/Qt" \
        -m qt5compat qtimageformats qtserialport
else
    log "Qt already present"
fi
QMAKE="$QT_ROOT/bin/qmake"
[[ -x "$QMAKE" ]] || die "qmake not found at $QMAKE"
log "qmake: $("$QMAKE" --version | tail -1)"

# ── 3. fritzing-app @ 1.0.7 ──────────────────────────────────────────────────
step "fritzing-app (tag ${FRITZING_REF})"
if [[ ! -d "$FRITZING_APP" ]]; then
    git -c advice.detachedHead=false clone --depth 1 --branch "$FRITZING_REF" \
        https://github.com/fritzing/fritzing-app.git "$FRITZING_APP"
else
    log "fritzing-app already present; ensuring it is at $FRITZING_REF"
    git -C "$FRITZING_APP" fetch --depth 1 origin "refs/tags/$FRITZING_REF:refs/tags/$FRITZING_REF" 2>/dev/null || true
    git -C "$FRITZING_APP" -c advice.detachedHead=false checkout "$FRITZING_REF" 2>/dev/null || true
fi
log "HEAD: $(git -C "$FRITZING_APP" describe --tags --always 2>/dev/null || echo '?')"

# ── 4. Boost 1.84 headers (official) ─────────────────────────────────────────
step "Boost ${BOOST_VERSION} (headers)"
BOOST_DIR="$WORKSPACE/boost_${BOOST_VERSION}"
if [[ ! -d "$BOOST_DIR/boost" ]]; then
    DOT="$(echo "$BOOST_VERSION" | tr _ .)"
    fetch "https://archives.boost.io/release/${DOT}/source/boost_${BOOST_VERSION}.tar.gz" /tmp/boost.tgz
    tar -xzf /tmp/boost.tgz -C "$WORKSPACE"
    rm /tmp/boost.tgz
else
    log "Boost already present"
fi

# ── 5. libgit2 1.7.1 (static) ────────────────────────────────────────────────
step "libgit2 ${LIBGIT2_VERSION} (static)"
LIBGIT2_DIR="$WORKSPACE/libgit2-${LIBGIT2_VERSION}"
if [[ ! -f "$LIBGIT2_DIR/lib/libgit2.a" ]]; then
    [[ -d "$LIBGIT2_DIR" ]] || git -c advice.detachedHead=false clone --depth 1 \
        --branch "v${LIBGIT2_VERSION}" https://github.com/libgit2/libgit2.git "$LIBGIT2_DIR"
    cmake -S "$LIBGIT2_DIR" -B "$LIBGIT2_DIR/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBGIT2_DIR" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DUSE_SSH=OFF
    cmake --build "$LIBGIT2_DIR/build" --parallel "$JOBS"
    cmake --install "$LIBGIT2_DIR/build"
    # detect expects the archive at libgit2-1.7.1/lib/libgit2.a
    [[ -f "$LIBGIT2_DIR/lib/libgit2.a" ]] || {
        alt="$(find "$LIBGIT2_DIR" -name libgit2.a | head -1)"
        [[ -n "$alt" ]] && { mkdir -p "$LIBGIT2_DIR/lib"; cp "$alt" "$LIBGIT2_DIR/lib/"; }
    }
else
    log "libgit2 already built"
fi

# ── 6. svgpp 1.3.1 (headers) ─────────────────────────────────────────────────
step "svgpp ${SVGPP_VERSION} (headers)"
SVGPP_DIR="$WORKSPACE/svgpp-${SVGPP_VERSION}"
[[ -d "$SVGPP_DIR/include" ]] || git -c advice.detachedHead=false clone --depth 1 \
    --branch "v${SVGPP_VERSION}" https://github.com/svgpp/svgpp.git "$SVGPP_DIR"

# ── 7. QuaZip 1.4 (built against this Qt) ────────────────────────────────────
step "QuaZip ${QUAZIP_VERSION}"
QUAZIP_DIR="$WORKSPACE/quazip-${QT_VERSION}-${QUAZIP_VERSION}"   # dir must match $$QT_VERSION
if [[ ! -d "$QUAZIP_DIR/lib" ]]; then
    QUAZIP_SRC="$WORKSPACE/quazip-src"
    [[ -d "$QUAZIP_SRC" ]] || git -c advice.detachedHead=false clone --depth 1 \
        --branch "v${QUAZIP_VERSION}" https://github.com/stachenov/quazip.git "$QUAZIP_SRC"
    cmake -S "$QUAZIP_SRC" -B "$QUAZIP_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT_ROOT" \
        -DCMAKE_INSTALL_PREFIX="$QUAZIP_DIR" -DQUAZIP_QT_MAJOR_VERSION=6
    cmake --build "$QUAZIP_SRC/build" --parallel "$JOBS"
    cmake --install "$QUAZIP_SRC/build"
else
    log "QuaZip already built"
fi

# ── 8. Clipper1 6.4.2 (vendored → built to Clipper1-6.4.2/) ───────────────────
step "Clipper1 ${CLIPPER1_VERSION} (from vendored source)"
CLIPPER1_DIR="$WORKSPACE/Clipper1-${CLIPPER1_VERSION}"   # note the dash: 1.0.7 path
if [[ ! -f "$CLIPPER1_DIR/lib/libpolyclipping.dylib" && ! -f "$CLIPPER1_DIR/lib/libpolyclipping.a" ]]; then
    [[ -f "$VENDORED_CLIPPER/clipper.cpp" ]] || die "vendored Clipper source missing at $VENDORED_CLIPPER"
    BUILD="$WORKSPACE/.clipper-build"
    rm -rf "$BUILD"; mkdir -p "$BUILD"
    # Clipper 6.4.2's CMakeLists declares cmake_minimum_required 2.6, which
    # CMake >= 4 rejects. Allow the old policy without modifying the vendored
    # upstream file (keeps its recorded SHA-256 intact).
    cmake -S "$VENDORED_CLIPPER" -B "$BUILD" \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$CLIPPER1_DIR"
    cmake --build "$BUILD" --parallel "$JOBS"
    cmake --install "$BUILD"
    log "Clipper1 installed to $CLIPPER1_DIR (lib + include/polyclipping)"
else
    log "Clipper1 already built"
fi

# ── 9. ngspice 42 (official mirror → shared lib + headers) ───────────────────
step "ngspice ${NGSPICE_VERSION} (shared library)"
NGSPICE_DIR="$WORKSPACE/ngspice-${NGSPICE_VERSION}"
if [[ ! -f "$NGSPICE_DIR/lib/libngspice.dylib" ]]; then
    NGSPICE_SRC="$WORKSPACE/ngspice-src"
    [[ -d "$NGSPICE_SRC" ]] || git -c advice.detachedHead=false clone --depth 1 \
        --branch "ngspice-${NGSPICE_VERSION}" https://github.com/imr/ngspice.git "$NGSPICE_SRC"
    ( cd "$NGSPICE_SRC"
      [[ -x ./configure ]] || ./autogen.sh
      mkdir -p release && cd release
      ../configure --prefix="$NGSPICE_DIR" --with-ngshared \
          --disable-debug --enable-xspice --enable-cider CFLAGS="-O2"
      make -j"$JOBS"
      make install )
    log "ngspice installed to $NGSPICE_DIR (include + libngspice.dylib)"
else
    log "ngspice already built"
fi

# ── 10. Build Fritzing ───────────────────────────────────────────────────────
step "Building Fritzing ${FRITZING_REF}"
BUILD_DIR="$WORKSPACE/fritzing-build"
mkdir -p "$BUILD_DIR"
( export PATH="$QT_ROOT/bin:$PATH"
  cd "$BUILD_DIR"
  "$QMAKE" -spec macx-clang "boost_root=$BOOST_DIR" "$FRITZING_APP/phoenix.pro"
  make -j"$JOBS" )

APP="$(find "$BUILD_DIR" -maxdepth 3 -name 'Fritzing.app' | head -1)"
[[ -n "$APP" ]] || die "build finished but Fritzing.app not found under $BUILD_DIR"

# ── 11. Bundle Qt frameworks + ngspice ───────────────────────────────────────
step "Deploying app bundle"
"$QT_ROOT/bin/macdeployqt" "$APP" -verbose=1
NGLIB="$(find "$NGSPICE_DIR/lib" -name 'libngspice*.dylib' | head -1)"
[[ -n "$NGLIB" ]] && { cp "$NGLIB" "$APP/Contents/MacOS/"; log "bundled $(basename "$NGLIB")"; }

echo
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Build complete — Fritzing ${FRITZING_REF}"
printf "║  %s\n" "$APP"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  open \"$APP\""
