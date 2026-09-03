# srsRAN 4G on macOS ARM64: session summary, 2026-09-03

Reference document for the sessions that follow: the osmo-bts cascade, the
upstream pull requests, and the kbwiki ingest. Written to be reused, so it
records what did not work as carefully as what did.

Counts in this document are the real ones. The srsRAN series is 23 patches, not
the 21 estimated mid-session; two more were needed after the first successful
attach.

---

## 1. Overview

One Claude Code session took srsRAN 4G 25.10 from "does not configure" to a
full LTE attach with a ping round trip, natively on Darwin 25.5 arm64 with
Apple clang 21.

Delivered:

- **usrsctp** master `fd070e0` built and installed with zero patches, two CMake
  flags standing in for what would otherwise be source changes.
- **libsctp-compat 0.1.0**, about 1150 lines, published at
  `github.com/AndreiGosman/libsctp-compat-macos-arm64` under LGPL-2.1-or-later.
  A Linux lksctp API over usrsctp with a real file descriptor bridge.
- **srsRAN 4G**, 23 numbered patches in `patches/srsRAN_4G-macos-arm64/`, each
  with a commit-style rationale. Six are not Darwin-specific and are candidates
  for upstream.
- **Three in-tree shims**: `timerfd_compat.h` (340 lines), `tun_compat.h` (188),
  `unix_socket_compat.h` (77), plus `endian_compat.h` (42).
- **`linux/*` uapi headers** as a small reproducible project in
  `src/linux-compat-headers/`, 202 lines across eight headers.
- **Phase 1 validated**: attach completes, UE gets 172.16.0.2, ping to the SGi
  address returns with no loss at 23 to 42 ms.

### The path a user-plane packet takes

```
  macOS kernel  (ping, source 172.16.0.2)
        |  route: 172.16.0.1 -> utun7   (deliberately crossed)
        v
  utun7  ............ PF_SYSTEM control socket, kernel-assigned name
        |  4-byte AF prefix stripped by srsran_tun_read
        v
  srsue  GW thread  ->  PDCP / RLC / MAC / PHY
        |
        v
  ZeroMQ  tcp://*:2101  ->  tcp://localhost:2101      (uplink IQ samples)
        |                    base_srate 11.52 MHz, decimated x2 to 5.76 MHz
        v
  srsenb PHY / MAC / RLC / PDCP  ->  GTP-U
        |  UDP 127.0.1.1:2152 -> 127.0.1.100:2152
        v
  srsepc SPGW  ->  SGi
        |  4-byte AF prefix added by srsran_tun_write
        v
  utun6  (172.16.0.1)
        |
        v
  macOS kernel  (ICMP echo reply, then the same path in reverse:
                 route 172.16.0.2 -> utun6)

  Control plane, established first and separately:
  srsenb S1AP  ->  libsctp-compat  ->  usrsctp  ->  UDP encapsulation
                   127.0.0.1:9900  ->  127.0.0.1:9899  ->  srsepc MME
```

Two details in that diagram matter and are not obvious. The routes are crossed
on purpose, because both tunnel addresses are local to one machine and without
the crossing the kernel answers on the loopback and proves nothing. And S1AP
does not travel on the loopback aliases the GTP-U planes use, because usrsctp
refuses traffic addressed to them.

---

## 2. Timeline, in the order it actually happened

**usrsctp build.** Low effort. Configured, compiled and installed clean under
its own `-Werror -Wall -Wextra -pedantic` with Apple clang 21. Zero patches.
`CMAKE_POLICY_VERSION_MINIMUM=3.5` because CMake 4 refuses the declared
minimum, and `sctp_build_shared_lib=ON` because the default is a static archive.

**libsctp-compat, first write.** High effort, about 1000 lines in one pass.
The design question was settled by grepping srsRAN rather than by assumption:
only three real lksctp functions are used, and the handover's list of nine was
wrong. The bridge is one AF_UNIX SOCK_DGRAM socketpair per SCTP socket, with
the usrsctp receive callback framing each message into it. Single-process tests
passed immediately.

**Two-process test, and three bugs.** Medium effort, very high value. Writing a
server and client as separate processes in the shape S1AP uses found three
faults at once, none of which a single-process test can reach: two processes
cannot share a UDP encapsulation port; `usrsctp_init` returns void so that
failure is silent; and `connect()` on a one-to-many socket returns once the
INIT is queued, so it reports success with no peer. Fixed by asymmetric
encapsulation ports, a port pre-check that refuses with an explanation, and
documentation of the connect semantics.

**srsRAN first configure.** Blocked on SCTP only. With the shim installed it
configured, then the build produced 452 errors.

**The ARM flag fix.** Low effort, and the root cause was not what the handover
said. `CMAKE_SYSTEM_PROCESSOR` is `arm64` on Darwin and `aarch64` on Linux, and
the guard tests `MATCHES "arm"`, a substring match. It hits `arm64` and misses
`aarch64`, which is why only Darwin sees it. The same asymmetry meant
`HAVE_NEONv8` was never defined on Darwin, so the 32-bit NEON paths were being
compiled. Both fixed by naming the 64-bit strings explicitly.

