#!/usr/bin/env bash
# Build Fritzing 1.0.7 from source on macOS (Intel or Apple Silicon).
#
# Every dependency comes from a first-party or official-mirror source, or is
# vendored+checksummed in this repo (deps/). Nothing is fetched from SourceForge.
#
#   Qt 6.5.3 ....... official Qt servers (aqtinstall)
#   fritzing-app ... github.com/fritzing  (tag 1.0.7)
#   fritzing-parts . github.com/fritzing  (develop branch; part defs/SVGs/bins)
#   Boost 1.84 ..... archives.boost.io    (official, headers only)
#   libgit2 1.7.1 .. github.com/libgit2   (built static)
#   svgpp 1.3.1 .... github.com/svgpp     (headers only)
#   QuaZip 1.4 ..... github.com/stachenov (built)
#   Clipper1 6.4.2 . vendored in deps/    (verified original, see PROVENANCE.md)
#   ngspice ........ github.com/imr/ngspice (official mirror; builds tag 46,
#                    installs as ngspice-42 — 42's source fails on Xcode 16.3)
set -euo pipefail

# ── Pinned versions (must match fritzing-app 1.0.7 pri/*detect.pri) ───────────
FRITZING_REF="1.0.7"
QT_VERSION="6.5.3"          # 1.0.7 accepts 6.5.3 .. 6.10.10; we pin 6.5.3
BOOST_VERSION="1_84_0"
LIBGIT2_VERSION="1.7.1"
QUAZIP_VERSION="1.4"
SVGPP_VERSION="1.3.1"
CLIPPER1_VERSION="6.4.2"
NGSPICE_VERSION="42"                # dir name Fritzing 1.0.7's spicedetect expects
NGSPICE_BUILD_TAG="ngspice-46"      # version we actually build: 42's bundled
                                    # cppduals illegally specializes std::is_compound
                                    # and fails on Xcode 16.3 libc++. 46 compiles
                                    # clean (same version Homebrew ships) and its
                                    # sharedspice API is compatible with Fritzing.
FRITZING_PARTS_REF="develop"        # fritzing-app's part definitions, SVGs, and
                                    # bins/core.fzb live in a separate repo and
                                    # aren't tracked as a submodule at this tag
                                    # (no .gitmodules at 1.0.7); fritzing-parts
                                    # itself hasn't been tag-released since 0.9.3b,
                                    # so develop (its default branch) is the
                                    # intended source for any current app version.

JOBS=$(sysctl -n hw.logicalcpu 2>/dev/null || echo 4)

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# fritzing-app's pri/*detect.pri scripts expect every dependency to sit as a
# sibling of fritzing-app/ itself — that's a hardcoded relative-path
# requirement, not a preference. Nesting the whole workspace under this repo
# (rather than in its parent directory) satisfies that while keeping
# everything this script downloads/builds contained inside Fritzing-macos/.
mkdir -p "$SCRIPT_DIR/build-workspace"
WORKSPACE="$(cd "$SCRIPT_DIR/build-workspace" && pwd)"
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
for pkg in cmake git python3 autoconf automake libtool pkg-config openssl@3 bison flex; do
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

# Every Qt 6.5.3 framework's baked-in .prl file (plus mkspecs/common/mac.conf)
# links "-framework AGL", a legacy OpenGL framework Apple removed entirely
# from modern macOS SDKs, so the final link step fails with
# "framework 'AGL' not found". Strip it everywhere it appears (idempotent).
AGL_HITS=$(grep -rl -- '-framework AGL' "$QT_ROOT" 2>/dev/null || true)
if [[ -n "$AGL_HITS" ]]; then
    while IFS= read -r f; do
        sed -i.bak -e 's/-framework AGL//g' "$f" && rm -f "$f.bak"
    done <<< "$AGL_HITS"
    log "patched -framework AGL out of Qt's .prl/mkspec files"
fi

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

# Fix an upstream typo in the 1.0.7 tag: pri/quazipdetect.pri appends a stray
# literal "intuisphere" to the QuaZip path, so qmake looks for a nonexistent
# directory. Strip it from the checked-out source (idempotent).
QZ_PRI="$FRITZING_APP/pri/quazipdetect.pri"
if [[ -f "$QZ_PRI" ]] && grep -q 'intuisphere' "$QZ_PRI"; then
    sed -i.bak 's/intuisphere//g' "$QZ_PRI" && rm -f "$QZ_PRI.bak"
    log "patched stray 'intuisphere' out of quazipdetect.pri"
fi

# Fix a Qt5-only code path in groundplanegenerator.cpp: it switches on
# QPaintDevice::PdmDevicePixelRatioF_EncodedA/B and calls encodeMetricF(),
# both of which existed only as a Qt5.14+ forward-compat shim and were
# removed from Qt6's QPaintDevice enum entirely, so it fails to compile
# against Qt 6.5.3 (idempotent).
GPG_CPP="$FRITZING_APP/src/svg/groundplanegenerator.cpp"
if [[ -f "$GPG_CPP" ]] && grep -q 'PdmDevicePixelRatioF_EncodedA' "$GPG_CPP"; then
    perl -0pi -e 's/\n\s*case PdmDevicePixelRatioF_EncodedA:\n\s*case PdmDevicePixelRatioF_EncodedB:\n\s*return QPaintDevice::encodeMetricF\(metric, 1\.0\);\n/\n/' "$GPG_CPP"
    log "patched Qt6-incompatible PdmDevicePixelRatioF_Encoded* case out of groundplanegenerator.cpp"
