# static-knock

Statically-linked [knock](https://github.com/jvinet/knock) — the classic
port-knocking utility — for every major Linux architecture. Two binaries per
flavor: the **knock** client (sends knock sequences) and the **knockd** daemon
(listens for sequences and fires commands, e.g. opening firewall ports).

| Binaries per flavor | Description |
|---|---|
| `knock-<ver>-<flavor>-static` | client — sends TCP/UDP knock sequences |
| `knockd-<ver>-<flavor>-static` | daemon — sniffs for sequences (needs libpcap) |

Flavors: `x86_64`, `x86` (i686), `arm64`, `arm32` (armhf), `mips64`,
`mips64el`, `mips32`, `mips32el`, `ppc64le`, `ppc32`, `ppc64be` — all
statically linked against glibc 2.40, each with its own statically-linked
libpcap 1.10.7.

## Quick start

Requirements: Ubuntu/Debian-ish **x86_64** host with `build-essential`,
`curl`, `flex` + `bison` (libpcap), **`autoconf` + `automake`** (the knock
release tarball ships no `configure` script), and the cross toolchains + qemu
for every flavor you build:

```bash
sudo apt-get install -y autoconf automake flex bison \
    gcc-14-i686-linux-gnu libc6-dev-i386-cross binutils-i686-linux-gnu \
    gcc-14-aarch64-linux-gnu libc6-dev-arm64-cross binutils-aarch64-linux-gnu \
    gcc-14-arm-linux-gnueabihf libc6-dev-armhf-cross binutils-arm-linux-gnueabihf \
    gcc-14-mips64-linux-gnuabi64 libc6-dev-mips64-cross binutils-mips64-linux-gnuabi64 \
    gcc-14-mips64el-linux-gnuabi64 libc6-dev-mips64el-cross binutils-mips64el-linux-gnuabi64 \
    gcc-14-mips-linux-gnu libc6-dev-mips-cross binutils-mips-linux-gnu \
    gcc-14-mipsel-linux-gnu libc6-dev-mipsel-cross binutils-mipsel-linux-gnu \
    gcc-14-powerpc64le-linux-gnu libc6-dev-ppc64el-cross binutils-powerpc64le-linux-gnu \
    gcc-14-powerpc-linux-gnu libc6-dev-powerpc-cross binutils-powerpc-linux-gnu \
    gcc-14-powerpc64-linux-gnu libc6-dev-ppc64-cross binutils-powerpc64-linux-gnu \
    qemu-user-static
```

(The `build.sh` dependency check prints exactly what is missing for the
flavors you have selected, with the matching install line.)

Then:

```bash
./build.sh
```

Binaries land in `dist/`, install trees (including `etc/knockd.conf` sample)
under `install/<triplet>/`. A full build of all 11 flavors takes roughly
20–30 minutes on a 20-core machine. The script is re-runnable: sources, the
autoreconf'd tree, per-flavor libpcap installs, and finished binaries are
skipped when already present.

### Options

```bash
KNOCK_VERSION=0.8      # knock version
LIBPCAP_VERSION=1.10.7 # libpcap version
TRIPLETS="..."         # space-separated subset of triplets (see build.sh)
CROSS_GCC_VER=14       # cross gcc package series on the host
JOBS=$(nproc)          # parallel jobs
BASE=/path/to/dir      # where to place src/deps/build/install/dist (default: repo dir)
```

## Deploying to a device

```bash
scp dist/knockd-0.8-arm64-static root@router:/usr/local/bin/knockd
scp dist/knock-0.8-x86_64-static user@workstation:/usr/local/bin/knock
```

`knockd` needs root on the target (raw packet capture) and a config file
(`-c`, sample in `install/<triplet>/etc/knockd.conf`).

## Verifying on an x86_64 host (qemu)

The build script sanity-checks both binaries of every flavor under qemu.
A real client test needs no privileges — send a TCP knock at a local
listener:

```bash
# terminal 1: listener
nc -l 7000
# terminal 2: static client under qemu
qemu-aarch64-static ./dist/knock-0.8-arm64-static 127.0.0.1 7000:tcp
```

## Caveats

- `knockd` requires root/CAP_NET_RAW on the target for live capture; the
  client is unprivileged.
- Static glibc: hostname resolution in the client falls back gracefully but
  numeric addresses always work — same as any statically linked glibc tool.
- knock 0.8 is the last upstream release (2020); it builds cleanly but sees
  no active development.

## How it works / notable gotchas

- The knock release tarball is a git export **without a `configure` script**
  — the build runs `autoreconf -fi` on the extracted source once (requires
  autoconf/automake on the host).
- libpcap is cross-built statically per flavor (flex/bison needed on the
  host); both knock binaries link it via `CPPFLAGS`/`LDFLAGS`/`LIBS=-lpcap`
  with plain `LDFLAGS=-static` (no libtool wrapper involved).
- `--sbindir` is redirected to `bin/` so both binaries land in one place.

Build layout (all gitignored): `src/`, `deps/`, `build-*/`, `install/`,
`dist/`.

## License

knock is GPLv2+; statically-linked binaries are derivative works, so if you
distribute the binaries you must offer the corresponding source (this repo
plus the pinned upstream version is a reasonable way to do that). No license
is claimed over these build files — add one of your choosing before
publishing.