**The seven mechanical fixes, plus five more that appeared.** Medium effort
overall, each individually small. Two of the seven changed shape after the
grep the user asked for: `sys/sysinfo.h` turned out to be an unused include
whose real Linux dependency is procfs, and `endian.h` was unused in the file
that included it while two other files needed the macros without including
anything. The five that appeared during the work were mbedtls 4 removing the
headers srsRAN wants, `struct udphdr` field names, CPU affinity,
`RUSAGE_THREAD`, and the bundled fmt being shadowed.

**utun.** High effort, the largest single piece after libsctp-compat. Chosen
shape was `linux/*` headers in the shared prefix plus in-tree code, over a
separate interposing library. Framing verified in isolation before integration.

**Phase 1 iterations.** The long tail, and where most of the elapsed time went.
Eight distinct blockers after the build was clean, listed in section 7.

---

## 3. Patches

### srsRAN 4G, `patches/srsRAN_4G-macos-arm64/`

Six are marked **UPSTREAM**. They fix real defects on platforms other than
macOS and should go as separate pull requests, each argued on the platform it
actually affects, with no mention of macOS where macOS is only how the bug was
found.

| # | Title | Root cause | Fix | Upstream | Validated by |
|---|---|---|---|---|---|
| 001 | 32-bit ARM flags on 64-bit ARM | `MATCHES "arm"` is a substring test: true for `arm64`, false for `aarch64`. Also gates `HAVE_NEONv8` off on Darwin | Name the 64-bit processor strings explicitly, in both places | **yes**, any platform reporting arm64 | Flags gone from the compile line, `HAVE_NEONv8` now defined |
| 002 | No timerfd on Darwin | `timerfd_create` and `struct itimerspec` do not exist | kqueue as the timing engine, a pipe as the descriptor, one pump thread | no | Isolated test: periodic through `read()`, one-shot through `poll()`, disarm, `gettime` |
| 003 | Bundled fmt shadowed | `format.cc` includes `"fmt/format-inl.h"`, which does not resolve next to the file and falls through to the `-I` list, where a system fmt sits first | `include_directories(BEFORE ...)` | **yes**, any system with fmt on an explicit include path | About 100 errors naming fmt 8 symbols disappeared |
| 004 | `pthread_setname_np` signature | Linux names any thread, Darwin only the calling one and caps at 64 bytes | Wrapper, both call sites name the calling thread anyway | no | Compiles and runs |
| 005 | `asm/hwcap.h` | `getauxval` and the auxiliary vector are Linux only. Exposed by 001 enabling NEONv8 | Guard, and report neon unconditionally since ARMv8 mandates it | no | Compiles, correct ISA reported |
| 006 | `sys/sysinfo.h` | The include is unused. The real Linux dependency is procfs | Guard the include, document that metrics read zero on Darwin | no | Compiles; metrics honestly report zero rather than wrong values |
| 007 | Unused `endian.h` | Left-over include in a file that uses no byte-order macro | Guard | no | Compiles |
| 008 | `pthread_t` narrowing cast | `pthread_t` is an integer on Linux and a pointer on Darwin | Cast through `uintptr_t` | no | Compiles; trace ids still unique enough |
| 009 | `steady_clock::to_time_t` | libstdc++ aliases `high_resolution_clock` to `system_clock`, libc++ to `steady_clock`, which has no epoch | Sample both clocks and carry the offset | no | Timestamps correct in the logs |
| 010 | `template` keyword with no argument list | The disambiguator is only allowed before a template-id. Six sites, argument deduction makes it unnecessary | Delete the keyword | **yes**, the code is ill-formed, clang 21 merely enforces it | 133 errors from six lines disappeared |
| 011 | `struct udphdr` field names | Same layout, Linux uses `source`/`dest`/`len`/`check`, BSD uses `uh_*` | Declare a local header of the same layout, rather than defining `len` and `check` globally | no | pcap writing compiles |
| 012 | CPU affinity | `cpu_set_t` and `pthread_*affinity_np` are Linux extensions with no mask-taking equivalent on Darwin | Refuse the request rather than approximate it | no | Compiles; a caller asking for a core is not told it succeeded |
| 013 | `RUSAGE_THREAD` | Darwin accounts per process | Fall back to `RUSAGE_SELF`, document the overcount | no | Benchmark compiles |
| 014 | mbedtls headers from the wrong version | Consumers add `SEC_INCLUDE_DIRS` after the inherited paths, so a newer mbedtls elsewhere wins. mbedtls 4 hides `mbedtls_md_hmac` behind a private-identifier guard | `include_directories(BEFORE ...)` | **yes**, same shape as 003 | `ssl.h` compiles against the 3.x library actually linked |
| 015 | Missing byte-order macros | `pdu.cc` and `mac_sch_pdu_nr.cc` use `htole*` with nothing declaring them; on glibc they arrive transitively | In-tree header over `OSByteOrder.h` | no | Compiles |
| 016 | `__GLIBC_PREREQ` unguarded | A glibc-only macro used bare. An undefined function-like macro in `#if` is a parse error, not a false | Nested `#ifdef` | **yes**, musl breaks the same way | `ipv6.h` compiles |
| 017 | Non-portable member spellings | `ifr_ifrn.ifrn_name`, `ifr_netmask`, `in6_u.u6_addr8` are glibc spellings with portable equivalents that mean the same thing | Use `ifr_name`, `ifr_addr`, `s6_addr` | **yes**, no behaviour change on Linux | Compiles on Darwin, semantics identical |
| 018 | No TUN device | Darwin has utun, which names itself and prefixes every packet with four bytes | `tun_compat.h`, warning on the name substitution, `readv`/`writev` framing, netns and IPv6 refused explicitly | no | Isolated test: five packets both families, prefix verified on the wire |
| 019 | C++ standard pinned to 14 | UHD 4.7 and later use `std::is_same_v` in public headers. A command-line `-std` loses to the pinned one appended after it | Cache variable, default unchanged | **yes**, future-proofing against any recent UHD | Builds against UHD 4.10 |
| 020 | Scheduling calls in examples | `sched_setscheduler` and affinity, Linux only | Guard, refuse affinity rather than ignore it | no | Compiles |
| 021 | RF plugins never load | The plugin table names them with a `.so` suffix, Darwin builds `.dylib`, so every backend including ZeroMQ was skipped at start-up | Platform-selected suffix | no | All four plugins load |
| 022 | S11 abstract UNIX socket | `sun_path[0] = '\0'` is the Linux abstract namespace. Darwin reads that as an empty path | Helper: abstract on Linux, a real file elsewhere, unlink before bind, carry the address length | no | EPC reaches `MME S11 Initialized` |
| 023 | SGi read bypasses the tun helper, and an uninitialised peer address | `read(sgi, ...)` on a local variable escaped the earlier conversion, leaving the four-byte prefix in the buffer. Separately `SIOCSIFADDR` sets only the local end of a point-to-point interface | Route the read through `srsran_tun_read`; clear the peer address explicitly | no | `IPv6 not supported yet` gone; ping returns |

