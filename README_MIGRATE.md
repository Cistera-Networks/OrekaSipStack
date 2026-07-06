# OrekaSipStack — Migration Guide: Kernel 6.12 / AlmaLinux 10 (EL10)

**Branch**: `version/2.5`  
**Target**: Linux 6.12.0-124.21.1.el10_1.x86_64 (AlmaLinux 10, GCC 14.3.1)  
**Current baseline**: Ubuntu 18.04 / CentOS 5–7 era code, GCC with C++11  

---

## 1. Scope of Changes

| Area | Why It Matters |
|---|---|
| **autotools `configure.in` (×2)** | OS detection via `/etc/redhat-release` only handles EL6/EL7. EL10 is unrecognised → no TLS flags, wrong boost/speex paths. |
| **`VoIp.cpp` preprocessor branches** | `#ifdef CENTOS_5` guards the old `pcap_open_live()` path. EL10 won't define it — the modern `pcap_create`/`pcap_activate` path is taken, which is correct, but needs verification against libpcap 1.10+. |
| **Compiler (GCC 14.3.1)** | Far stricter than the GCC 7–9 era originally used. Expect new warnings-as-errors on C++11 code: `-Wdeprecated-copy`, `-Wformat-overflow`, `-Wmaybe-uninitialized`, `-Wstrict-aliasing`. |
| **libpcap ABI / behaviour** | Kernel 6.12 + libpcap ≥ 1.10 may change `TPACKET_V3` defaults, buffer-size limits, `SO_RCVBUF` maximums, and `pcap_set_buffer_size()` semantics. |
| **System libraries** | AlmaLinux 10 ships newer `boost`, `xerces-c`, `log4cxx`, `apr`, `openssl`. API breaks are unlikely but possible. |
| **Packaging** | The legacy `.deb` packaging under `distribution/` must be replaced or augmented with an RPM spec (`dnf` / `rpm` native to EL10). |
| **Docker** | `Dockerfile.orkaudio` is Ubuntu `focal` based; needs a parallel `Dockerfile.el10` or a multi-stage build that produces an EL10-compatible binary. |
| **Capabilities** | `check_pcap_capabilities()` in `VoIp.cpp` probes CAP_NET_RAW / CAP_NET_ADMIN. EL10's default capability bounding set may differ. |

---

## 2. Step-by-Step Checklist

### 2.1. OS Detection in `configure.in`

**Files**: `orkbasecxx/configure.in`, `orkaudio/configure.in`

Both files read `/etc/redhat-release` with hard-coded patterns for `release 6`, `release 7`. On AlmaLinux 10 the file contains something like:

```
AlmaLinux release 10.0 (Cerulean Leopard)
```

**What to do**:

1. **`orkbasecxx/configure.in`** (~lines 33–44):
   - The `release 7` test forces `boost_lib=/usr/lib64/static_libboost_system.a`. On EL10, boost is likely at `/usr/lib64/libboost_system.so` — verify and update the condition.
   - The `release 6` test adds `-DCENTOS_6 -D__STDC_CONSTANT_MACROS`. EL10 should **not** set those.
   - The `release 6` TLS exclusion guard must **not** exclude EL10 (TLS should be enabled).
   - Add an explicit EL10 path, or better, invert the logic so modern releases get sensible defaults.

2. **`orkaudio/configure.in`** (~lines 38–47):
   - The `release [67]` test selects `speex_lib=orkspeex` for EL6/EL7. EL10 likely wants the default `speex`.
   - Same TLS exclusion pattern — must not gate on EL10.
   - **New dependency**: AlmaLinux 10 may not ship `libunwind` or `libdw` in the same package names. Verify with `dnf provides`.

**Recommended approach**: Replace fragile `/etc/redhat-release` grepping with `pkg-config`-based checks or AC_TRY_COMPILE probes where possible. At minimum, add an `elif` for `release 1[0-9]` that sets modern defaults.

### 2.2. `CENTOS_5` Preprocessor Branches in `VoIp.cpp`

**File**: `orkaudio/audiocaptureplugins/voip/VoIp.cpp`

The `#ifdef CENTOS_5` guards (lines 1305, 1441, 1580, 1604, 1627, 1656) isolate the old `pcap_open_live()` code path. EL10 will **not** define `CENTOS_5`, so the modern path runs.

