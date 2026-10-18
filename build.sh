#!/usr/bin/env bash
#
# Build statically-linked knock and knockd (port knocking, jvinet/knock) for
# every architecture flavor:
#   x86_64 (native), x86 (i686), arm64 (aarch64), arm32 (armhf),
#   mips64 + mips64el (n64), mips32 + mips32el (o32),
#   ppc64le, ppc32, ppc64be
#
# Two binaries per flavor (client + daemon). libpcap is cross-built
# statically per flavor (knockd needs it; the release tarball ships no
# configure script, so the source is autoreconf'd once on the host).
#
# Outputs:
#   dist/knock-<ver>-<flavor>-static     client (stripped)
#   dist/knockd-<ver>-<flavor>-static    daemon  (stripped)
#   install/<triplet>/                   full install trees
#
# Runs on an x86_64 Ubuntu/Debian host; flavors other than x86_64 are
# cross-compiled with the Ubuntu cross toolchains. qemu-user is used to
# sanity-check the cross binaries. See README.md for details.
#
set -euo pipefail

KNOCK_VERSION="${KNOCK_VERSION:-0.8}"
LIBPCAP_VERSION="${LIBPCAP_VERSION:-1.10.7}"

NATIVE_TRIPLET=x86_64-linux-gnu
TRIPLETS="${TRIPLETS:-x86_64-linux-gnu i686-linux-gnu aarch64-linux-gnu arm-linux-gnueabihf mips64-linux-gnuabi64 mips64el-linux-gnuabi64 mips-linux-gnu mipsel-linux-gnu powerpc64le-linux-gnu powerpc-linux-gnu powerpc64-linux-gnu}"
CROSS_GCC_VER="${CROSS_GCC_VER:-14}"
JOBS="${JOBS:-$(nproc)}"

BASE="${BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
BUILD=x86_64-linux-gnu
SRC="$BASE/src"
DEPS="$BASE/deps"
DIST="$BASE/dist"
mkdir -p "$SRC" "$DEPS" "$DIST"

log() { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }

qemu_for_triplet() {
    case "$1" in
        x86_64-linux-gnu) echo "" ;;
        i686-*)          echo qemu-i386-static ;;
        aarch64-*)       echo qemu-aarch64-static ;;
        arm-*)           echo qemu-arm-static ;;
        mips64el-*)      echo qemu-mips64el-static ;;
        mips64-*)        echo qemu-mips64-static ;;
        mipsel-*)        echo qemu-mipsel-static ;;
        mips-*)          echo qemu-mips-static ;;
        powerpc64le-*)   echo qemu-ppc64le-static ;;
        powerpc64-*)     echo qemu-ppc64-static ;;
        powerpc-*)       echo qemu-ppc-static ;;
        *) echo "unsupported triplet: $1" >&2; return 1 ;;
    esac
}

short_for_triplet() {
    case "$1" in
        x86_64-linux-gnu) echo x86_64 ;;
        i686-*)          echo x86 ;;
        aarch64-*)       echo arm64 ;;
        arm-*)           echo arm32 ;;
        mips64el-*)      echo mips64el ;;
        mips64-*)        echo mips64 ;;
        mipsel-*)        echo mips32el ;;
        mips-*)          echo mips32 ;;
        powerpc64le-*)   echo ppc64le ;;
        powerpc64-*)     echo ppc64be ;;
        powerpc-*)       echo ppc32 ;;
        *) echo "unsupported triplet: $1" >&2; return 1 ;;
    esac
}

# --------------------------------------------------------------------------
# 0. Host dependencies
# --------------------------------------------------------------------------
check_host_deps() {
    local missing=()
    local t QEMU

    [ -f /usr/lib/x86_64-linux-gnu/libc.a ] || missing+=(libc6-dev)
    command -v flex >/dev/null || missing+=(flex)
    command -v bison >/dev/null || missing+=(bison)
    command -v autoreconf >/dev/null || missing+=(autoconf automake)
    for t in $TRIPLETS; do
        if [ "$t" != "$NATIVE_TRIPLET" ]; then
            command -v "$t-gcc-$CROSS_GCC_VER" >/dev/null || missing+=("gcc-$CROSS_GCC_VER-$t")
            [ -e "/usr/$t/lib/libc.a" ] || case "$t" in
                i686-*)        missing+=(libc6-dev-i386-cross) ;;
                aarch64-*)     missing+=(libc6-dev-arm64-cross) ;;
                arm-*)         missing+=(libc6-dev-armhf-cross) ;;
                mips64el-*)    missing+=(libc6-dev-mips64el-cross) ;;
                mips64-*)      missing+=(libc6-dev-mips64-cross) ;;
                mipsel-*)      missing+=(libc6-dev-mipsel-cross) ;;
                mips-*)        missing+=(libc6-dev-mips-cross) ;;
                powerpc64le-*) missing+=(libc6-dev-ppc64el-cross) ;;
                powerpc64-*)   missing+=(libc6-dev-ppc64-cross) ;;
                powerpc-*)     missing+=(libc6-dev-powerpc-cross) ;;
            esac
        fi
        QEMU=$(qemu_for_triplet "$t")
        [ -z "$QEMU" ] && continue   # native flavor runs directly, no qemu
        command -v "$QEMU" >/dev/null || missing+=(qemu-user-static)
    done

    # deduplicate
    local uniq=() p
    for p in "${missing[@]:-}"; do
        [ -n "$p" ] || continue
        case " ${uniq[*]:-} " in *" $p "*) ;; *) uniq+=("$p") ;; esac
    done

    if [ "${#uniq[@]}" -gt 0 ]; then
        echo "Missing host packages: ${uniq[*]}" >&2
        echo "Install them with:" >&2
        echo "  sudo apt-get install -y ${uniq[*]}" >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------
