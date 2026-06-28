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

| Module | Purpose |
|--------|---------|
| `AudioCapture` | Core audio chunk handling, capture events, encoding enums |
| `AudioTape` | Recording session lifecycle (start/stop/hold/resume) |
| `CapturePort` | Associates a network endpoint with a recording session |
| `BatchProcessing` | Thread pool for audio compression and post-processing |
| `Reporting` | Sends call metadata to orktrack via TCP/TLS |
| `Config` / `ConfigManager` | XML configuration parsing |
| `serializers/` | Serialization formats: DOM, SingleLine, URL, XML-RPC |
| `audiofile/` | Audio file writers: PCM, WAV (libsndfile), Opus/Ogg, MediaChunk |
| `filters/` | Codec transcoding filters (see [Supported Codecs](#supported-protocols--codecs)) |
| `MultiThreadedServer` | TCP/TLS server infrastructure |
| `EventStreaming` | WebSocket-based event streaming |
| `Daemon` | Cross-platform daemonization (Linux daemon / Windows service) |

### orkaudio
The **audio capture and storage daemon**. It uses pluggable capture modules:

| Plugin | Library | Description |
|--------|---------|-------------|
| **VoIP** | `libvoip.so` / `VoIP.dll` | Primary plugin. Captures VoIP signalling and RTP media via libpcap. Supports SIP, Cisco Skinny (SCCP), IAX2, and raw RTP/RTCP. Also supports SIPREC for compliant call recording. |
| **SoundDevice** | (sounddevice/) | Records from local sound card / audio input device. |
| **Generator** | `libgenerator.so` | Generates fake audio streams for testing. Replays an existing WAV file as simulated calls. |

### orktrack *(Java, in pom.xml modules)*
Tracks and publishes all activity from one or more orkaudio services to a database (MySQL). Receives call metadata via TCP/TLS from orkaudio's Reporting module.

### orkweb *(Java/Tapestry)*
A J2EE Tapestry-based web front-end for searching, browsing, and replaying recorded calls. Communicates with the orktrack database.

---

## Supported Protocols & Codecs

### VoIP Signalling Protocols
| Protocol | Support |
|----------|---------|
| **SIP** (including SIPREC) | Full support — INVITE, BYE, re-INVITE (hold/resume), compact headers, SIP over TCP, SDP offer/answer, custom header extraction |
| **Cisco Skinny (SCCP)** | Full support — CUCM 7+, metadata extraction |
| **IAX2** | Supported |
| **H.323** (Avaya extensions) | Supported via `libh323voip.so` plugin |
| **Nortel Unistim** | Supported |
| **Mitel** | Supported (signalling + ARP extension detection + SMDR) |
| **Sangoma Wanpipe RTP Tap** | Supported (TDM board integration) |
| **Raw RTP / RTCP** | Supported with SDES metadata extraction |

### Audio Codecs (decode → transcode → store)
| Codec | RTP Payload | Notes |
|-------|-------------|-------|
| G.711 μ-law (PCMU) | 0 | |
| G.711 A-law (PCMA) | 8 | |
| GSM | 3 | |
| iLBC | 97 | |
| G.722 | 9 | Wideband |
| G.721 | — | |
| G.726 | — | |
| G.729 | 18 | Via bcg729 library |
| SILK | — | Via SILK SDK |
| Opus | — | Via libopus |
| Speex | — | Via libspeex |

### Storage Formats
| Format | Extension | Description |
|--------|-----------|-------------|
| `native` | `.mcf` | Raw media chunk file (uncompressed) |
| `gsm` | `.gsm` | GSM 6.10 compressed |
| `ulaw` | `.ulaw` | G.711 μ-law |
| `alaw` | `.alaw` | G.711 A-law |
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