### usrsctp, `patches/usrsctp-macos-arm64/`

Empty by design. Upstream master builds clean on Darwin 25.5 arm64. Two CMake
flags replace what would otherwise be patches:
`CMAKE_POLICY_VERSION_MINIMUM=3.5` and `sctp_build_shared_lib=ON`. Recorded in
the directory's README and in `scripts/install_usrsctp.sh`.

### libsctp-compat

Not a patch series. Written here, so the history is its own commits:

| Commit | What it fixed |
|---|---|
| `4bb381e` | Initial release |
| `a3f270c` | Two claims corrected after checking: the free helpers return `int` not `void`, and the default-peer fallback does not "restore Linux behaviour" because RFC 6458 sides with usrsctp. Checking also exposed a real defect: with two associations the fallback would have sent to the wrong peer |
| `37926e2` | Two processes on one host, and a port check so a conflict is reported instead of running with no transport |
| `ca0aa2f` | Recorded that usrsctp drops traffic addressed to a loopback alias |
| `a3c177d` | A received `sctp_sndrcvinfo` is now safe to hand back to `sctp_send` |
| `167111e` | Moved the loopback test off the conventional encapsulation port |

---

## 4. Shim architecture

### libsctp-compat

**Interface.** Drop-in `netinet/sctp.h` with the Linux lksctp types and
constants, and the functions `sctp_sendmsg`, `sctp_send`, `sctp_recvmsg`,
`sctp_bindx`, `sctp_connectx`, `sctp_getpaddrs`, `sctp_freepaddrs`,
`sctp_getladdrs`, `sctp_freeladdrs`, `sctp_opt_info`, `sctp_peeloff`. Ten libc
calls are interposed by link order, not by `DYLD_INSERT_LIBRARIES`: `socket`,
`bind`, `listen`, `connect`, `close`, `setsockopt`, `getsockopt`,
`getsockname`, `getpeername`, `shutdown`. Each checks whether the descriptor is
ours and hands everything else straight back to libc, so UDP and TCP in the
same process are untouched. The two-level namespace is also what stops
usrsctp's own socket calls from recursing into us.

**Backend.** usrsctp, with one AF_UNIX SOCK_DGRAM socketpair per SCTP socket.
The receive callback frames each message with its flags, sender address and
`sctp_sndrcvinfo` into one datagram, so `read()`, `recv()` and `poll()` all
work on an ordinary descriptor and message boundaries survive.
`SO_RCVTIMEO` is applied to the socketpair rather than the usrsctp socket,
because that is what a receive loop waiting for `EAGAIN` actually reads from.

**Tests.** Four. A link and error-path test, a single-process loopback test, a
C++ usage test that runs srsRAN's three socket-option helpers verbatim, and a
two-process test that re-executes itself for the client role.