fi

# ── 4. fritzing-parts (part definitions, SVGs, bins/core.fzb) ────────────────
step "fritzing-parts (${FRITZING_PARTS_REF})"
FRITZING_PARTS="$WORKSPACE/fritzing-parts"
if [[ ! -d "$FRITZING_PARTS" ]]; then
    git -c advice.detachedHead=false clone --depth 1 --branch "$FRITZING_PARTS_REF" \
        https://github.com/fritzing/fritzing-parts.git "$FRITZING_PARTS"
else
    log "fritzing-parts already present; pulling latest $FRITZING_PARTS_REF"
    git -C "$FRITZING_PARTS" pull --depth 1 origin "$FRITZING_PARTS_REF" 2>/dev/null || true
fi

# ── 5. Boost 1.84 headers (official) ─────────────────────────────────────────
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

# ── 6. libgit2 1.7.1 (static) ────────────────────────────────────────────────
step "libgit2 ${LIBGIT2_VERSION} (static)"
LIBGIT2_DIR="$WORKSPACE/libgit2-${LIBGIT2_VERSION}"
if [[ ! -f "$LIBGIT2_DIR/lib/libgit2.a" ]]; then
    [[ -d "$LIBGIT2_DIR" ]] || git -c advice.detachedHead=false clone --depth 1 \
        --branch "v${LIBGIT2_VERSION}" https://github.com/libgit2/libgit2.git "$LIBGIT2_DIR"
    cmake -S "$LIBGIT2_DIR" -B "$LIBGIT2_DIR/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$LIBGIT2_DIR" \
        -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
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

# ── 7. svgpp 1.3.1 (headers) ─────────────────────────────────────────────────
step "svgpp ${SVGPP_VERSION} (headers)"
SVGPP_DIR="$WORKSPACE/svgpp-${SVGPP_VERSION}"
[[ -d "$SVGPP_DIR/include" ]] || git -c advice.detachedHead=false clone --depth 1 \
    --branch "v${SVGPP_VERSION}" https://github.com/svgpp/svgpp.git "$SVGPP_DIR"

# ── 8. QuaZip 1.4 (built against this Qt) ────────────────────────────────────
step "QuaZip ${QUAZIP_VERSION}"
QUAZIP_DIR="$WORKSPACE/quazip-${QT_VERSION}-${QUAZIP_VERSION}"   # dir must match $$QT_VERSION
if [[ ! -d "$QUAZIP_DIR/lib" ]]; then
    QUAZIP_SRC="$WORKSPACE/quazip-src"
    [[ -d "$QUAZIP_SRC" ]] || git -c advice.detachedHead=false clone --depth 1 \
        --branch "v${QUAZIP_VERSION}" https://github.com/stachenov/quazip.git "$QUAZIP_SRC"
    cmake -S "$QUAZIP_SRC" -B "$QUAZIP_SRC/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH="$QT_ROOT" \
        -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
        -DCMAKE_INSTALL_PREFIX="$QUAZIP_DIR" -DQUAZIP_QT_MAJOR_VERSION=6
    cmake --build "$QUAZIP_SRC/build" --parallel "$JOBS"
    cmake --install "$QUAZIP_SRC/build"
else
    log "QuaZip already built"
fi

# ── 9. Clipper1 6.4.2 (vendored → built to Clipper1-6.4.2/) ───────────────────
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
        -DCMAKE_OSX_ARCHITECTURES="x86_64;arm64" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$CLIPPER1_DIR"
    cmake --build "$BUILD" --parallel "$JOBS"
    cmake --install "$BUILD"
    log "Clipper1 installed to $CLIPPER1_DIR (lib + include/polyclipping)"
else
    log "Clipper1 already built"
fi

