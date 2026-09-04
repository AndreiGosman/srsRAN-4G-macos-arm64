# srsRAN 4G on macOS ARM64

A port of [srsRAN 4G](https://github.com/srsran/srsRAN_4G) to native Apple
Silicon: 25 numbered patches, four compatibility shims, and a small set of
`linux/*` uapi headers.

This repository carries no srsRAN source. Clone upstream, apply the patches,
build. `scripts/install.sh` does all of it.

**Phase 1 is validated end to end.** srsepc, srsenb and srsue run together over
a ZeroMQ radio; S1AP rides SCTP through a userspace stack; the UE attaches and
is assigned 172.16.0.2; a ping to the SGi gateway returns with no loss at 20 to
45 ms. Transcripts are in [docs/phase1-validation.md](docs/phase1-validation.md).

**Phase 2 is validated on real hardware.** Live cell search with a LibreSDR
B220 mini inventoried 34 LTE cells across bands 1, 3 and 7 in Bucharest. That
is receive only; nothing is transmitted at any point.

The Phase 1 loopback transmits nothing either: both ends exchange IQ samples
over TCP on localhost.

## Motivation

srsRAN builds on Linux and assumes it throughout. Most of the assumptions are
small and invisible until the platform changes: a header that only glibc ships,
a substring match in CMake that happens to be true for one processor string and
false for another, a plugin loader that names shared objects with a literal
`.so`. Two are not small. There is no SCTP in the XNU kernel at all, and there
is no `timerfd` and no `/dev/net/tun`.

The result is a stack that a MacBook can run on its own: a complete LTE network,
core included, without a Linux machine or a virtual one in the path. That is
useful for protocol work, for teaching, and as the foundation for the Osmocom
ports that follow.

Eight of the 25 patches fix defects that have nothing to do with macOS. Those
are listed under [Upstream contributions](#upstream-contributions).

## Architecture

Three things Darwin does not have needed a shim. Each keeps the Linux interface
so that call sites stay unchanged, and each is a single header rather than a
library, so the patches carry no new link dependencies.

**`shims/timerfd_compat.h`** provides `timerfd_create`, `timerfd_settime`,
`timerfd_gettime` and `struct itimerspec`, which Darwin also lacks. kqueue
`EVFILT_TIMER` drives the timing and one background thread waits on a shared
kqueue, but a kqueue descriptor cannot be `read()`, and srsRAN reads the
expiration count straight out of the descriptor. So each timer hands the caller
the read end of a pipe that the thread writes into. The descriptor is both
readable and pollable, which is what the two call sites need between them.

**`shims/tun_compat.h`** provides `srsran_tun_open`, `srsran_tun_read` and
`srsran_tun_write`. Darwin's equivalent of a TUN device is utun, a `PF_SYSTEM`
control socket, and it differs in two ways callers must know about: the kernel
picks the interface name, so a configured name is reported and ignored, and
every packet carries a four byte address family prefix with no equivalent of
`IFF_NO_PI` to switch it off. The prefix is added and stripped with `writev` and
`readv`, so no copy is introduced on the user plane.

**`shims/unix_socket_compat.h`** handles the abstract UNIX socket namespace,
which Linux has and Darwin does not. srsRAN's S11 interface between the MME and
the SPGW names its sockets with a leading NUL byte; on Darwin that is an empty
path. The helper keeps the abstract form on Linux and falls back to a real file
elsewhere, unlinking it before bind and carrying the shorter address length.

**`shims/endian_compat.h`** maps `htole*` and `le*toh` onto
`libkern/OSByteOrder.h`. Two files use these macros without including anything
that declares them; on glibc they arrive transitively.

SCTP is not a shim in this repository. It is a separate library,
[libsctp-compat-macos-arm64](https://github.com/AndreiGosman/libsctp-compat-macos-arm64),
which presents the Linux lksctp API over [usrsctp](https://github.com/sctplab/usrsctp)
with a real file descriptor bridge, and interposes ten libc socket calls by link
order. srsRAN links it unchanged.

**`linux-compat-headers/`** holds `linux/ip.h`, `linux/ipv6.h`, `linux/in6.h`,
`linux/if.h`, `linux/if_tun.h`, `linux/tcp.h`, `linux/types.h` and
`linux/udp.h`. These go into the shared prefix rather than the source tree,
which looks like the include-shadowing trap that this port hit three times, and
is not: no macOS component ships a `linux/` directory, so the namespace cannot
collide by construction. The structures inside are wire formats fixed by RFC, so
declaring them is exact rather than approximate. That is what lets 37 uses of
`struct iphdr` and `struct ipv6hdr` compile with no source change at all.

## Build

Requires macOS on Apple Silicon and Homebrew.

```sh
git clone https://github.com/AndreiGosman/srsRAN-4G-macos-arm64.git
cd srsRAN-4G-macos-arm64
./scripts/install.sh
```

That installs the Homebrew dependencies, builds and installs usrsctp and
libsctp-compat, runs the SCTP test suite, installs the `linux/*` headers,
clones srsRAN, applies the 25 patches, configures, builds, installs, and
verifies that all three binaries start in a clean environment.

Everything lands under `~/sdr-lab` by default; set `SRSRAN_PREFIX` to change
that. Nothing is written to `/opt/homebrew` except the Homebrew packages.

### Doing it by hand

```sh
brew install cmake pkg-config boost fftw zeromq uhd libconfig mbedtls@3 tmux
./scripts/install_usrsctp.sh
# build and install libsctp-compat, then:
./linux-compat-headers/install.sh "$PREFIX/local"
git clone https://github.com/srsran/srsRAN_4G.git
cd srsRAN_4G
for p in ../patches/*.patch; do patch -p1 < "$p"; done
mkdir build && cd build
cmake .. \
  -DCMAKE_INSTALL_PREFIX="$PREFIX/local" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="$(brew --prefix mbedtls@3)" \
  -DSRSRAN_CXX_STANDARD=c++17 \
  -DCMAKE_INSTALL_RPATH="$PREFIX/local/lib" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
  -DCMAKE_C_FLAGS="-I$PREFIX/local/include" \
  -DCMAKE_CXX_FLAGS="-I$PREFIX/local/include" \
  -DENABLE_WERROR=OFF -DENABLE_HARDSIM=OFF \
  -DENABLE_UHD=ON -DENABLE_ZEROMQ=ON \
  -DENABLE_SRSUE=ON -DENABLE_SRSENB=ON -DENABLE_SRSEPC=ON \
  -DENABLE_GUI=OFF -DENABLE_5GNR=OFF \
  -DENABLE_ALL_TEST=OFF -DBUILD_TESTS=OFF
make -j$(sysctl -n hw.ncpu) && make install
```

Why the non-obvious flags:

| Flag | Reason |
|---|---|
| `CMAKE_POLICY_VERSION_MINIMUM=3.5` | CMake 4 refuses the minimum srsRAN declares |
| `mbedtls@3` and `CMAKE_PREFIX_PATH` | mbedtls 4 removed `aes.h` and `md5.h` and made `mbedtls_md_hmac` private |
| `SRSRAN_CXX_STANDARD=c++17` | UHD 4.7 and later use `std::is_same_v` in public headers. A command-line `-std` loses to the pinned one appended after it, which is why patch 019 makes it a cache variable |
| `CMAKE_INSTALL_RPATH` | Installed binaries otherwise carry no rpath and fail under `sudo`, which strips every `DYLD_*` variable under SIP |
| `ENABLE_WERROR=OFF` | Apple clang 21 is much newer than upstream CI, and warns about the bundled fmt |
| `ENABLE_HARDSIM=OFF` | The PC/SC framework on macOS uses different integer types |
| the two `-I` flags | So `netinet/sctp.h` is found by targets that do not receive `SCTP_INCLUDE_DIRS` |

Verify before running, in a clean environment, because that is what `sudo`
gives them:

```sh
for b in srsue srsenb srsepc; do
  env -i HOME=$HOME "$PREFIX/local/bin/$b" --help >/dev/null && echo "$b ok"
done
```

Check all three. Testing only one is how the missing rpath was missed the first
time.

## Running the loopback

```sh
mkdir -p "$PREFIX/etc/srsran"
cp etc/srsran/*.template "$PREFIX/etc/srsran/"
cp etc/srsran/{rr,sib,rb}.conf "$PREFIX/etc/srsran/"
# rename the .template files, then generate a key pair:
#   K=$(openssl rand -hex 16); OPc=$(openssl rand -hex 16)
# and put the same two values in ue.conf and user_db.csv
sudo ./scripts/run-faza1.sh
ping -c 5 172.16.0.1
```

`run-faza1.sh` needs root, for three reasons: srsepc and srsue each create a
utun, and the two loopback aliases the GTP-U planes use do not exist by default
on macOS. It adds the aliases, kills leftovers, refuses to start if a port is
still held and names the holder, then starts each component and waits for a
marker in its log before the next one.

Use five pings. The first can time out legitimately while the UE comes out of
idle.

### Things that will surprise you

**Interface names.** The kernel assigns `utunN` for the first free N. The
configured `tun_dev_name` and `sgi_if_name` are reported and ignored, and the
number varies between runs. Read the real name from the log.

**Routes.** macOS installs no route for a utun, and both tunnel addresses are
local to one machine, so the launcher adds two deliberately crossed host
routes. Without the crossing the kernel answers on the loopback and the ping
proves nothing. Linux avoids the whole question with network namespaces, which
macOS does not have.

**SCTP addresses.** usrsctp drops traffic addressed to a loopback alias.
127.0.0.1 works and so does a real interface address, so the S1AP endpoints stay
on 127.0.0.1 while GTP-U keeps its aliases.

**Encapsulation ports.** Two processes cannot share one, so srsepc and srsenb
each get their own and are told the other's, through
`LIBSCTP_COMPAT_UDP_ENCAPS_PORT` and `LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT`.

**Logs.** srslog buffers a file log and flushes at exit, so a running process
appears to write nothing at all. All three configurations use
`filename = stdout` and the launcher tees.

## Phase 1 validation

Full transcripts in [docs/phase1-validation.md](docs/phase1-validation.md).
The short version:

```
[S1AP] Proc "MME Connection" - S1Setup procedure completed successfully
[NAS]  Network attach successful. APN: srsapn, IP: 172.16.0.2

5 packets transmitted, 5 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 22.985/30.953/38.474/6.126 ms
```

Corroborated by `TX PDU` and `RX PDU` pairs in the UE's gateway log, which is
what rules out a loopback shortcut, and by zero occurrences of `IPv6 not
supported yet` in the EPC log, which is the signature of the utun prefix being
left in the buffer.

Thirty milliseconds is not a slow network. The packet crosses a complete LTE
stack twice.

## Upstream contributions

Eight of the 25 patches fix defects that are not specific to macOS. They are
being submitted separately to `srsran/srsRAN_4G`, each argued on the platform it
actually affects.

| Patch | Fix | Who else it affects | PR |
|---|---|---|---|
| [001](patches/001-arm64-not-arm32-flags.patch) | Detect 64-bit ARM by explicit processor names | Any platform reporting `arm64`. Linux `aarch64` silently loses `HAVE_NEONv8` from the same asymmetry | [#1544](https://github.com/srsran/srsRAN_4G/pull/1544) |
| [003](patches/003-bundled-fmt-include-priority.patch) | Give the bundled fmt include priority | Any system with fmt on an explicit include path | not yet opened |
| [010](patches/010-template-keyword.patch) | Drop a `template` keyword with no argument list | Every conforming compiler. The construct is ill-formed; clang 21 merely enforces it | not yet opened |
| [014](patches/014-mbedtls-include-priority.patch) | Give the selected mbedtls priority | Any system with a second mbedtls installed | not yet opened |
| [016](patches/016-glibc-prereq-guard.patch) | Test for `__GLIBC_PREREQ` before calling it | musl, so Alpine and most embedded builds | not yet opened |
| [017](patches/017-portable-ifreq-in6-members.patch) | Portable `ifreq` and `in6_addr` member spellings | No behaviour change on Linux; makes the code build on BSD | not yet opened |
| [019](patches/019-cxx-standard-option.patch) | Make the C++ standard selectable | Anyone building against UHD 4.7 or later | not yet opened |
| [024](patches/024-cell-search-getopt.patch) | Fix `cell_search` getopt parsing | Every platform. Every flag after the first is silently ignored | not yet opened |

The first is open. The remaining six are prepared and held deliberately:
patch 001 is the strongest argument and the smallest diff, so it goes alone as
a test of whether the maintainers want this class of change at all. The others
follow once there is an answer.

## Repository layout

```
patches/                 25 numbered patches, each with a commit-style rationale
shims/                   The four compatibility headers the patches install
linux-compat-headers/    linux/* uapi headers plus their installer
scripts/                 install.sh, install_usrsctp.sh, run-faza1.sh
etc/srsran/              Configuration templates, no keys
docs/                    Session summary and Phase 1 transcripts
```

[docs/session-summary.md](docs/session-summary.md) is the long form: how each
patch was arrived at, the design decisions with the arguments against them, and
a section on the bugs that cost the most time. It is deliberately honest about
the false starts, because a port is mostly false starts and a document that
hides them is not reusable.

## Dependencies

Homebrew: `cmake`, `pkg-config`, `boost`, `fftw`, `zeromq`, `uhd`, `libconfig`,
`mbedtls@3`, `tmux`.

Built from source into the prefix: [usrsctp](https://github.com/sctplab/usrsctp)
at master, no patches, and
[libsctp-compat-macos-arm64](https://github.com/AndreiGosman/libsctp-compat-macos-arm64).

Tested on Darwin 25.5 arm64 with Apple clang 21 and CMake 4.4.3, against srsRAN
4G at upstream `6bcbd9e5b`.

## Hardware note for B210 owners

Patch [025](patches/025-rf-uhd-libresdr-mcr.patch) lowers the default master
clock rate for B200 series devices from 23.04 MHz to 11.52 MHz, because the
LibreSDR B220 mini presents itself as one and loses its VITA control channel
above that. A genuine Ettus B210 is unaffected by the hardware limit and can be
put back on the upstream default:

```
device_args = master_clock_rate=23.04e6
```

This patch is the one change in the series that is deliberately not upstream
material.

## Status and limitations

Phase 1 works. Beyond that:

- IPv6 bearers are refused rather than silently failing. Assigning an IPv6
  address to an interface needs `SIOCAIFADDR_IN6` and is not implemented.
- Network namespaces have no equivalent, so a configured `netns` is an error.
- System metrics report zero. They come from procfs, which Darwin does not have.
- Thread affinity requests are refused rather than approximated. Darwin's
  `THREAD_AFFINITY_POLICY` is advisory and takes no mask.
- There is no NAT, so the UE has no route to the internet. It is not needed for
  attach validation.
- An srsRAN process that fails fatally can hang in its own shutdown and ignore
  `SIGTERM`. The launcher escalates to `SIGKILL`; the cause is not yet known.
- Live radio operation is untested. Phase 2 is receive-only cell search.

## License

AGPL-3.0-or-later, matching srsRAN 4G upstream. The patches and shims are
derivative works of srsRAN and carry the same terms. `libsctp-compat` is a
separate project under LGPL-2.1-or-later, and usrsctp is BSD-2-Clause.

## Credits

srsRAN 4G is the work of [Software Radio Systems](https://www.srs.io/).

Port developed by Andrei Gosman across Cowork and Claude Code CLI sessions on
2026-09-03.