**Bugs the tests caught.** The link test caught `usrsctp_freepaddrs(NULL)`
aborting the process. The two-process test caught all three transport faults
and, later, both faults in the reply path. None of the five is reachable with
both ends in one address space.

**Known limitations.** Traffic addressed to a loopback alias is dropped by
usrsctp; 127.0.0.1 and real interface addresses work. `sctp_peeloff` returns
`EOPNOTSUPP` rather than being half-implemented. The `timetolive` argument of
`sctp_sendmsg` is logged rather than forwarded. Messages over 256 KB are
dropped by the pump and logged. Two processes need distinct encapsulation
ports. `connect()` on a one-to-many socket returns before the association is
up, which is what the specification says but not what Linux callers expect.

### timerfd_compat

**Interface.** `timerfd_create`, `timerfd_settime`, `timerfd_gettime`, plus
`struct itimerspec` and the `TFD_*` constants, which Darwin also lacks. The
descriptor works with plain `read()` and `close()`.

**Backend.** kqueue `EVFILT_TIMER` drives the timing, one background thread
waits on a shared kqueue, and each timer hands the caller the read end of a
pipe the thread writes the expiration count into. A kqueue descriptor cannot
be `read()`, which is what `threads.h` does, so kqueue alone could not be the
whole answer.

**Bug the test caught.** Slot recovery. When the caller closes the descriptor,
the internal entry stayed marked in use and the write end stayed open, so the
next `timerfd_create` got the same descriptor number, matched the stale entry,
and the thread wrote into a dead pipe. The periodic path worked and the
one-shot path, created after a close, did not. Dead entries are now reclaimed
at allocation.

**Known limitations.** Linux coalesces expirations into one `read()`; here each
wakeup writes its own count, so a slow reader gets several eight-byte values
whose sum is the same. Sixty-four timers per translation unit.

### tun_compat

**Interface.** `srsran_tun_open(requested_name, actual_name, len)`,
`srsran_tun_read`, `srsran_tun_write`. On Linux it is the classic
`open("/dev/net/tun")` plus `TUNSETIFF` and plain read and write, so both
platforms go through one API.

**Backend.** utun: a `PF_SYSTEM` control socket, `CTLIOCGINFO`, `connect` with
`sockaddr_ctl` and unit zero, and `UTUN_OPT_IFNAME` to learn the assigned name.
The four-byte address family prefix is added and stripped with `writev` and
`readv`, so no copy is introduced and callers keep handling bare IP packets.

**Bugs found by testing and by the run.** The isolated test confirmed the
framing before integration. The run then found what the test could not: one
read path in `spgw.cc` still called `read()` directly, because the descriptor
arrives there in a local variable named `sgi` rather than the member name the
other call sites use. The lesson is to audit by descriptor role, not by
variable name.

**Known limitations.** The kernel names the interface, so a configured name is
reported and ignored. Network namespaces have no equivalent and are refused.
Assigning an IPv6 address needs `SIOCAIFADDR_IN6` and is not implemented, so
IPv6 bearers are refused rather than silently failing. macOS installs no route
for a utun, so routes are the caller's problem.

---

## 5. Working configuration

All files live in `~/sdr-lab/etc/srsran/`. What follows is the reasoning; the
files themselves carry the same notes as comments.

**epc.conf.** MCC 001, MNC 01. `mme_bind_addr = 127.0.0.1`, because usrsctp
will not accept S1AP addressed to a loopback alias. `gtpu_bind_addr =
127.0.1.100`, which is a loopback alias and works because GTP-U is plain UDP;
it needs its own address because srsenb binds port 2152 as well. HSS database
at `~/sdr-lab/var/user_db.csv`. SGi 172.16.0.1, DNS 8.8.8.8, TAC 0x0007,
`sgi_if_name` present but not honoured.

**enb.conf.** eNB id 0x19B, `mme_addr` and `s1c_bind_addr` on 127.0.0.1,
`gtp_bind_addr = 127.0.1.1`. 25 PRB, band 3, EARFCN 1300 which is 1815.0 MHz
downlink. No `srate` key: the PHY derives 5.76 MHz from the cell width and the
radio decimates from the link rate. `rr.conf` carries `cell_id = 0x01`,
`tac = 0x0007` and the EARFCN.

**ue.conf.** Milenage rather than XOR, because a random OPc is only meaningful
with milenage and it exercises more of the stack. K and OPc are generated per
lab and match `user_db.csv` exactly. IMSI 001010000000001, IMEI
353490069873310.

**user_db.csv.** Format is
`Name,Auth,IMSI,Key,OP_Type,OP/OPc,AMF,SQN,QCI,IP_alloc`. The draft supplied
mid-session had `dyn` in the `OP_Type` position and an SQN value in the
`IP_alloc` position, with a 33-character AMF; the HSS would have rejected it.

**ZeroMQ ports.** Crossed, single antenna. eNB transmits on 2000 and listens on
2101, the UE transmits on 2101 and listens on 2000, both at
`base_srate=11.52e6`. Ports 2001 and 2100 are unused and would only be needed
for a second antenna.

