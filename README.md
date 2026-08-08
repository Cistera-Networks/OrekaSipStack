# OrekaSipStack — Open Source VoIP Media Capture & Retrieval Platform

Based on [OrecX Oreka](http://www.orecx.com/open-source/) ([GitHub](https://github.com/OrecX/Oreka)), this project provides a complete **Call Recording (SIPREC)** solution. It captures VoIP signalling and media from the network, extracts call metadata, compresses and stores audio recordings, and optionally serves them through a web interface.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Components](#components)
- [Supported Protocols & Codecs](#supported-protocols--codecs)
- [Project Structure](#project-structure)
- [Prerequisites](#prerequisites)
- [Building](#building)
  - [C++ Components (orkbasecxx & orkaudio)](#c-components-orkbasecxx--orkaudio)
  - [RPM Build & Installation](#rpm-build--installation)
  - [Java Components (orktrack & orkweb)](#java-components-orktrack--orkweb)
- [Docker](#docker)
  - [Building the Docker Image](#building-the-docker-image)
  - [Running with Docker](#running-with-docker)
  - [Docker Compose (Development)](#docker-compose-development)
- [Configuration](#configuration)
  - [orkaudio Configuration (config.xml)](#orkaudio-configuration-configxml)
  - [Logging Configuration](#logging-configuration)
- [Running orkaudio](#running-orkaudio)
- [How It Works](#how-it-works)
  - [Capture Pipeline](#capture-pipeline)
  - [Message Bus & Threading Model](#message-bus--threading-model)
  - [Audio Storage & Naming](#audio-storage--naming)
- [API & Integration](#api--integration)
- [Database](#database)
- [License](#license)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────────────┐
│                      Network Traffic                      │
│           (SIP / Skinny / H.323 / RTP / IAX2)            │
└─────────────────────┬────────────────────────────────────┘
                      │ libpcap (packet capture)
                      ▼
┌──────────────────────────────────────────────────────────┐
│                       orkaudio (C++)                      │
│                                                          │
│  ┌──────────┐  ┌────────────┐  ┌──────────────────────┐  │
│  │ VoIP     │  │ SoundDevice│  │ Generator (test)     │  │
│  │ Plugin   │  │ Plugin     │  │ Plugin               │  │
│  └────┬─────┘  └─────┬──────┘  └─────────┬────────────┘  │
│       │              │                   │               │
│       ▼              ▼                   ▼               │
│  ┌─────────────────────────────────────────────────────┐ │
│  │              orkbasecxx (C++ Library)               │ │
│  │  AudioCapture | AudioTape | Filters | Serializers   │ │
│  │  MultiThreadedServer | Config | Reporting           │ │
│  └─────────────────────────────────────────────────────┘ │
│       │                                                  │
│       ▼                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐   │
│  │ BatchProc    │  │ Reporting    │  │ EventStream  │   │
│  │ (compress)   │  │ (to orktrack)│  │ (WebSocket)  │   │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘   │
└─────────┼─────────────────┼─────────────────┼───────────┘
          │                 │                 │
          ▼                 ▼                 ▼
   ┌──────────┐    ┌──────────────┐   ┌──────────────┐
   │  Disk    │    │ orktrack     │   │ External     │
   │ (wav/gsm │    │ (Java/MySQL) │   │ Consumers    │
   │  /opus)  │    └──────┬───────┘   └──────────────┘
   └──────────┘           │
                          ▼
                   ┌──────────────┐
                   │   orkweb     │
                   │ (Java Web UI)│
                   └──────────────┘
```

## Components

### orkbasecxx
The **C++ base library** shared by all C++ capture services. It provides:
- **AudioCapture**: Core audio capture abstractions and plugin framework.
- **AudioTape**: Recording session management — tracks call state, metadata, and audio chunks.
- **Filters**: Codec conversion filters (GSM, iLBC, G.722, G.726, Opus, Speex).
- **Serializers**: Serialization formats (DOM, SingleLine, URL, XML-RPC).
- **MultiThreadedServer**: TCP/TLS server framework for accepting connections.
- **Config**: XML configuration parsing with XSD schema validation.
- **Reporting**: Metadata reporting to orktrack via TCP or TLS.
- **BatchProcessing**: Thread pool for post-processing audio (compression, format conversion).
- **EventStreaming**: WebSocket push of real-time events.

### orkaudio
The **audio capture daemon**. Links against orkbasecxx and dynamically loads capture plugins at runtime. Handles:
- Packet capture via libpcap.
- Signalling parsing (SIP, Skinny, IAX2, H.323).
- RTP media stream detection, extraction, and chunking.
- Multi-threaded processing pipeline.

### orktrack (Java)
A **metadata indexing and search service**. Receives call metadata from orkaudio over TCP/TLS, stores it in MySQL, and exposes a search API.

### orkweb (Java)
A **web-based user interface** built with Apache Tapestry. Provides call search, playback, and download features.

---

## Supported Protocols & Codecs

### VoIP Signalling Protocols

| Protocol | Description |
|----------|-------------|
| **SIP** (including SIPREC) | Session Initiation Protocol — the primary signalling protocol. SIPREC support for call recording servers. |
| **Cisco Skinny (SCCP)** | Cisco Skinny Client Control Protocol — used by older Cisco IP phones. |
| **IAX2** | Inter-Asterisk eXchange protocol v2. |
| **H.323** | Legacy ITU-T protocol suite. |
| **RTP/RTCP** | Raw RTP media streams with RTCP metadata. |

### Audio Codecs

| Codec | Description | Library |
|-------|-------------|---------|
| G.711 (μ-law / A-law) | Standard narrowband codec | Built-in |
| GSM | GSM 06.10 full-rate | Built-in (libgsm) |
| iLBC | Internet Low Bitrate Codec | Built-in (libilbc) |
| G.722 | Wideband (7 kHz) codec | Built-in (libg722) |
| G.726 (16/24/32/40 kbps) | ADPCM codec variants | Built-in (libg726) |
| **G.729** | 8 kbps narrowband | libbcg729 (built from source) |
| **SILK** | Skype SILK codec | SILK SDK (built from source) |
| **Opus** | Modern wideband codec | libopus |
| **Speex** | Speech codec | libspeex |

### Storage Formats

| Format | Extension | Description |
|--------|-----------|-------------|
| `native` | `.mcf` | Raw Oreka container format |
| `gsm` | `.gsm` | GSM 06.10 compressed |
| `ulaw` | `.ulaw` | G.711 μ-law raw audio |
| `alaw` | `.alaw` | G.711 A-law raw audio |
| `pcmwav` | `.wav` | PCM in WAV container (supports stereo) |
| `opus` | `.opus` | Opus in Ogg container |

---

## Project Structure

```
OrekaSipStack/
├── orkbasecxx/               # C++ base library
│   ├── audiofile/            #   Audio file writers (PCM, WAV, Opus/Ogg)
│   ├── filters/              #   Codec filters (GSM, iLBC, G.722, G.726, Opus, Speex)
│   ├── messages/             #   Internal message types (TapeMsg, CaptureMsg, etc.)
│   ├── serializers/          #   Serialization (DOM, SingleLine, URL, XML-RPC)
│   ├── AudioCapture.*        #   Core audio capture abstractions
│   ├── AudioTape.*           #   Recording session management
│   ├── BatchProcessing.*     #   Thread pool for audio processing
│   ├── CapturePort.*         #   Network endpoint tracking
│   ├── Config.*              #   XML configuration parsing
│   ├── MultiThreadedServer.* #   TCP/TLS server framework
│   ├── Reporting.*           #   Metadata reporting to orktrack
│   └── ...
├── orkaudio/                 # Audio capture daemon
│   ├── audiocaptureplugins/  #   Capture plugins
│   │   ├── common/           #     Shared plugin infrastructure
│   │   ├── voip/             #     VoIP plugin (SIP, Skinny, IAX2, RTP)
│   │   ├── sounddevice/      #     Sound device plugin
│   │   └── generator/        #     Test signal generator plugin
│   ├── filters/              #   Additional codec filters (G.729, SILK, RTP mixer)
│   ├── messages/             #   OrkAudio-specific messages
│   ├── OrkAudio.cpp          #   Main entry point
│   ├── config-linux-template.xml   #   Linux configuration template
│   └── config-template.xml   #   Windows configuration template
├── orkweb/                   # Java web UI (Tapestry)
│   ├── src/net/sf/           #   Java source
│   ├── context/              #   Web app context files
│   └── pom.xml               #   Maven build
├── distribution/             # Packaging & deployment
│   ├── docker/               #   Docker files
│   │   ├── Dockerfile.orkaudio
│   │   ├── docker-compose.yml
│   │   └── entrypoint.sh
│   ├── orkaudio-linux-deb-binary/
│   ├── orkaudio-win32-binary/
│   ├── orkweb-linux-installer/
│   ├── orkweb-win32-installer/
│   └── tools/                #   DB migration scripts
├── documentation/            # Developer docs (DocBook XML)
├── pom.xml                   # Maven parent POM
├── BUILD_C++.txt             # C++ build instructions
├── CHANGELOG.txt             # Release history
├── LICENSE                   # GPL v3
└── README.md                 # This file
```

---

## Prerequisites

### For C++ (orkbasecxx & orkaudio) — Ubuntu 18.04+

```bash
# System dependencies
sudo apt-get install -y \
    build-essential libtool automake git \
    libboost-dev \
    libapr1-dev \
    liblog4cxx-dev \
    libpcap-dev \
    libxerces-c-dev \
    libsndfile1-dev \
    libspeex-dev \
    libssl-dev \
    libace-dev \
    libcap-dev \
    libdw-dev \
    liblzma-dev \
    libunwind-dev \
    cmake
```

### For AlmaLinux 10 / RHEL 10 (RPM build server)

```bash
# System dependencies (run as root once)
dnf install -y epel-release
dnf config-manager --set-enabled crb
dnf install -y gcc gcc-c++ make libtool automake autoconf \
    boost-devel libpcap-devel libsndfile-devel apr-devel \
    speex-devel log4cxx-devel libcap-devel opus-devel \
    xerces-c-devel openssl-devel cmake elfutils-devel xz-devel \
    libunwind-devel git rpm-build rpmdevtools file
```

### Opus & SILK Codec Libraries

```bash
# Build Opus
git clone https://github.com/xiph/opus.git
cd opus && git checkout v1.2.1
./autogen.sh
./configure --enable-shared --with-pic --enable-static
make && sudo make install

# Build SILK
git clone https://github.com/gaozehua/SILKCodec.git /opt/silk/SILKCodec
cd /opt/silk/SILKCodec/SILK_SDK_SRC_FIX
CFLAGS='-fPIC' make all
```

### Optional: G.729 Codec

```bash
git clone https://github.com/BelledonneCommunications/bcg729.git
cd bcg729
cmake . -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib
make && sudo make install
```

### Optional: backward-cpp (stack traces)

Required for the RPM build. Install once as root:

```bash
mkdir -p /opt/backward-cpp && chmod 777 /opt/backward-cpp
git clone --depth 1 https://github.com/bombela/backward-cpp.git /opt/backward-cpp
ln -s /opt/backward-cpp/backward.hpp /usr/local/include/backward.hpp
```

### For Java (orktrack & orkweb)

- JDK 8+
- Maven 3+
- Tomcat (for orkweb deployment)
- MySQL (for orktrack database)

---

## Building

### C++ Components (orkbasecxx & orkaudio)

Both libraries use GNU Autotools.

#### Step 1: Build and install orkbasecxx

```bash
cd orkbasecxx
autoreconf -i
./configure CXX=g++
make
sudo make install
```

This installs `liborkbase.*` to `/usr/lib/` and headers to `/usr/include/`.

#### Step 2: Build orkaudio

```bash
cd orkaudio
autoreconf -i
./configure CXX=g++
make
sudo make install
```

This installs the `orkaudio` binary to `/usr/sbin/` and plugins to `/usr/lib/`.

#### Building on Windows

Visual Studio project files (`.sln`, `.vcxproj`, `.vcproj`) are provided in both `orkbasecxx/` and `orkaudio/` directories.

### RPM Build & Installation

The RPM build script lives in the BuildServer repo (`build_scripts/oreka_sipstack_rpm_build_github.sh`) and is deployed to `/opt/scripts/` on the build host — the standard releasing mechanism used by every component (see the BuildServer Jenkins pipelines). It targets **AlmaLinux 10** (kernel 6.12, GCC 14.3), performs a full source build, stages everything under a DESTDIR, and packages it into an installable `.rpm`.

#### Build Process Overview

The script runs six steps:

| Step | What it does |
|------|-------------|
| 0 | Clones the repository from GitHub (requires `GITHUB_TOKEN`) |
| 1 | Verifies system build dependencies are installed |
| 2 | Verifies third-party codec libraries (SILK, bcg729, Opus) are present |
| 3 | Builds `orkbasecxx`: `autoreconf -i`, `./configure --prefix=/usr --libdir=/usr/lib`, `make`, `make install DESTDIR=...` |
| 4 | Builds `orkaudio`: same flow, linking against staged `orkbasecxx` via `LD_LIBRARY_PATH` |
| 5 | Generates an RPM `.spec` file and runs `rpmbuild -bb` |
| 6 | Copies the resulting `.rpm` to the output directory and runs a smoke test |

#### Running the Build (Jenkins)

```bash
export GITHUB_TOKEN="ghp_..."
export GIT_BRANCH="version/2.5"
export BUILD_NUMBER="1"
/opt/scripts/oreka_sipstack_rpm_build_github.sh
```

The output RPM lands at `/data/RPMS/orkaudio/orkaudio-2.5-1.<build>.el10.x86_64.rpm`.

#### Build Server Prerequisites (run once as root)

Before the script can run, the build server must have:

1. System packages (see [Prerequisites for AlmaLinux](#for-almalinux-10--rhel-10-rpm-build-server))
2. Codec libraries: SILK at `/opt/silk/SILKCodec/SILK_SDK_SRC_FIX/`, bcg729, Opus
3. backward-cpp at `/usr/local/include/backward.hpp`
4. Build directories: `/opt/RPMBUILDER/`, `/data/RPMS/orkaudio/`

#### RPM Architecture

The spec file packages:

| Path | Contents |
|------|----------|
| `/usr/sbin/orkaudio` | Main daemon binary |
| `/usr/lib/liborkbase.so*` | Core shared library |
| `/usr/lib/libvoip.so*` | VoIP capture plugin |
| `/usr/lib/libgenerator.so*` | Test signal generator plugin |
| `/usr/lib/orkaudio/plugins/` | Codec filter plugins (G.729, SILK, RTP mixer) |
| `/usr/lib64/libbcg729.so*` | G.729 codec library |
| `/etc/orkaudio/` | Configuration files |
| `/opt/orkaudio/audio/` | Default recording output directory |
| `/var/log/orkaudio/` | Log directory |

#### Installing the RPM

```bash
# Install the RPM (requires root)
sudo rpm -ivh orkaudio-2.5-1.el10.x86_64.rpm

# Or upgrade an existing installation
sudo rpm -Uvh orkaudio-2.5-1.el10.x86_64.rpm

# Verify installation
rpm -ql orkaudio
orkaudio version
```

#### Post-Install Setup

```bash
# Grant raw socket permissions for packet capture
sudo setcap cap_net_raw,cap_net_admin+ep /usr/sbin/orkaudio

# Tune kernel buffer for high-throughput capture
echo 'net.core.rmem_max = 16777216' | sudo tee /etc/sysctl.d/90-orkaudio.conf
sudo sysctl --system

# Edit configuration
sudo vi /etc/orkaudio/config.xml

# Start orkaudio
orkaudio debug
```

### Java Components (orktrack & orkweb)

```bash
# From the project root
mvn clean package
```

This builds both `orktrack` and `orkweb` WAR files. Deploy `orkweb.war` to Tomcat.

---

## Docker

The project includes a multi-stage Docker build for orkaudio.

### Building the Docker Image

```bash
export DOCKER_BUILDKIT=1
cd distribution/docker
docker build -f Dockerfile.orkaudio -t voiceip/orkaudio .
```

The Dockerfile:
1. **Stage 1 (builder)**: Installs all build dependencies, compiles Opus, SILK, bcg729 (G.729), builds orkbasecxx and orkaudio from source.
2. **Stage 2 (runtime)**: Copies only the built binaries and libraries into a clean Ubuntu image.

### Running with Docker

```bash
docker run -it \
    --net=host \
    --restart=always \
    --privileged=true \
    -v /var/log/orkaudio:/var/log/orkaudio \
    -v /etc/orkaudio:/etc/orkaudio \
    voiceip/orkaudio:latest
```

**Important notes:**
- `--net=host` is required for libpcap to capture network traffic.
- `--privileged=true` is required for raw socket access.
- Mount `/etc/orkaudio` to provide a `config.xml` (or the entrypoint auto-generates one).
- Mount `/var/log/orkaudio` for persistent logs and optional audio output.

### Docker Compose (Development)

A `docker-compose.yml` is provided that starts:
- **orkaudio** — the capture service
- **softphone** — a PJSIP-based softphone for testing (`andrius/pjsua`)
- **tcpdump** — for debugging SIP signalling (`nicolaka/netshoot`)

```bash
cd distribution/docker
# Edit docker-compose.yml to set SIP_SERVER_HOST
docker-compose up
```

### Entrypoint Behavior

The `entrypoint.sh` script:
1. Checks if `/etc/orkaudio` is externally mounted.
2. If not, generates a default `config.xml` from the template, substituting `__INTERFACE__` with the `INTERFACE` environment variable (default: `eth0`).
3. Prints the configuration and launches orkaudio.

---

## Configuration

### orkaudio Configuration (config.xml)

Copy the template to `config.xml` and customize:

```
orkaudio/config-linux-template.xml  →  /etc/orkaudio/config.xml  (Linux)
orkaudio/config-template.xml        →  config.xml               (Windows)
```

#### Key Configuration Elements

| Parameter | Description | Default |
|-----------|-------------|---------|
| `AudioOutputPath` | Where recordings are stored | `/opt/orkaudio/audio` |
| `CapturePlugin` | Plugin to load (`libvoip.so`, `VoIP.dll`, `libgenerator.so`) | `libvoip.so` |
| `CapturePluginPath` | Directory containing plugin `.so`/`.dll` files | `/usr/lib` |
| `StorageAudioFormat` | Compression format: `native`, `gsm`, `ulaw`, `alaw`, `pcmwav`, `opus` | `gsm` |
| `DeleteNativeFile` | Delete raw `.mcf` file after compression (`yes`/`no`) | `yes` |
| `TrackerHostname` | orktrack server hostname/IP | `localhost` |
| `TrackerTcpPort` | orktrack TCP port | `9000` |
| `TlsClientCACertFile` | CA certificate for TLS to orktrack | `/etc/orkaudio/certs/orkweb.pem` |
| `CapturePortFilters` | Comma-separated filter list | `LiveMonitoring` |
| `TapeProcessors` | Post-processing pipeline | `BatchProcessing, Reporting` |
| `BatchProcessingEnhancePriority` | Boost batch thread priority | `true` |
| `AudioFileOwner` / `AudioFileGroup` / `AudioFilePermissions` | File ownership | `root` / `root` / `644` |
| `SocketStreamerTargets` | TCP endpoints to mirror data to | (none) |

#### VoIP Plugin Configuration (`<VoIpPlugin>`)

| Parameter | Description |
|-----------|-------------|
| `Devices` | Network device(s) to capture from (e.g., `enx00e082312676`) |
| `PcapFilter` | libpcap filter expression (e.g., `host 10.0.0.1`) |
| `PcapSocketBufferSize` | Kernel buffer size for pcap (e.g., `67108864`) |
| `IpFragmentsReassemble` | Reassemble fragmented IP packets |
| `SipOverTcpSupport` | Enable SIP-over-TCP detection |
| `SipDomains` | Comma-separated SIP domains for direction detection |
| `SipDirectionReferenceIpAddresses` | Reference IPs for direction detection |
| `SipReportFullAddress` | Report full SIP URI instead of just user |
| `SipUse200OkMediaAddress` | Use 200 OK SDP for media address |
| `Iax2Support` | Enable IAX2 protocol support |
| `SangomaRxTcpPortStart` / `SangomaTxTcpPortStart` | Sangoma TDM board integration |
| `MitelDetect` / `MitelSignallingPort` | Mitel platform support |

#### SIPREC Configuration (`<SipUAPlugin>`)

| Parameter | Description |
|-----------|-------------|
| `SipMode` | SIPREC mode: `SiprecBroadWorks`, `SiprecAcme`, `CiscoBib`, `SiprecMetaswitch`, `SiprecOpenSips`, `Truphone`, `SiprecSonus`, `SiprecSangoma`, `SiprecAudioCodes`, `SipGeneric`, `Softphone` |
| `SupportFeatures` | SIP feature tags (e.g., `resource-priority,siprec`) |
| `SipRecExtractFields` | SIPREC XML fields to extract as tags (e.g., `groupid,serviceproviderid`) |
| `SipExtractFields` | Arbitrary SIP header fields to extract (e.g., `X-Unique-ID`) |
| `SdpOfferAnswerMode` | Enable SDP offer/answer model |

### Logging Configuration

Copy and edit the logging template:

```
orkaudio/logging-linux-template.properties  →  /etc/orkaudio/logging.properties
```

Uses log4cxx for C++ logging. Controls log levels, appenders, and output paths.

---

## Running orkaudio

```bash
# Run in foreground (attached to terminal, with debug logging)
orkaudio debug

# Run as a daemon (background)
orkaudio

# Run in foreground (alias)
orkaudio fg

# Display version
orkaudio version

# Transcode an existing .mcf file to the configured storage format
orkaudio transcode <file.mcf>

# Windows only: Install as NT service
orkaudio install

# Windows only: Uninstall NT service
orkaudio uninstall
```

---

## How It Works

### Capture Pipeline

1. **Packet Capture**: The VoIP plugin uses libpcap to sniff network traffic on the specified interface(s). A BPF filter can be applied to limit which packets are inspected.

2. **Signalling Parsing**: SIP INVITE, BYE, re-INVITE messages are parsed to detect call start, stop, hold, and resume. Metadata (caller, callee, call-ID, etc.) is extracted. Cisco Skinny, IAX2, H.323, and other protocols are similarly parsed.

3. **RTP Stream Detection**: RTP media streams are identified by their SSRC, payload type, and IP/port tuples. Multiple codecs within a single call are tracked per-SSRC.

4. **Audio Chunking**: RTP payloads are assembled into `AudioChunk` objects with encoding, timestamp, and sequence number information.

5. **Direction Detection**: Based on configured LAN masks, media gateway IPs, and signalling analysis, each audio stream is classified as inbound or outbound.

6. **Session (Tape) Management**: Audio chunks are associated with a recording session (`AudioTape`). Sessions track state: start, stop, hold, resume.

### Message Bus & Threading Model

orkaudio uses an internal message-passing architecture with dedicated thread pools:

```
Capture Thread (pcap loop)
    │
    ▼
ImmediateProcessing (queue + thread pool)
    │  - RTP/SIP parsing
    │  - Session state tracking
    ▼
BatchProcessing (queue + thread pool)
    │  - Audio compression (codec → storage format)
    │  - WAV/Opus file writing
    ▼
Reporting (queue + thread)
    │  - Serializes metadata
    │  - Sends to orktrack via TCP/TLS
    ▼
TapeFileNaming (thread)
    │  - Generates file paths from templates
    ▼
CommandProcessing (thread)
    │  - Handles external API commands (record, stop, pause)
    ▼
EventStreaming (thread)
    - WebSocket push of real-time events
```

All queues are bounded and configurable. Thread counts are configurable for BatchProcessing.

### Audio Storage & Naming

Recordings are stored in a date-based directory hierarchy:

```
<AudioOutputPath>/
└── YYYY/
    └── MM/
        └── DD/
            └── hh/
                └── YYYYMMDD_hhmmss_capturePort.extension
```

File naming is configurable via `TapeFileNaming` and `TapePathNaming` parameters.

---

## API & Integration

### Reporting to orktrack

orkaudio sends JSON-formatted metadata over TCP or TLS to orktrack. Configure:

```xml
<TrackerHostname>localhost</TrackerHostname>
<TrackerTcpPort>9000</TrackerTcpPort>
```

For TLS, prefix the hostname with `https://` or set `TrackerTlsPort`.

### Event Streaming

orkaudio can stream real-time events via WebSocket on a configurable port:

```xml
<EventStreamingServerPort>8090</EventStreamingServerPort>
```

### External Control API

orkaudio accepts commands via its TCP server:

- **Record**: Start recording a specific call
- **Stop**: Stop recording a specific call
- **Pause**: Pause/resume recording

### Socket Streamer

Mirror captured data to external TCP endpoints:

```xml
<SocketStreamerTargets>192.168.1.250:1721, 192.168.1.1:8091</SocketStreamerTargets>
```

---

## Database

orktrack uses MySQL. The default database name is `oreka` (Linux) or `test` (Windows).

### Schema Migration

If upgrading from an older Oreka version, run the migration script:

```bash
mysql -uroot -p<password> oreka < distribution/tools/updateOrekaDB_to_v1.sql
```

---

## Development & Testing

### Testing with the Generator Plugin

The generator plugin creates simulated calls from a reference WAV file (16-bit, mono, 8 kHz):

1. Set `CapturePlugin` to `libgenerator.so` (Linux) or `generator.dll` (Windows).
2. Specify a reference file in `AudioFilename`.
3. Run orkaudio — fake calls with generated metadata will appear.

### Running Multiple Instances

orkaudio supports multiple instances on Linux. Each instance needs its own `config.xml` and must use a unique `serviceName`.

---

## License

This project is distributed under the **GNU General Public License v3** (see [LICENSE](LICENSE)).

Based on original work by OrecX LLC (Copyright © 2005, http://www.orecx.com).

---

## References

- [OrecX Open Source](http://www.orecx.com/open-source/)
- [Original Oreka Repository](https://github.com/OrecX/Oreka)
- [SIPREC Protocol](https://tools.ietf.org/html/rfc7865)
