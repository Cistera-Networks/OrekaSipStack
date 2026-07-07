#!/bin/bash
# =============================================================================
# Jenkins Build Script -- OrekaSipStack (orkaudio) RPM  (AlmaLinux 10)
#
#  Prerequisites (run ONCE as root before any Jenkins job):
#    dnf install -y epel-release; dnf config-manager --set-enabled crb
#    dnf install -y gcc gcc-c++ make libtool automake autoconf \
#        boost-devel libpcap-devel libsndfile-devel apr-devel \
#        speex-devel log4cxx-devel libcap-devel opus-devel \
#        xerces-c-devel openssl-devel cmake elfutils-devel xz-devel \
#        libunwind-devel git rpm-build rpmdevtools file
#    # SILK, bcg729, Opus, backward-cpp -- see build prerequisites doc
#
#  1. Clones OrekaSipStack from GitHub (authenticated via GITHUB_TOKEN)
#  2. Verifies build dependencies and codec libs are present
#  3. Builds orkbasecxx  (autotools -> make -> staging install)
#  4. Builds orkaudio     (autotools -> make -> staging install)
#  5. Packages orkaudio + liborkbase + plugins into an installable RPM
#  6. Copies the resulting RPM to GENERATED_RPM_DIRECTORY
#
#  Called by Jenkins; requires GITHUB_TOKEN environment variable.
#  Target  : AlmaLinux 10  (kernel 6.12, GCC 14.3)
#  Branch  : version/2.5
# =============================================================================
set -euo pipefail

export GIT_TERMINAL_PROMPT=0

GIT_REPO_URL="https://github.com/Cistera-Networks/OrekaSipStack.git"
GIT_BRANCH="${GIT_BRANCH:-version/2.5}"

RPM_BUILD_DIRECTORY="/opt/RPMBUILDER"
WORKSPACE_ROOT="$RPM_BUILD_DIRECTORY/workspaces/orekasipstack"
GENERATED_RPM_DIRECTORY="/data/RPMS/orkaudio"
LOG_DIRECTORY="/var/log/cistera_orkaudio_builder"

DATE_DIRECTORY="$(date +%Y%m%d)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
CHANGELOG_DATE="$(date "+%a %b %d %Y")"

VERSION="2.5"
RELEASE="1"

LOG_FILE="${LOG_DIRECTORY}/${DATE_DIRECTORY}/build_${TIMESTAMP}.log"
mkdir -p "$(dirname "${LOG_FILE}")"

exec > >(tee -a "${LOG_FILE}") 2>&1

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')]  $*"; }

log "============================================================================="
log "OrekaSipStack (orkaudio) RPM Build -- started"
log "  Workspace   : ${WORKSPACE_ROOT}"
log "  RPM output  : ${GENERATED_RPM_DIRECTORY}"
log "  Log file    : ${LOG_FILE}"
log "  Version     : ${VERSION}-${RELEASE}"
log "  Branch      : ${GIT_BRANCH}"
log "  Target      : AlmaLinux 10 / kernel 6.12 / GCC 14.3"
log "============================================================================="

# =============================================================================
# Git helpers
# =============================================================================

function check_credentials() {
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        log "ERROR: GitHub Personal Access Token required. Export GITHUB_TOKEN or pass via Jenkins credentials."
        exit 1
    fi
    log "GitHub token verified (length: ${#GITHUB_TOKEN})"
}

function get_auth_repo_url() {
    local raw_url="$1"
    echo "${raw_url}" | sed -E "s!^https://!https://${GITHUB_TOKEN}@!"
}

function fix_source_permissions() {
    local src="$1"
    log "Fixing source file permissions in ${src}..."
    find "${src}" -type f -name "*.sh"  -exec chmod +x {} \; 2>/dev/null || true
    find "${src}" -type f \( -name "Makefile" -o -name "configure" -o -name "*.m4" -o -name "*.ac" -o -name "*.am" \) \
        -execdir chmod -R +w . \; 2>/dev/null || true
}