# 1. Fetch sources and autoreconf knock once (release tarball has no
#    configure script)
# --------------------------------------------------------------------------
fetch_sources() {
    cd "$SRC"
    [ -f "knock-$KNOCK_VERSION.tar.gz" ] || \
        curl -fsSLO "https://github.com/jvinet/knock/archive/refs/tags/v$KNOCK_VERSION.tar.gz" \
        && mv "v$KNOCK_VERSION.tar.gz" "knock-$KNOCK_VERSION.tar.gz" 2>/dev/null || true
    [ -f "libpcap-$LIBPCAP_VERSION.tar.gz" ] || \
        curl -fsSLO "https://www.tcpdump.org/release/libpcap-$LIBPCAP_VERSION.tar.gz"

    [ -d "libpcap-$LIBPCAP_VERSION" ] || tar xf "libpcap-$LIBPCAP_VERSION.tar.gz"
    if [ ! -d "knock-$KNOCK_VERSION" ]; then
        tar xf "knock-$KNOCK_VERSION.tar.gz"
        ( cd "knock-$KNOCK_VERSION" && autoreconf -fi )
    fi
    cd "$BASE"
}

# --------------------------------------------------------------------------
# 2. Build one flavor (libpcap, then knock + knockd)
# --------------------------------------------------------------------------
build_flavor() {
    local T=$1
    local short
    short=$(short_for_triplet "$T")
    local out_c="$DIST/knock-$KNOCK_VERSION-$short-static"
    local out_d="$DIST/knockd-$KNOCK_VERSION-$short-static"
    local W="$BASE/build-$T"
    local prefix="$BASE/install/$T"
    local PCAP_PREFIX

    if [ "$T" = "$NATIVE_TRIPLET" ]; then
        PCAP_PREFIX="$DEPS/native/pcap"
    else
        PCAP_PREFIX="$DEPS/cross/$T/pcap"
    fi

    local CC CXX AR RANLIB STRIPTOOL hostflags
    if [ "$T" = "$NATIVE_TRIPLET" ]; then
        CC=gcc CXX=g++ AR=ar RANLIB=ranlib STRIPTOOL=strip
        hostflags=""
    else
        CC=$T-gcc-$CROSS_GCC_VER CXX=$T-g++-$CROSS_GCC_VER
        AR=$T-ar RANLIB=$T-ranlib STRIPTOOL=$T-strip
        hostflags="--build=$BUILD --host=$T"
    fi

    if [ ! -f "$PCAP_PREFIX/lib/libpcap.a" ]; then
        log "Building libpcap $LIBPCAP_VERSION for $T"
        mkdir -p "$W/pcap"
        cd "$W/pcap"
        # shellcheck disable=SC2086
        CC=$CC AR=$AR RANLIB=$RANLIB \
            "$SRC/libpcap-$LIBPCAP_VERSION/configure" \
            $hostflags \
            --prefix="$PCAP_PREFIX" \
            --disable-shared --enable-static \
            --disable-dbus --without-libnl --disable-rdma \
            --disable-bluetooth
        make -j"$JOBS"
        make install
        cd "$BASE"
    fi

    log "Building knock $KNOCK_VERSION (knock + knockd) for $T"
    [ -x "$out_c" ] && [ -x "$out_d" ] && { log "$T already built"; return; }
    mkdir -p "$W/knock"
    cd "$W/knock"
    # shellcheck disable=SC2086
    CC=$CC CXX=$CXX AR=$AR RANLIB=$RANLIB \
        "$SRC/knock-$KNOCK_VERSION/configure" \
        $hostflags \
        --prefix="$prefix" \
        --sbindir="$prefix/bin" \
        CPPFLAGS="-I$PCAP_PREFIX/include" \
        LDFLAGS="-static -L$PCAP_PREFIX/lib" \
        LIBS="-lpcap"
    # The git-export tarball's man-page rules are broken (no doc/*.1.in), so
    # build only the programs and install them by hand.
    make -j"$JOBS" knock knockd
    mkdir -p "$prefix/bin" "$prefix/etc"
    cp knock "$prefix/bin/"
    cp knockd "$prefix/bin/"
    for f in "$SRC/knock-$KNOCK_VERSION"/knockd.conf \
             "$SRC/knock-$KNOCK_VERSION"/etc/knockd.conf; do
        [ -f "$f" ] && cp "$f" "$prefix/etc/knockd.conf" && break
    done
    cd "$BASE"

    cp "$prefix/bin/knock" "$out_c"
    cp "$prefix/bin/knockd" "$out_d"
    "$STRIPTOOL" "$out_c" "$out_d"
}

# --------------------------------------------------------------------------
# 3. Sanity check the results
# --------------------------------------------------------------------------
verify() {
    log "Results"
    local t short QEMU b
    for t in $TRIPLETS; do
        short=$(short_for_triplet "$t")
        QEMU=$(qemu_for_triplet "$t")
        for b in "$DIST/knock-$KNOCK_VERSION-$short-static" \
                 "$DIST/knockd-$KNOCK_VERSION-$short-static"; do
            [ -e "$b" ] || continue
            file "$b" | sed 's/^/  /'
            if [ -n "$QEMU" ]; then
                timeout 120 "$QEMU" "$b" --help 2>/dev/null | head -1 | sed 's/^/  /' || true
            else
                timeout 120 "$b" --help 2>/dev/null | head -1 | sed 's/^/  /' || true
            fi
        done
    done
}

main() {
    check_host_deps
    fetch_sources

    local t
    for t in $TRIPLETS; do
        build_flavor "$t"
    done

    verify
    log "Done. Binaries in $DIST"
}

main "$@"