**Critical environment.**

```sh
# One encapsulation port per process, each pointing at the other.
# Two processes on one host cannot share one.
srsepc:  LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9899  LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9900
srsenb:  LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900  LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899

# Loopback aliases, needed only by the two GTP-U planes. Not persistent.
sudo ifconfig lo0 alias 127.0.1.100 up
sudo ifconfig lo0 alias 127.0.1.1 up

# Routes, deliberately crossed. Both addresses are local to this machine, so
# without this a ping is answered on the loopback and proves nothing.
sudo route -n add -host 172.16.0.1 -interface utun7   # SGi reached via the UE tunnel
sudo route -n add -host 172.16.0.2 -interface utun6   # UE reached via the SGi tunnel

# Log to stdout. srslog buffers a file log and flushes at exit, so a running
# process appears to write nothing at all.
[log] filename = stdout
```

**`scripts/run-faza1.sh`** does all of it as root: adds the aliases
idempotently, kills leftovers with SIGTERM then SIGKILL, refuses to start if a
port is still held and names the holder, then starts each component in a tmux
pane and waits for a marker before the next. The markers, taken from the source
rather than guessed, are `SP-GW Initialized`, `S1Setup procedure completed
successfully` and `Network attach successful`. At the end it reads the
kernel-assigned utun names out of the logs, adds the routes and prints the ping
command.

---

## 6. Runtime validation

**S1AP setup.** eNB side:

```
[S1AP] SCTP socket established with MME
[S1AP] Proc "MME Connection" - S1 setup request sent. Waiting for response.
[S1AP] Proc "MME Connection" - S1Setup procedure completed successfully
```

EPC side, 0.6 ms later:

```
Received S1 Setup Request.
S1 Setup Request - eNB Name: srsenb01, eNB id: 0x19b
S1 Setup Request - MCC:001, MNC:01
S1 Setup Request - TAC 7, B-PLMN 0xf110
[S1AP] Adding new eNB context. eNB ID 411
Sending S1 Setup Response
```

**Attach.** UE side:

```
[NAS] Received Authentication Request
[NAS] Sending Authentication Response
[NAS] Received Security Mode Command ksi: 0, eea: EEA0, eia: 128-EIA1
[NAS] Sending Security Mode Complete
[RRC] Received Security Mode Command eea: EEA0, eia: 128-EIA2
[NAS] Received Attach Accept
[NAS] Network attach successful. APN: srsapn, IP: 172.16.0.2
[NAS] Sending Attach Complete
```

EPC side:

```
[SPGW GTPC] SPGW Received Create Session Request
[SPGW GTPC] Sending Create Session Response
[MME GTPC]  Create Session Response -- SPGW S1-U Address: 127.0.1.100
[NAS]       Attach Accept -- MCC 0xf001, MNC 0xff01
[S1AP]      UL NAS: Received Attach Complete
[SPGW GTPC] IMSI: 001010000000001, UE IP: 172.16.0.2
[GTPU]      Downlink eNB addr 127.0.1.1, U-TEID 0x1
```

**Ping.**

```
PING 172.16.0.1 (172.16.0.1): 56 data bytes
64 bytes from 172.16.0.1: icmp_seq=0 ttl=64 time=38.474 ms
64 bytes from 172.16.0.1: icmp_seq=1 ttl=64 time=25.100 ms
64 bytes from 172.16.0.1: icmp_seq=2 ttl=64 time=31.506 ms
64 bytes from 172.16.0.1: icmp_seq=3 ttl=64 time=36.701 ms
64 bytes from 172.16.0.1: icmp_seq=4 ttl=64 time=22.985 ms

5 packets transmitted, 5 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 22.985/30.953/38.474/6.126 ms
```

Corroborated in the UE log, which is what rules out a loopback shortcut:

```
[GW] TX PDU
[GW] RX PDU. Stack latency: 4 us
```

**Reading the 30 ms.** This is not a slow network. The packet crosses a
complete LTE stack twice. Each direction pays a scheduling request, an uplink
grant, HARQ, and the ZeroMQ transport carrying 11.52 Msps between two processes
that must stay in step. The 4 microsecond stack latency the UE reports is the
time inside srsue itself, so nearly all of the 30 ms is the radio protocol
doing what a radio protocol does. A first ping after an idle period can time
out legitimately, because the UE has released its bearer and has to request
service again; the log says `UE does not have service, waiting for NAS service
request` when that happens.

---

## 7. Bugs and lessons

### Include order shadowing on Homebrew

Three times in one session: the bundled fmt, mbedtls, and earlier the SCTP
header itself.

*Symptom.* Errors naming symbols that do not exist in the version the tree
expects. For fmt: `no member named 'basic_data'`, `no type named 'float_specs'`.
For mbedtls: `use of undeclared identifier 'mbedtls_md_hmac'` against a library
that exports it.

*Real cause.* `-I/opt/homebrew/include` arrives before the tree's own include
directory, so a quoted include that does not resolve next to the source file
falls through to the system copy. mbedtls 4 had additionally moved the symbol
behind `MBEDTLS_DECLARE_PRIVATE_IDENTIFIERS`.