# ── 10. ngspice 42 (official mirror → shared lib + headers) ───────────────────
step "ngspice ${NGSPICE_VERSION} (shared library)"
NGSPICE_DIR="$WORKSPACE/ngspice-${NGSPICE_VERSION}"
if [[ ! -f "$NGSPICE_DIR/lib/libngspice.dylib" ]]; then
    NGSPICE_SRC="$WORKSPACE/ngspice-src"
    # Ensure the source tree is at NGSPICE_BUILD_TAG; re-clone if it is missing
    # or (e.g. from an earlier run) checked out at a different tag.
    if [[ ! -d "$NGSPICE_SRC/.git" ]] || \
       ! git -C "$NGSPICE_SRC" describe --tags --exact-match 2>/dev/null | grep -qx "$NGSPICE_BUILD_TAG"; then
        rm -rf "$NGSPICE_SRC"
        git -c advice.detachedHead=false clone --depth 1 \
            --branch "$NGSPICE_BUILD_TAG" https://github.com/imr/ngspice.git "$NGSPICE_SRC"
    fi
    # macOS system bison/flex are ancient and cannot parse ngspice's grammar;
    # Homebrew's are keg-only, so put them first on PATH for autogen and make.
    BISON_PREFIX="$(brew --prefix bison 2>/dev/null || true)"
    FLEX_PREFIX="$(brew --prefix flex 2>/dev/null || true)"
    ( export PATH="${BISON_PREFIX:+$BISON_PREFIX/bin:}${FLEX_PREFIX:+$FLEX_PREFIX/bin:}$PATH"
      cd "$NGSPICE_SRC"
      [[ -x ./configure ]] || ./autogen.sh
      rm -rf release && mkdir -p release && cd release   # clean reconfigure
      # Flags mirror Homebrew's proven ngspice build, plus --with-ngshared to
      # produce libngspice.dylib (which Homebrew's formula omits).
      ../configure --prefix="$NGSPICE_DIR" --with-ngshared \
          --enable-xspice --enable-cider --disable-openmp CFLAGS="-O2"
      make -j"$JOBS"
      make install )
    log "ngspice ${NGSPICE_BUILD_TAG} installed to $NGSPICE_DIR (include + libngspice.dylib)"
else
    log "ngspice already built"
fi

# ── 11. Build Fritzing ───────────────────────────────────────────────────────
step "Building Fritzing ${FRITZING_REF}"
BUILD_DIR="$WORKSPACE/fritzing-build"
mkdir -p "$BUILD_DIR"
( export PATH="$QT_ROOT/bin:$PATH"
  cd "$BUILD_DIR"
  "$QMAKE" -spec macx-clang "boost_root=$BOOST_DIR" "$FRITZING_APP/phoenix.pro"
  make -j"$JOBS" )

APP="$(find "$BUILD_DIR" "$WORKSPACE" -maxdepth 3 -name 'Fritzing.app' 2>/dev/null | head -1)"
[[ -n "$APP" ]] || die "build finished but Fritzing.app not found under $BUILD_DIR or $WORKSPACE"

# ── 12. Bundle Qt frameworks + ngspice + parts library ───────────────────────
step "Deploying app bundle"
"$QT_ROOT/bin/macdeployqt" "$APP" -verbose=1
NGLIB="$(find "$NGSPICE_DIR/lib" -name 'libngspice*.dylib' | head -1)"
[[ -n "$NGLIB" ]] && { cp "$NGLIB" "$APP/Contents/MacOS/"; log "bundled $(basename "$NGLIB")"; }

# FolderUtils::getAppPartsSubFolder2() walks up from the executable's directory
# looking for a "parts" (or "fritzing-parts") folder; Contents/parts is the
# shallowest match. Without it the app can't find bins/core.fzb and shows
# "Unable to find parts git repository" at startup. rsync so re-deploys stay
# in sync with fritzing-parts without re-copying everything from scratch.
rsync -a --delete --exclude='.git' "$FRITZING_PARTS/" "$APP/Contents/parts/"
log "bundled fritzing-parts into Contents/parts"

# macdeployqt bundles Qt frameworks the main Fritzing binary links directly,
# and copies third-party dylibs (QuaZip, Clipper1) it finds via rpath, but it
# doesn't recurse into *those* dylibs' own Qt dependencies — e.g. QuaZip links
# QtCore5Compat, which then goes missing from Contents/Frameworks and crashes
# the app at launch ("Library not loaded: @rpath/QtCore5Compat..."). Sweep the
# whole bundle for any @rpath/Qt*.framework reference still missing and copy
# it in, repeating until nothing's left, then re-sign (bundle contents changed
# after macdeployqt's own signing pass).
FRAMEWORKS_DIR="$APP/Contents/Frameworks"
while :; do
    MISSING=""
    while IFS= read -r bin; do
        for dep in $(otool -L "$bin" 2>/dev/null | awk '/@rpath\/Qt[A-Za-z0-9]*\.framework/ {print $1}'); do
            fw="$(echo "$dep" | sed -E 's#@rpath/([^/]+\.framework).*#\1#')"
            [[ -d "$FRAMEWORKS_DIR/$fw" ]] || MISSING+="$fw"$'\n'
        done
    done < <(find "$APP/Contents" -type f \( -perm -u+x -o -name '*.dylib' \) 2>/dev/null)
    MISSING="$(echo "$MISSING" | sort -u | grep -v '^$' || true)"
    [[ -z "$MISSING" ]] && break
    while IFS= read -r fw; do
        [[ -d "$QT_ROOT/lib/$fw" ]] || continue
        cp -R "$QT_ROOT/lib/$fw" "$FRAMEWORKS_DIR/"
        log "bundled transitively-missing framework: $fw"
    done <<< "$MISSING"
done
codesign --force --deep --sign - "$APP"

echo
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  Build complete — Fritzing ${FRITZING_REF}"
printf "║  %s\n" "$APP"
echo "╚══════════════════════════════════════════════════════════╝"
echo "  open \"$APP\""