**What to verify**:
- `pcap_create()` + `pcap_activate()` + `pcap_set_buffer_size()` work correctly with kernel 6.12's AF_PACKET implementation.
- The `ActivatePcapHandle()` function sets `SO_RCVBUF = 8388608` (8 MB) unconditionally. Kernel 6.12's default `net.core.rmem_max` is typically 212992; `/proc/sys/net/core/rmem_max` must be raised or the setsockopt will silently clamp.
- `SetPcapSocketBufferSize()` (non-CENTOS_5 path) calls `pcap_set_buffer_size()` — on recent libpcap this maps to `TPACKET_V3` and may behave differently from `SO_RCVBUF` tuning.

**Action**: Build and run with `strace -e setsockopt` to confirm the buffer sizes actually applied. Consider adding an `EL10` or kernel-version runtime check in logging.

### 2.3. GCC 14.3.1 Compatibility

GCC 14 is much stricter. The codebase was written for GCC 4.x–9.x.

| Likely Issue | Mitigation |
|---|---|
| `-Wdeprecated-copy` on implicit copy constructors | Add `= default` or explicitly declare |
| `-Wformat-overflow` / `-Wstringop-overflow` on CStdString Format calls | Review buffer sizes; some `Format()` calls use fixed-size internal buffers |
| `-Wmaybe-uninitialized` | GCC 14 is more aggressive; may need `= {}` initialisation |
| `-Wstrict-aliasing` violations (the Ethernet/IP header structs overlay packet buffers via pointer casts) | Already wrapped in `#pragma pack` but may trigger warnings; test with `-fno-strict-aliasing` as a fallback |
| `-Wimplicit-function-declaration` (C99 removal in GCC 14) | Check for any C files using undeclared functions |
| C++11 mode (`-std=c++11`) | GCC 14 still supports this; no change needed |

**Action**: First build with `-Wno-error` to catalog warnings, then fix incrementally.

### 2.4. Dependency Mapping (Ubuntu → AlmaLinux 10)

The `Dockerfile.orkaudio` installs these Ubuntu packages. Here's the EL10 equivalent:

| Ubuntu (focal) | AlmaLinux 10 / EPEL 10 |
|---|---|
| `build-essential` | `dnf groupinstall "Development Tools"` |
| `libtool automake` | `libtool automake autoconf` |
| `libboost-all-dev` | `boost-devel` (or `boost-*` subpackages) |
| `libpcap-dev` | `libpcap-devel` |
| `libsndfile1-dev` | `libsndfile-devel` |
| `libapr1-dev` | `apr-devel` |
| `libspeex-dev` | `speex-devel` |
| `liblog4cxx-dev` | `log4cxx-devel` (likely in EPEL) |
| `libace-dev` | `ace-devel` (likely in EPEL) |
| `libcap-dev` | `libcap-devel` |
| `libopus-dev` | `opus-devel` |
| `libxerces-c3-dev` | `xerces-c-devel` |
| `libssl-dev` | `openssl-devel` |
| `cmake` | `cmake` |
| `libdw-dev` | `elfutils-devel` (provides libdw) |
| `liblzma-dev` | `xz-devel` |
| `libunwind-dev` | `libunwind-devel` |

**Note**: Several packages (`log4cxx`, `ace`, `libunwind`) may require **EPEL 10** or **CodeReady Builder (CRB)** / **Powertools** repo. Enable them:
```bash
dnf install epel-release
dnf config-manager --set-enabled crb   # CodeReady Builder
```

### 2.5. Build Dependencies From Source

The `Dockerfile.orkaudio` builds several libraries from source:

| Library | Notes for EL10 |
|---|---|
| **SILK** | The `gaozehua/SILKCodec` repo compiles with `CFLAGS=-fPIC`. GCC 14 may need `-std=gnu99` or `-Wno-implicit-int`. |
| **Opus 1.2.1** | Should build fine; consider upgrading to a newer Opus release. |
| **bcg729 (G.729)** | CMake-based; should build fine with GCC 14. |
| **backward-cpp** | Header-only stack trace library; may need `-lbfd` or different link flags for binutils 2.41. |

### 2.6. Kernel 6.12 Specifics

#### 2.6.1. AF_PACKET / libpcap

- Kernel 6.12 supports `TPACKET_V3` as the default for memory-mapped packet capture. libpcap ≥ 1.10 uses it by default when available.
- `TPACKET_V3` uses block-based buffering rather than frame-based; the `pcap_set_buffer_size()` semantics change accordingly.
- **Fanout**: If multiple orkaudio instances run, check that `PACKET_FANOUT` / `setsockopt(PACKET_RX_RING)` behave as expected.

#### 2.6.2. SO_RCVBUF Limits