*Fix.* `include_directories(BEFORE ...)`. And note that an incremental `cmake ..`
does not reorder an existing cache; a clean reconfigure was needed before the
change took effect, which cost an extra debugging round.

*Generalisation.* On macOS with Homebrew, assume any bundled or version-pinned
dependency is shadowed until proven otherwise. Check `flags.make` for the real
order rather than reasoning about what CMake should have done.

### `arm` matching `arm64` but not `aarch64`

*Symptom.* `unsupported option '-mfloat-abi='`, only on Darwin.

*Real cause.* Substring matching in CMake. `arm64` contains `arm`; `aarch64`
does not. The first hypothesis, that this is a Darwin quirk, was wrong; it is a
latent bug that Linux happens not to trip.

*Generalisation.* When a bug appears on one platform only, ask what the other
platform's string looks like before concluding the platform is at fault.

### Shared library extension in a plugin loader

*Symptom.* `Skipping RF plugin libsrsran_rf_uhd.so: no such file`, for all four
backends, leaving no radio at all including ZeroMQ.

*Real cause.* `rf_dev.h` names the plugins literally with a `.so` suffix.

*Generalisation.* Any dlopen by literal filename is a portability bug. Grep for
`".so"` early in a port.

### BCD in logs

*Symptom.* `HSS Initialized. MCC: 61441, MNC: 65281` and `MCC: 0xf001, MNC:
0xff01`, which look like corruption.

*Real cause.* Neither. That is the BCD encoding of 001 and 01 with the standard
filler nibbles. No action needed.

*Generalisation.* In telecom logs, check the encoding before treating an odd
number as a bug.

### `source` in a pipeline loses the environment

*Symptom.* `pkg-config --exists sctp` reported the shim missing, moments after
it had been installed and verified.

*Real cause.* `source env.sh 2>&1 | head -1`. In zsh a pipeline runs in a
subshell, so the exported variables never reached the parent. Self-inflicted,
and it cost a diagnostic round.

*Generalisation.* Never pipe `source`. If output needs trimming, redirect to a
file or discard it.

### One UDP encapsulation port per process

*Symptom.* Client reports the association established and the send successful.
Server receives nothing at all.

*Real cause.* Two processes cannot bind the same tunnelling port. The second
`usrsctp_init` fails, returns void, and the stack carries on with no transport.
`connect()` on a one-to-many socket returns once the INIT is queued, so it also
reported success.

*Fix.* Asymmetric ports, plus a pre-check that refuses with an explanation.
That message later identified a stale-process port conflict immediately, which
would otherwise have looked like a network fault.

*Generalisation.* A void-returning init function is a place to add your own
check. And a successful `connect()` on a one-to-many SCTP socket is not
evidence of a peer.

### utun names itself

*Symptom.* Configured `tun_srsue` and `srs_spgw_sgi` never appear.

*Real cause.* The kernel assigns `utunN` for the first free N. It was `utun6`
and `utun7` here because six were already in use by VPN software and Private
Relay, and the number varies between runs.

*Fix.* Report the substitution in the log and on the console, and have scripts
read the real name from the log rather than the configuration.

### macOS installs no route for a utun

*Symptom.* `ping: sendto: No route to host`, even with the interface forced.

*Real cause.* Two things at once. `SIOCSIFADDR` sets only the local end of a
point-to-point interface, so the peer address kept uninitialised memory and
appeared as `20.18.25.0`. And BSD does not install a subnet route for a
point-to-point interface from the netmask alone.

*Fix.* Clear the peer address in code, add explicit host routes in the
launcher. The routes are crossed because both addresses are local to one
machine. On Linux the tutorial avoids the whole question with network
namespaces, which macOS does not have.

### Abstract UNIX sockets

*Symptom.* `Error binding UNIX socket. Error No such file or directory`, from
the MME's S11 interface, inside a single process.

*Real cause.* `sun_path[0] = '\0'` selects the Linux abstract namespace. Darwin
has none, so the path is empty. The parent directory was never the issue.

*Fix.* Abstract on Linux, a real file elsewhere, unlinked before bind because a
socket left by a previous run is otherwise rejected as in use, and the address
length carried alongside the address because a filesystem address is shorter
than the struct.

### Receive flags are not send flags

*Symptom.* The eNB sends `s1SetupRequest`, the MME logs `Sending S1 Setup
Response` with no error, the eNB waits forever.

*Real cause.* usrsctp reports the DATA chunk's fragmentation bits in
`rcv_flags`, shifted into the high byte, so a complete message arrives as
`0x0300`. The send side reads that byte as `SCTP_EOF | SCTP_ABORT`. The shim
copied the field through unchanged, so every reply ordered the association shut
down and aborted, while reporting success.

*Fix.* Report only the unordered indication, which is what Linux reports.

*Generalisation.* When two structures share a field name across a receive and a
send API, check that the value space is the same before passing it through. It
usually is not.