function cleanup_git_auth() {
    log "Cleaning up Git auth..."
    git config --global --unset-all url."https://${GITHUB_TOKEN}@github.com/".insteadOf 2>/dev/null || true
}

# =============================================================================
# Step 0 -- Clone from GitHub
# =============================================================================
log "Step 0/6  Cloning repository..."

check_credentials

AUTH_URL=$(get_auth_repo_url "${GIT_REPO_URL}")

log "  Repo   : ${GIT_REPO_URL}"
log "  Branch : ${GIT_BRANCH}"
log "  Target : ${WORKSPACE_ROOT}"

rm -rf "${WORKSPACE_ROOT}"

if ! git clone --depth 1 -b "${GIT_BRANCH}" "${AUTH_URL}" "${WORKSPACE_ROOT}"; then
    log "ERROR: Git clone failed - verify GITHUB_TOKEN has repo access"
    exit 1
fi

trap 'cleanup_git_auth' EXIT

fix_source_permissions "${WORKSPACE_ROOT}"

log "  Clone completed successfully."

# =============================================================================
# Step 1 -- Verify build dependencies (pre-installed by root)
# =============================================================================
log "Step 1/6  Verifying build dependencies..."

MISSING=""
for dep in gcc g++ make libtool autoreconf autoconf cmake git rpmbuild file; do
    command -v "$dep" >/dev/null 2>&1 || MISSING+="  $dep"$'\n'
done
for header in boost/shared_ptr.hpp pcap.h sndfile.hh apr.h speex/speex.h \
              log4cxx/logger.h opus/opus.h xercesc/dom/DOM.hpp \
              openssl/ssl.h elfutils/libdw.h unwind.h; do
    test -f "/usr/include/${header}" 2>/dev/null \
        || test -f "/usr/include/apr-1/${header##*/}" 2>/dev/null \
        || MISSING+="  ${header}"$'\n'
done

if [ -n "$MISSING" ]; then
    log "ERROR: The following build dependencies are missing:"
    echo "$MISSING"
    log ""
    log "Run this as root once before running Jenkins:"
    log ""
    log "  dnf install -y epel-release"
    log "  dnf config-manager --set-enabled crb"
    log "  dnf install -y gcc gcc-c++ make libtool automake autoconf \\"
    log "      boost-devel libpcap-devel libsndfile-devel apr-devel \\"
    log "      speex-devel log4cxx-devel libcap-devel opus-devel \\"
    log "      xerces-c-devel openssl-devel cmake elfutils-devel xz-devel \\"
    log "      libunwind-devel git rpm-build rpmdevtools file"
    exit 1
fi

log "  All build dependencies present."

# =============================================================================
# Step 2 -- Verify codec libraries (pre-installed by root)
# =============================================================================
log "Step 2/6  Verifying third-party codec libraries..."

MISSING_CODECS=""