The hardcoded `8388608` (8 MB) in `ActivatePcapHandle()` exceeds the default `net.core.rmem_max` (typically 208 KB). On EL10, configure:
```bash
sysctl -w net.core.rmem_max=16777216
sysctl -w net.core.rmem_default=16777216
```
Or add to `/etc/sysctl.d/90-orkaudio.conf`.

#### 2.6.3. Network Namespace / Containers

If running in a container with `network_mode: host`, verify that `CAP_NET_RAW` and `CAP_NET_ADMIN` are in the bounding set. Podman (default on EL10) has different default capabilities than Docker.

### 2.7. Packaging (RPM)

The `distribution/orkaudio-linux-deb-binary/` tree is Debian-only. For EL10:

1. Create an **RPM `.spec`** file (or use `checkinstall` as a quick prototype).
2. The binary payload is:
   - `/usr/sbin/orkaudio`
   - `/usr/lib/liborkbase.*`
   - `/usr/lib/orkaudio/plugins/*.so`
   - `/usr/lib/libvoip.so`, `libgenerator.so`
   - `/etc/orkaudio/config.xml`, `logging.properties`
3. Runtime dependencies: `libpcap`, `libsndfile`, `libapr`, `libspeex`, `liblog4cxx`, `libace`, `libopus`, `libxerces-c`, `openssl-libs`, `elfutils-libs`.

### 2.8. Docker Image for EL10

**Recommended**: Create `distribution/docker/Dockerfile.orkaudio.el10`:

```dockerfile
FROM almalinux:10 AS builder
# ... dnf install build deps (see §2.4) ...
# ... build orkbasecxx → orkaudio ...
FROM almalinux:10
# ... copy binaries, config, entrypoint ...
```

The existing `entrypoint.sh` works as-is (it only touches `/etc/orkaudio` and calls `exec`).

---

## 3. Testing Plan

| Phase | What | Success Criteria |
|---|---|---|
| **1. Compile** | `autoreconf -i && ./configure CXX=g++ && make` on EL10 | Zero errors |
| **2. Warnings** | Build with `-Wall -Wextra` under GCC 14 | Catalog all warnings |
| **3. Unit smoke** | Run orkaudio with `generator` plugin | Simulated calls captured |
| **4. Live capture** | Run orkaudio with `voip` plugin on a test interface | SIP calls detected, RTP captured |
| **5. Buffer tuning** | Verify pcap buffer sizes with `strace` / `/proc` | No silent SO_RCVBUF clamping |
| **6. Long soak** | Run 24h under production-like load | No memory leaks, no pcap drops escalating |
| **7. Multi-NIC** | Multiple devices in `config.xml` | All interfaces captured |

---

## 4. Quick-Start Commands on Target Box

```bash
# 1. Enable repos
dnf install -y epel-release
dnf config-manager --set-enabled crb

# 2. Install build deps
dnf install -y gcc gcc-c++ make libtool automake autoconf \
    boost-devel libpcap-devel libsndfile-devel apr-devel \
    speex-devel log4cxx-devel ace-devel libcap-devel \
    opus-devel xerces-c-devel openssl-devel cmake \
    elfutils-devel xz-devel libunwind-devel git

# 3. Tune kernel
echo 'net.core.rmem_max = 16777216' >> /etc/sysctl.d/90-orkaudio.conf
echo 'net.core.rmem_default = 16777216' >> /etc/sysctl.d/90-orkaudio.conf
sysctl --system

# 4. Build
cd orkbasecxx && autoreconf -i && ./configure CXX=g++ && make && make install
cd ../orkaudio && autoreconf -i && ./configure CXX=g++ && make && make install

# 5. Configure and run
cp config-linux-template.xml /etc/orkaudio/config.xml
# edit /etc/orkaudio/config.xml — set CapturePlugin to libvoip.so and add devices
orkaudio debug
```

---

## 5. Risks & Unknowns

1. **log4cxx availability**: Apache log4cxx was resurrected but may not be in EPEL 10. Fallback: build from source or switch to a maintained replacement.
2. **ACE (Adaptive Communication Environment)**: Not in base EL10; if EPEL doesn't have it, build from source.
3. **libpcap version**: EL10 ships libpcap ≥ 1.10.8. Verify `pcap_set_buffer_size()` behaviour on `TPACKET_V3` — some versions had bugs with buffer sizes > 64 MB.
4. **`backward-cpp` / stack traces**: Links against `libdw` (elfutils) and `libunwind`. Binutils 2.41 + GCC 14 may require different flags.
5. **SILK SDK build**: The SILK reference code (C89) may fail under GCC 14's `-Wimplicit-int` removal. Apply `-std=gnu89` or patch.

---

*Last updated: 2025-07-17  |  Branch: `version/2.5`*