### Sending by association id alone

*Symptom.* Same as above, and it survived the first fix.

*Real cause.* With UDP encapsulation, usrsctp takes the encapsulation port from
the association rather than the socket, and an association accepted from an
incoming INIT does not carry one. The reply left as bare SCTP and was lost.

*Fix.* Look up the peer address and supply it, clearing the association id so
usrsctp resolves by address.

### The one read path that got away

*Symptom.* `IPv6 not supported yet` for every uplink packet, while the uplink
itself worked.

*Real cause.* `read(sgi, ...)` in `spgw.cc` never went through the tun helper,
so the four-byte prefix stayed in the buffer and the version nibble was read
out of it. It escaped the earlier conversion because the descriptor arrives
there in a local variable named `sgi`, and the search had been for the member
names `m_sgi` and `tun_fd`.

*Generalisation.* Audit by descriptor role, not by variable name. After
converting an I/O path, grep for every remaining `read(` and `write(` on any
descriptor that could be that device.

### Multi-process testing is not optional

The single-process test suite passed cleanly throughout, while five separate
faults sat in the transport and reply paths. Every one needed two processes to
reach. This is now a standing rule: each shim gets a two-role binary that
mirrors how the target software uses the API, run as separate processes, and
checks the peer's observable state rather than local return codes.

### A process that fails fatally may not exit

`srsenb` failed to open its radio, then hung in its own shutdown and ignored
`SIGTERM`, holding two ports. The next run failed for an unrelated-looking
reason. The launcher now escalates to `SIGKILL`. The underlying cause was not
investigated and is still open.

---

## 8. Design decisions and the arguments against them

**Tier 2 shim rather than a link-satisfying stub.** A stub would have unblocked
the srsRAN build in hours, and the immediate need was only to satisfy the
linker for cell search. Tier 2 was chosen because the cascade needs real SCTP
for S1AP and later for M3UA in Osmocom, and because a stub would have to be
thrown away. The cost was real: five of the session's hardest bugs live in
that code. The benefit is also real: Phase 1 would not exist without it.

**kqueue plus a pipe, rather than `pthread_cond_timedwait`.** The condition
variable is less code and would have served `threads.h`, which only ever
`read()`s its timer. It would not have served `nas.cc`, which hands the
descriptor to the MME event loop and needs it pollable. kqueue alone would not
have served `threads.h`, because a kqueue descriptor cannot be read. The pipe
is what makes one mechanism cover both.

**`linux/*` headers in the shared prefix, but `tun_compat.h` in-tree.** Putting
a generic header on a shared include path is the shadowing anti-pattern that
bit this session three times, so the rule looks inconsistent. It is not: no
macOS component ships a `linux/` directory, so that namespace cannot collide
by construction. `endian.h` would have collided, which is why it went in-tree
instead.

**Delete the `template` keyword rather than suppress the diagnostic.**
`-Wno-missing-template-arg-list-after-template-kw` exists and was verified to
be accepted. It was rejected because the code is ill-formed: the disambiguator
requires a template-id and there is none. Suppressing it would hide a real
defect and leave the tree broken for the next compiler.

**No upstream reports for the lksctp and usrsctp divergences.** Both candidates
were checked and neither is a defect. `sctp_freepaddrs` is a verbatim copy of
the FreeBSD libc function, and the `ENOENT` on an unaddressed one-to-many send
is what RFC 6458 section 3.1.3 requires. Filing them would have been wrong. The
compatibility analysis in the README is the contribution instead.

**In-tree utun rather than a separate interposing library.** A `libtun-compat`
would have needed no srsRAN patches and would be reusable. It was rejected
because the cascade is dominated by the control plane, TUN handling is specific
to srsRAN, the reuse is speculative, and interposing `read` and `write` puts a
lookup on the user-plane hot path. The revisit condition is a second confirmed
project with heavy TUN use, not a hypothetical one.

**Milenage rather than XOR.** The supplied draft said XOR but also asked for a
random OPc, which only milenage uses. Milenage also exercises more of the
authentication path. One word in two files reverses this.

---

## 9. Remaining work, in priority order

1. **Publish the srsRAN fork.** `libsctp-compat` is already public with tag
   `v0.1.0`. `srsRAN-4G-macos-arm64` is not yet created; the 23 patches, the
   `linux/*` headers and this document's sections 5 and 10 are the material.

2. **Six upstream pull requests**, one per category, each argued on the
   platform it actually affects and not framed as macOS fixes: arm64 detection
   (001), bundled fmt priority (003), mbedtls priority (014), `__GLIBC_PREREQ`
   guard (016), portable `ifreq` and `in6_addr` spellings (017), selectable C++
   standard (019).

3. **Phase 2, live cell search** with the LibreSDR on EARFCN 1300. Receive
   only. Nothing transmits.

4. **osmo-bts and osmo-trx**, the next port in the cascade. It will exercise
   the SCTP shim harder than srsRAN does, and it uses timerfd through
   libosmocore, so `timerfd_compat` may need to become a shared library rather
   than an in-tree header.