# --- SILK ---
if [ -d /opt/silk/SILKCodec/SILK_SDK_SRC_FIX ] && ls /opt/silk/SILKCodec/SILK_SDK_SRC_FIX/*.a >/dev/null 2>&1; then
    log "  SILK SDK: present"
else
    MISSING_CODECS+="  SILK SDK  (expected at /opt/silk/SILKCodec/SILK_SDK_SRC_FIX)"$'\n'
fi

# --- bcg729 (G.729) ---
if ldconfig -p 2>/dev/null | grep -q libbcg729; then
    log "  bcg729 (G.729): present"
else
    MISSING_CODECS+="  bcg729 / G.729"$'\n'
fi

# --- Opus ---
if ldconfig -p 2>/dev/null | grep -q libopus; then
    log "  Opus: present"
else
    MISSING_CODECS+="  Opus"$'\n'
fi

if [ -n "$MISSING_CODECS" ]; then
    log "ERROR: The following codec libraries are missing:"
    echo "$MISSING_CODECS"
    log ""
    log "Run this as root once before running Jenkins:"
    log ""
    log "  # --- SILK SDK ---"
    log "  mkdir -p /opt/silk && chmod 777 /opt/silk"
    log "  git clone --depth 1 https://github.com/gaozehua/SILKCodec.git /tmp/SILKCodec"
    log "  cd /tmp/SILKCodec/SILK_SDK_SRC_FIX"
    log "  CFLAGS='-fPIC -std=gnu99' make all"
    log "  cp -a /tmp/SILKCodec /opt/silk/"
    log "  rm -rf /tmp/SILKCodec"
    log ""
    log "  # --- bcg729 (G.729) ---"
    log "  git clone --depth 1 https://github.com/BelledonneCommunications/bcg729.git /tmp/bcg729"
    log "  cd /tmp/bcg729"
    log "  cmake . -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=/usr/lib64"
    log "  make && make install"
    log "  rm -rf /tmp/bcg729"
    log ""
    log "  # --- Opus ---"
    log "  dnf install -y opus-devel"
    log ""
    log "  ldconfig"
    exit 1
fi

log "  All codec libraries present."

# =============================================================================
# Step 3 -- Build orkbasecxx
# =============================================================================
log "Step 3/6  Building orkbasecxx..."

cd "${WORKSPACE_ROOT}/orkbasecxx"

autoreconf -i

./configure CXX=g++ --prefix=/usr --libdir=/usr/lib

make -j"$(nproc)"

# Install to a staging area for RPM packaging
ORKSIP_INSTALL_ROOT="${RPM_BUILD_DIRECTORY}/orkaudio-install"
rm -rf "${ORKSIP_INSTALL_ROOT}"
mkdir -p "${ORKSIP_INSTALL_ROOT}"

make install DESTDIR="${ORKSIP_INSTALL_ROOT}"

log "  orkbasecxx build complete."
log "  Installed to staging: ${ORKSIP_INSTALL_ROOT}"

# =============================================================================
# Step 4 -- Build orkaudio
# =============================================================================
log "Step 4/6  Building orkaudio..."

cd "${WORKSPACE_ROOT}/orkaudio"

export PKG_CONFIG_PATH="${ORKSIP_INSTALL_ROOT}/usr/lib/pkgconfig:${ORKSIP_INSTALL_ROOT}/usr/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
export LD_LIBRARY_PATH="${ORKSIP_INSTALL_ROOT}/usr/lib:${ORKSIP_INSTALL_ROOT}/usr/lib64:${LD_LIBRARY_PATH:-}"

autoreconf -i

./configure CXX=g++ --prefix=/usr --libdir=/usr/lib \
    LDFLAGS="-L${ORKSIP_INSTALL_ROOT}/usr/lib -L${ORKSIP_INSTALL_ROOT}/usr/lib64 -Wl,-rpath,/usr/lib" \
    CPPFLAGS="-I${ORKSIP_INSTALL_ROOT}/usr/include"

make -j"$(nproc)"

make install DESTDIR="${ORKSIP_INSTALL_ROOT}"

log "  orkaudio build complete."

# Verify key binaries
ORKAUDIO_BIN="${ORKSIP_INSTALL_ROOT}/usr/sbin/orkaudio"
LIBORKBASE="${ORKSIP_INSTALL_ROOT}/usr/lib/liborkbase.so"
LIBVOIP="${ORKSIP_INSTALL_ROOT}/usr/lib/libvoip.so"

test -x "${ORKAUDIO_BIN}"    || { log "ERROR: orkaudio binary missing: ${ORKAUDIO_BIN}";       exit 1; }
test -f "${LIBORKBASE}"      || { log "ERROR: liborkbase missing: ${LIBORKBASE}";               exit 1; }
test -f "${LIBVOIP}"         || { log "ERROR: libvoip plugin missing: ${LIBVOIP}";              exit 1; }

log "  orkaudio   : $(file "${ORKAUDIO_BIN}"   | cut -d, -f1)"
log "  liborkbase : $(file "${LIBORKBASE}"     | cut -d, -f1)"
log "  libvoip    : $(file "${LIBVOIP}"        | cut -d, -f1)"

# =============================================================================
# Step 5 -- Package into RPM
# =============================================================================
log "Step 5/6  Setting up RPM build tree..."

RPM_TOPDIR="${RPM_BUILD_DIRECTORY}/rpmbuild"
rm -rf "${RPM_TOPDIR}"
mkdir -p "${RPM_TOPDIR}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

cp -a "${ORKSIP_INSTALL_ROOT}"/* "${RPM_TOPDIR}/SOURCES/" 2>/dev/null || true
cp -v "${WORKSPACE_ROOT}/orkaudio/config-linux-template.xml"     "${RPM_TOPDIR}/SOURCES/"
cp -v "${WORKSPACE_ROOT}/orkaudio/logging-linux-template.properties" "${RPM_TOPDIR}/SOURCES/"

log "  RPM tree ready at ${RPM_TOPDIR}"

log "  Generating orkaudio.spec..."

SPEC_FILE="${RPM_TOPDIR}/SPECS/orkaudio.spec"

# Top of spec -- bash expands ${VERSION}/${RELEASE} here
cat > "${SPEC_FILE}" << SPECEOF
Name:           orkaudio
Version:        ${VERSION}
Release:        ${RELEASE}%{?dist}
Summary:        VoIP media capture and recording daemon

License:        GPLv3
URL:            https://github.com/Cistera-Networks/OrekaSipStack

Requires:       bash
Requires:       libpcap
Requires:       libsndfile
Requires:       apr
Requires:       speex
Requires:       log4cxx
Requires:       opus
Requires:       xerces-c
Requires:       openssl-libs
Requires:       elfutils-libs
Requires:       libunwind
Requires:       libpcap.so.1()(64bit)
Requires:       libsndfile.so.1()(64bit)
Requires:       libapr-1.so.0()(64bit)

%description
orkaudio is the audio capture and storage daemon from the OrekaSipStack
project. It captures VoIP signalling and RTP media from the network using
libpcap, extracts call metadata, compresses and stores audio recordings,
and optionally reports them to orktrack.

Supported protocols: SIP (including SIPREC), Cisco Skinny (SCCP), IAX2,
H.323, raw RTP/RTCP.

Included codecs:
  G.711 u-law / A-law, GSM, iLBC, G.722, G.726, G.729, SILK, Opus, Speex

Storage formats: native (.mcf), GSM, u-law, A-law, PCM/WAV, Opus/Ogg
SPECEOF

# Remainder of spec -- quoted heredoc, no shell expansion
cat >> "${SPEC_FILE}" << 'SPECEOF'

%prep
:
%{nil}

%build
:
%{nil}

%check
test -f %{_sourcedir}/usr/sbin/orkaudio    || { echo "ERROR: orkaudio binary not found"    >&2; exit 1; }
test -f %{_sourcedir}/usr/lib/liborkbase.* || { echo "ERROR: liborkbase not found"         >&2; exit 1; }
test -f %{_sourcedir}/usr/lib/libvoip.*    || { echo "ERROR: libvoip plugin not found"     >&2; exit 1; }

%install
rm -rf %{buildroot}

# ---- Binaries ----
install -D -m 0755 %{_sourcedir}/usr/sbin/orkaudio  %{buildroot}/usr/sbin/orkaudio

# ---- Core library ----
for f in %{_sourcedir}/usr/lib/liborkbase.*; do
    [ -f "$f" ] || continue
    bname="$(basename "$f")"
    install -D -m 0755 "$f" "%{buildroot}/usr/lib/${bname}"
done

# ---- Sub-libraries (serializers, messages, audiofile, filters) ----
for libdir in serializers messages audiofile filters; do
    for f in %{_sourcedir}/usr/lib/orkbase*/${libdir}/*.so*; do
        [ -f "$f" ] || continue
        bname="$(basename "$f")"
        install -D -m 0755 "$f" "%{buildroot}/usr/lib/${bname}"
    done
done

# ---- VoIP capture plugin ----
for f in %{_sourcedir}/usr/lib/libvoip.so* %{_sourcedir}/usr/lib/libvoip.la; do
    [ -f "$f" ] || continue
    bname="$(basename "$f")"
    install -D -m 0755 "$f" "%{buildroot}/usr/lib/${bname}"
done

# ---- Generator plugin (testing) ----
for f in %{_sourcedir}/usr/lib/libgenerator.so* %{_sourcedir}/usr/lib/libgenerator.la; do
    [ -f "$f" ] || continue
    bname="$(basename "$f")"
    install -D -m 0755 "$f" "%{buildroot}/usr/lib/${bname}"
done

# ---- Optional plugins ----
if [ -d %{_sourcedir}/usr/lib/orkaudio/plugins ]; then
    for f in %{_sourcedir}/usr/lib/orkaudio/plugins/*.so*; do
        [ -f "$f" ] || continue
        bname="$(basename "$f")"
        install -D -m 0755 "$f" "%{buildroot}/usr/lib/orkaudio/plugins/${bname}"
    done
fi

# ---- Config files ----
install -D -m 0644 %{_sourcedir}/config-linux-template.xml \
    %{buildroot}%{_sysconfdir}/orkaudio/config.xml
install -D -m 0644 %{_sourcedir}/logging-linux-template.properties \
    %{buildroot}%{_sysconfdir}/orkaudio/logging.properties

# ---- Runtime directories ----
install -d -m 0755 %{buildroot}/var/log/orkaudio
install -d -m 0755 %{buildroot}/opt/orkaudio/audio

# ---- G.729 codec library (built from source) ----
if [ -f /usr/lib64/libbcg729.so ]; then
    install -D -m 0755 /usr/lib64/libbcg729.so   %{buildroot}/usr/lib64/libbcg729.so
elif [ -f /usr/lib/libbcg729.so ]; then
    install -D -m 0755 /usr/lib/libbcg729.so      %{buildroot}/usr/lib/libbcg729.so
fi

%files
/usr/sbin/orkaudio
/usr/lib/liborkbase.so*
/usr/lib/liborkbase.la
/usr/lib/libserializers.*
/usr/lib/libmessages.*
/usr/lib/libaudiofile.*
/usr/lib/libgsm.*
/usr/lib/libgsm610.*
/usr/lib/libilbc.*
/usr/lib/libaudiogain.*
/usr/lib/libg722codec.*
/usr/lib/libspeexfilter.*
/usr/lib/libg726codecs.*
/usr/lib/libg72x.*
/usr/lib/libopuscodec.*
/usr/lib/libvoip.so*
/usr/lib/libvoip.la
/usr/lib/libgenerator.so*
/usr/lib/libgenerator.la
/usr/lib/orkaudio/plugins/
%dir %{_sysconfdir}/orkaudio
%config(noreplace) %{_sysconfdir}/orkaudio/config.xml
%config(noreplace) %{_sysconfdir}/orkaudio/logging.properties
%dir /var/log/orkaudio
%dir /opt/orkaudio
%dir /opt/orkaudio/audio

%post
chmod 755 /var/log/orkaudio 2>/dev/null || true
mkdir -p /opt/orkaudio/audio
chmod 755 /opt/orkaudio/audio
ldconfig

echo ""
echo "===================================================================="
echo "  OrekaSipStack (orkaudio) installed."
echo ""
echo "  Daemon:      /usr/sbin/orkaudio"
echo "  Config:      /etc/orkaudio/config.xml"
echo "  Logging:     /etc/orkaudio/logging.properties"
echo "  Logs:        /var/log/orkaudio/"
echo "  Recordings:  /opt/orkaudio/audio/"
echo ""
echo "  Quick start:"
echo "    1. Edit /etc/orkaudio/config.xml"
echo "       - Set CapturePlugin to libvoip.so"
echo "       - Add your network devices under <VoIpPlugin><Devices>"
echo "    2. Ensure CAP_NET_RAW and CAP_NET_ADMIN:"
echo "         setcap cap_net_raw,cap_net_admin+ep /usr/sbin/orkaudio"
echo "    3. Tune kernel buffer:"
echo "         echo 'net.core.rmem_max = 16777216' >> /etc/sysctl.d/90-orkaudio.conf"
echo "         sysctl --system"
echo "    4. Run: orkaudio debug"
echo "===================================================================="
echo ""

%preun
if [ $1 -eq 0 ]; then
    :
fi

%changelog
* __CHANGELOG_DATE__ Cistera Build System <build@cistera.com> - __VERSION__-__RELEASE__
- Automated Jenkins build targeting AlmaLinux 10 (kernel 6.12, GCC 14.3)
SPECEOF

# Substitute placeholders in the changelog
sed -i "s/__VERSION__/${VERSION}/g"                "${SPEC_FILE}"
sed -i "s/__RELEASE__/${RELEASE}/g"                "${SPEC_FILE}"
sed -i "s/__CHANGELOG_DATE__/${CHANGELOG_DATE}/g"  "${SPEC_FILE}"

log "  Spec written to ${SPEC_FILE}"

# =============================================================================
# Build the RPM
# =============================================================================
log "  Running rpmbuild..."

QA_RPATHS=0x0001 rpmbuild -bb \
    --define "_topdir ${RPM_TOPDIR}" \
    "${SPEC_FILE}"

log "  rpmbuild completed successfully."

# =============================================================================
# Step 6 -- Collect and stage
# =============================================================================
log "Step 6/6  Collecting and staging RPM..."

ARCH="$(uname -m)"
RPM_SRC="${RPM_TOPDIR}/RPMS/${ARCH}/orkaudio-${VERSION}-${RELEASE}*.rpm"

RPM_FILE=$(ls ${RPM_SRC} 2>/dev/null | head -1)

if [ -z "${RPM_FILE}" ]; then
    log "ERROR: No RPM found matching ${RPM_SRC}"
    exit 1
fi

RPM_NAME="$(basename "${RPM_FILE}")"

mkdir -p "${GENERATED_RPM_DIRECTORY}"

cp -v "${RPM_FILE}" "${GENERATED_RPM_DIRECTORY}/${RPM_NAME}"
cp -v "${RPM_FILE}" "${GENERATED_RPM_DIRECTORY}/orkaudio-${VERSION}-${RELEASE}.${ARCH}.rpm"

log "============================================================================="
log "Build completed successfully"
log "  RPM  : ${GENERATED_RPM_DIRECTORY}/${RPM_NAME}"
log "  Arch : ${ARCH}"
log "============================================================================="

log ""
log "RPM contents:"
rpm -qlp "${GENERATED_RPM_DIRECTORY}/${RPM_NAME}" 2>/dev/null || true

log ""
log "RPM metadata:"
rpm -qip "${GENERATED_RPM_DIRECTORY}/${RPM_NAME}" 2>/dev/null || true

# =============================================================================
# Smoke test
# =============================================================================
log ""
log "Smoke test: verifying orkaudio binary starts..."

RPM_EXTRACT_DIR="$(mktemp -d)"
cd "${RPM_EXTRACT_DIR}"
rpm2cpio "${GENERATED_RPM_DIRECTORY}/${RPM_NAME}" | cpio -idm 2>/dev/null

if [ -x ./usr/sbin/orkaudio ]; then
    OUTPUT=$(timeout 3 ./usr/sbin/orkaudio version 2>&1 || true)
    log "  orkaudio version output: ${OUTPUT}"
    if echo "$OUTPUT" | grep -qiE "version|orkaudio|usage"; then
        log "  PASS: orkaudio binary executes"
    else
        log "  WARN: orkaudio started but output unexpected"
    fi
else
    log "  WARN: could not extract orkaudio from RPM for smoke test"
fi

rm -rf "${RPM_EXTRACT_DIR}"

log ""
log "============================================================================="
log "OrekaSipStack (orkaudio) build and packaging finished."
log "============================================================================="

exit 0