5. **kbwiki ingest**: concepts, cases and decisions extracted from sections 4,
   7 and 8.

6. **Open question, not scheduled**: why an srsRAN process that fails fatally
   hangs in shutdown and ignores `SIGTERM`. It will be a nuisance in Phase 2.

7. **Phase 1.5, optional: `pf` NAT and IP forwarding for UE internet egress.**
   Needed only for a web navigation demo through the virtual UE, or a real
   end-to-end iperf3. It does not block Phase 2 cell search, osmo-bts, or the
   Faraday cage lab; all of those talk on their own internal networks.

---

## 10. Reproducing this from scratch

For a fresh Mac with Homebrew, or for future-me.

**1. Dependencies.**

```sh
brew install cmake pkg-config boost fftw zeromq uhd libconfig mbedtls@3 tmux
```

`mbedtls@3` specifically: mbedtls 4 removed `mbedtls/aes.h` and `mbedtls/md5.h`
and made `mbedtls_md_hmac` a private identifier.

**2. usrsctp.**

```sh
~/sdr-lab/scripts/install_usrsctp.sh
```

Clones, builds out of tree with the two flags, installs into
`~/sdr-lab/local`. No patches.

**3. libsctp-compat.**

```sh
git clone https://github.com/AndreiGosman/libsctp-compat-macos-arm64.git \
    ~/sdr-lab/src/libsctp-compat
cd ~/sdr-lab/src/libsctp-compat && mkdir build && cd build
cmake .. -DCMAKE_INSTALL_PREFIX=$HOME/sdr-lab/local -DCMAKE_BUILD_TYPE=Release
make -j$(sysctl -n hw.ncpu) && ctest --output-on-failure && make install
```

All four tests must pass before going further.

**4. The `linux/*` headers.**

```sh
~/sdr-lab/src/linux-compat-headers/install.sh
```

**5. srsRAN and the patches.**

```sh
git clone https://github.com/srsran/srsRAN_4G.git ~/sdr-lab/src/srsRAN_4G
cd ~/sdr-lab/src/srsRAN_4G
for p in ~/sdr-lab/patches/srsRAN_4G-macos-arm64/*.patch; do
  patch -p1 < "$p" || { echo "failed on $p"; break; }
done
```

**6. Configure and build.** Every flag here is load-bearing.

```sh
source ~/sdr-lab/env.sh
MB=$(brew --prefix mbedtls@3)
mkdir -p build && cd build
cmake .. \
  -DCMAKE_INSTALL_PREFIX=$HOME/sdr-lab/local \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="$MB" \
  -DSRSRAN_CXX_STANDARD=c++17 \
  -DCMAKE_INSTALL_RPATH="$HOME/sdr-lab/local/lib" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
  -DCMAKE_C_FLAGS="-I$HOME/sdr-lab/local/include" \
  -DCMAKE_CXX_FLAGS="-I$HOME/sdr-lab/local/include" \
  -DENABLE_WERROR=OFF -DENABLE_HARDSIM=OFF \
  -DENABLE_UHD=ON -DENABLE_ZEROMQ=ON \
  -DENABLE_SRSUE=ON -DENABLE_SRSENB=ON -DENABLE_SRSEPC=ON \
  -DENABLE_GUI=OFF -DENABLE_5GNR=OFF \
  -DENABLE_ALL_TEST=OFF -DBUILD_TESTS=OFF
make -j$(sysctl -n hw.ncpu) && make install
```

Why each of the non-obvious ones: `CMAKE_POLICY_VERSION_MINIMUM` because CMake
4 refuses the declared minimum. `SRSRAN_CXX_STANDARD=c++17` because UHD 4.7 and
later need it. `CMAKE_INSTALL_RPATH` because the installed binaries otherwise
carry no rpath and fail under `sudo`, which strips `DYLD_*` under SIP.
`ENABLE_WERROR=OFF` because Apple clang 21 is far newer than upstream CI.
`ENABLE_HARDSIM=OFF` because the PC/SC framework on macOS uses different types.
The two `-I` flags so `netinet/sctp.h` is found by targets that do not receive
`SCTP_INCLUDE_DIRS`.

Verify before running:

```sh
for b in srsue srsenb srsepc; do
  env -i HOME=$HOME ~/sdr-lab/local/bin/$b --help >/dev/null && echo "$b ok"
done
```

A clean environment is what `sudo` will give them. Testing only one binary is
how the missing rpath was missed the first time.

**7. Run Phase 1.**

```sh
sudo ~/sdr-lab/scripts/run-faza1.sh
```

**8. Verify.**

```sh
ping -c 5 172.16.0.1
```

Five packets, because the first can time out while the UE comes out of idle.
Expect no loss and 20 to 45 ms. Confirm it really traversed the stack:

```sh
grep -E "\[GW " ~/sdr-lab/logs/faza1-ue.log | tail -4   # TX PDU / RX PDU pairs
grep -c "IPv6 not supported" ~/sdr-lab/logs/faza1-epc.log   # must be 0
```
