#!/usr/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Set up the Memory Usage Analyzer environment on Ubuntu/Debian or CentOS/RHEL.
# Installs the OS packages needed by the redis/memtier tests, accel-config for
# the IAA devices, and the pinned Python. It also installs this repository in
# editable mode (pip install -e) inside an isolated virtualenv, then symlinks
# the helper scripts from setup.py onto PATH.
#
# Usage:
#   sudo ./tests/scripts/install_dependencies.sh

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
ACCEL_CONFIG_VERSION="${ACCEL_CONFIG_VERSION:-4.1.8}"
ACCEL_CONFIG_TAG="accel-config-v${ACCEL_CONFIG_VERSION}"
IDXD_CONFIG_REPO="https://github.com/intel/idxd-config.git"

# Kernel release used to pick the kernel-specific cpupower/linux-tools package.
# Defaults to the running kernel; override to target a different one.
KERNEL_VER="${KERNEL_VER:-$(uname -r)}"

# Python release pinned across systems to avoid host-to-host variation.
PYTHON_VERSION="${PYTHON_VERSION:-3.11}"

# Full patch release used only for the from-source fallback build. Must match
# PYTHON_VERSION's major.minor so the resulting binary is python${PYTHON_VERSION}.
PYTHON_SRC_VERSION="${PYTHON_SRC_VERSION:-3.11.9}"
PYTHON_SRC_URL="https://www.python.org/ftp/python/${PYTHON_SRC_VERSION}/Python-${PYTHON_SRC_VERSION}.tgz"

# Repository root (two levels up from tests/scripts/) and the package installed
# from it in editable mode via setup.py.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PACKAGE_NAME="memoryusageanalyzer"

# Isolated virtualenv for the editable install. Installing here (rather than
# system-wide) keeps pip away from the distro's dpkg-managed dist-packages,
# which it cannot uninstall (e.g. Debian's urllib3 has no RECORD file).
VENV_DIR="${VENV_DIR:-${REPO_ROOT}/iaa-venv}"

# Directory the helper scripts are symlinked into so they land on PATH.
BIN_DIR="${BIN_DIR:-/usr/local/bin}"

# sudo resets PATH to sudoers' secure_path, which on RHEL/CentOS (and some
# hardened Ubuntu setups) omits /usr/local/bin. Put BIN_DIR on PATH so the
# symlinked helper scripts are found during verification regardless of sudo.
case ":${PATH}:" in
    *":${BIN_DIR}:"*) ;;
    *) export PATH="${BIN_DIR}:${PATH}" ;;
esac

# Helper scripts (basenames) that setup.py installs onto PATH.
mapfile -t REPO_SCRIPTS < <(grep -oE "'[^']+\.(py|sh)'" "${REPO_ROOT}/setup.py" 2>/dev/null | tr -d "'" | xargs -r -n1 basename | sort -u)

# Tools whose presence/version is confirmed in the final summary.
VERIFY_TOOLS=(accel-config cpupower "python${PYTHON_VERSION}" git wget make gcc numactl pkg-config)

OS="Centos"                 # set by detect_os()
declare -A STATUS=()        # step name -> OK | FAILED | SKIPPED ...

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
track() {
    # Run a command and record its outcome under a named step.
    local name="$1"; shift
    if "$@"; then
        STATUS["$name"]="OK"
    else
        STATUS["$name"]="FAILED"
    fi
}

ensure_root() {
    # Run as root. If already root (e.g. logged in as root), run directly
    # without sudo -- this also preserves root's PATH so the /usr/local/bin
    # symlinks are visible during verification. If invoked by a normal user,
    # transparently re-exec the whole script under sudo.
    if [[ "$(id -u)" -eq 0 ]]; then
        return
    fi
    if command -v sudo &>/dev/null; then
        echo "Not running as root; re-executing under sudo..."
        exec sudo -E bash "$0" "$@"
    fi
    echo "This script must be run as root, and sudo is not available." >&2
    exit 1
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "$ID" in
            ubuntu|debian) OS="Ubuntu" ;;
            *)             OS="Centos" ;;
        esac
    fi
    echo "Detected OS family: $OS"
}

tool_version() {
    # Best-effort one-line version string for a tool.
    case "$1" in
        accel-config) accel-config --version 2>/dev/null | head -1 ;;
        cpupower)     cpupower --version 2>/dev/null | head -1 ;;
        *)            "$1" --version 2>&1 | head -1 ;;
    esac
}

print_tool_verification() {
    # Confirm each expected tool is actually installed and usable.
    local tool status
    echo "  Tool Verification"
    echo "=============================="
    for tool in "${VERIFY_TOOLS[@]}"; do
        if ! command -v "$tool" &>/dev/null; then
            status="MISSING"
        elif [[ "$tool" == "cpupower" ]] && ! cpupower frequency-info &>/dev/null; then
            status="PRESENT (not functional on ${KERNEL_VER})"
        else
            status="OK  $(tool_version "$tool")"
        fi
        printf "  %-22s %s\n" "$tool" "$status"
    done
    echo "=============================="
}

print_python_package_verification() {
    # Report the editable install: the package version, the scripts it put on
    # PATH, and the Python libraries pulled in from setup.py.
    local py="${VENV_DIR}/bin/python" info ver dep script path
    echo "  Python Package (${PACKAGE_NAME})"
    echo "=============================="
    if [[ ! -x "$py" ]] || ! info="$("$py" -m pip show "$PACKAGE_NAME" 2>/dev/null)"; then
        printf "  %-24s %s\n" "$PACKAGE_NAME" "NOT INSTALLED"
        echo "=============================="
        return
    fi
    ver="$(awk -F': ' '/^Version:/{print $2}' <<<"$info")"
    printf "  %-24s %s\n" "$PACKAGE_NAME" "OK  (v${ver}, ${VENV_DIR})"

    echo "  -- Added scripts (PATH) --"
    for script in ${REPO_SCRIPTS[@]+"${REPO_SCRIPTS[@]}"}; do
        if path="$(command -v "$script" 2>/dev/null)"; then
            printf "    %-32s %s\n" "$script" "$path"
        else
            printf "    %-32s %s\n" "$script" "MISSING"
        fi
    done

    echo "  -- Installed libraries --"
    awk -F': ' '/^Requires:/{print $2}' <<<"$info" | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
        | while read -r dep; do
        [[ -z "$dep" ]] && continue
        ver="$("$py" -m pip show "$dep" 2>/dev/null | awk -F': ' '/^Version:/{print $2}')"
        printf "    %-24s %s\n" "$dep" "${ver:-?}"
    done
    echo "=============================="
}

print_summary() {
    local fail=0 step
    echo ""
    echo "=============================="
    echo "  Installation Summary"
    echo "=============================="
    for step in "${!STATUS[@]}"; do
        printf "  %-40s %s\n" "$step" "${STATUS[$step]}"
        [[ "${STATUS[$step]}" == "FAILED" ]] && fail=1
    done
    echo "=============================="
    print_tool_verification
    print_python_package_verification
    if [[ "$fail" -eq 1 ]]; then
        echo "  Result: SOME STEPS FAILED"
    else
        echo "  Result: ALL STEPS SUCCEEDED"
    fi
    echo "=============================="
}

# ---------------------------------------------------------------------------
# System packages
# ---------------------------------------------------------------------------
apt_update() {
    # The command-not-found package ships an APT Post-Invoke-Success hook
    # (cnf-update-db) that crashes with a Python refcount bug on some installs,
    # making `apt-get update` return non-zero even though the update succeeded.
    # Temporarily disable the hook for the duration of the update and always
    # restore it afterwards.
    local hook=/etc/apt/apt.conf.d/50command-not-found
    local moved=0 rc=0
    if [[ -f "$hook" ]]; then
        mv "$hook" "$hook.disabled" && moved=1
    fi
    apt-get update || rc=$?
    [[ "$moved" -eq 1 ]] && mv "$hook.disabled" "$hook"
    return "$rc"
}

install_system_packages_ubuntu() {
    export DEBIAN_FRONTEND=noninteractive
    track "apt-get update" apt_update

    if apt-cache show linux-modules-extra-"$(uname -r)" &>/dev/null; then
        track "linux-modules-extra" apt-get install -y linux-modules-extra-"$(uname -r)"
    else
        STATUS["linux-modules-extra"]="SKIPPED (not available for $(uname -r))"
    fi

    track "system packages" apt-get install -y \
        build-essential autoconf automake libtool pkg-config \
        git wget curl unzip vim \
        numactl libevent-dev libpcre3-dev libssl-dev zlib1g-dev \
        libxml2-dev libxslt1-dev libffi-dev \
        libjson-c-dev uuid-dev libkmod-dev libudev-dev
}

install_system_packages_centos() {
    track "system packages" yum install -y \
        gcc gcc-c++ make autoconf automake libtool pkgconfig \
        git wget curl unzip vim \
        numactl numactl-devel libevent libevent-devel pcre-devel \
        openssl-devel zlib-devel libxml2-devel libxslt-devel libffi-devel \
        json-c-devel libuuid-devel kmod-devel systemd-devel
}

build_python_from_source() {
    # Fallback when the distro package for python${PYTHON_VERSION} is unavailable:
    # install build prerequisites, fetch the official tarball, and `make
    # altinstall` so the pinned interpreter never clobbers the system python.
    local src_dir rc=0
    echo "== Building Python ${PYTHON_SRC_VERSION} from source =="
    if [[ "$OS" == "Ubuntu" ]]; then
        apt-get install -y build-essential wget zlib1g-dev libncurses5-dev \
            libgdbm-dev libnss3-dev libssl-dev libreadline-dev libffi-dev \
            libsqlite3-dev libbz2-dev liblzma-dev uuid-dev || return 1
    else
        yum groupinstall -y "Development Tools" &>/dev/null || true
        yum install -y gcc make wget zlib-devel ncurses-devel gdbm-devel \
            openssl-devel readline-devel libffi-devel sqlite-devel \
            bzip2-devel xz-devel libuuid-devel || return 1
    fi
    src_dir="$(mktemp -d)"
    (
        cd "$src_dir"
        wget -q "$PYTHON_SRC_URL" -O python-src.tgz &&
        tar -xf python-src.tgz &&
        cd "Python-${PYTHON_SRC_VERSION}" &&
        ./configure --enable-optimizations --with-ensurepip=install &&
        make -j"$(nproc)" &&
        make altinstall
    ) || rc=$?
    rm -rf "$src_dir"
    return "$rc"
}

install_repo_package() {
    # Install this repository in editable mode inside an isolated virtualenv,
    # then symlink the helper scripts from setup.py onto PATH. The venv keeps
    # pip from touching the distro's dpkg-managed dist-packages.
    local py="python${PYTHON_VERSION}" script
    echo "== Installing ${PACKAGE_NAME} (editable) into ${VENV_DIR} =="
    if [[ ! -x "${VENV_DIR}/bin/python" ]] && ! "$py" -m venv "$VENV_DIR"; then
        STATUS["${PACKAGE_NAME} (pip install -e)"]="FAILED (venv creation)"
        return
    fi
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip &>/dev/null || true
    if ! "${VENV_DIR}/bin/python" -m pip install -e "$REPO_ROOT"; then
        STATUS["${PACKAGE_NAME} (pip install -e)"]="FAILED"
        return
    fi
    STATUS["${PACKAGE_NAME} (pip install -e)"]="OK"

    # Point the `python` alias at the venv so `python <script>.py` sees the
    # installed dependencies. A plain symlink breaks venv detection, so install
    # a thin exec wrapper instead (rm first: `cat >` would follow the old
    # symlink and clobber the system interpreter).
    rm -f "${BIN_DIR}/python"
    cat > "${BIN_DIR}/python" <<EOF
#!/bin/sh
exec "${VENV_DIR}/bin/python" "\$@"
EOF
    chmod +x "${BIN_DIR}/python"

    # Expose the venv's helper scripts on PATH.
    for script in ${REPO_SCRIPTS[@]+"${REPO_SCRIPTS[@]}"}; do
        [[ -e "${VENV_DIR}/bin/${script}" ]] && ln -sf "${VENV_DIR}/bin/${script}" "${BIN_DIR}/${script}"
    done
}

install_python() {
    # Pin Python to a fixed version on both OS families so hosts don't diverge:
    # the deadsnakes PPA on Ubuntu/Debian, the python${PYTHON_VERSION} module on
    # RHEL/CentOS. Falls back to a source build, then to a manual-install prompt.
    local py="python${PYTHON_VERSION}"
    echo "== Installing Python ${PYTHON_VERSION} =="

    # Preferred path: the distro package.
    if [[ "$OS" == "Ubuntu" ]]; then
        apt-get install -y software-properties-common || true
        if ! ls /etc/apt/sources.list.d/ 2>/dev/null | grep -qi deadsnakes; then
            add-apt-repository -y ppa:deadsnakes/ppa && apt_update
        fi
        apt-get install -y "$py" "${py}-dev" "${py}-venv" || true
    else
        yum install -y "$py" "${py}-devel" "${py}-pip" || true
    fi

    # Fallback: build from source if the package didn't provide the interpreter.
    if ! command -v "$py" &>/dev/null; then
        echo "WARNING: package install of ${py} failed; attempting source build." >&2
        build_python_from_source || true
    fi

    # Neither path produced a usable interpreter: warn and stop.
    if ! command -v "$py" &>/dev/null; then
        STATUS["$py"]="FAILED (install manually)"
        echo "ERROR: Could not install ${py} via package manager or source build." >&2
        echo "       Please install Python ${PYTHON_VERSION} manually and re-run this script." >&2
        print_summary
        exit 1
    fi

    STATUS["$py"]="OK"
    # Bootstrap pip and provide a baseline `python` alias for the pinned
    # interpreter; install_repo_package later replaces it with a venv wrapper so
    # `python <script>.py` sees the installed dependencies.
    "$py" -m ensurepip --upgrade &>/dev/null || true
    ln -sf "$(command -v "$py")" "${BIN_DIR}/python"
}

install_cpupower() {
    # cpupower ships with the kernel-tools package, which is tied to the kernel
    # version. Install the package matching ${KERNEL_VER}; skip gracefully if it
    # is not available (e.g. custom-built kernels have no matching repo package).
    echo "== Installing cpupower (CPU frequency tooling) for ${KERNEL_VER} =="
    if [[ "$OS" == "Ubuntu" ]]; then
        # linux-tools-common provides the /usr/bin/cpupower wrapper; the
        # kernel-specific package provides the actual versioned binary.
        track "linux-tools-common" apt-get install -y linux-tools-common
        local pkg
        for pkg in "linux-tools-${KERNEL_VER}" "linux-cloud-tools-${KERNEL_VER}"; do
            if apt-cache show "$pkg" &>/dev/null; then
                track "$pkg" apt-get install -y "$pkg"
            else
                STATUS["$pkg"]="SKIPPED (not available for ${KERNEL_VER})"
            fi
        done
    else
        # On RHEL/CentOS the cpupower binary ships in kernel-tools.
        track "kernel-tools (cpupower)" yum install -y kernel-tools
    fi
}

install_system_packages() {
    echo "== Installing system packages =="
    if [[ "$OS" == "Ubuntu" ]]; then
        install_system_packages_ubuntu
    else
        install_system_packages_centos
    fi
    install_python
    install_cpupower
}

# ---------------------------------------------------------------------------
# accel-config (pinned version, built from source)
# ---------------------------------------------------------------------------
accel_config_current() {
    # Print the installed base version (e.g. 4.1.8), or nothing if absent.
    command -v accel-config &>/dev/null || return 0
    accel-config --version 2>/dev/null | sed 's/[.-]git.*//; s/^v//'
}

remove_accel_config() {
    if [[ "$OS" == "Ubuntu" ]]; then
        apt-get remove -y accel-config libaccel-config1 libaccel-config-dev &>/dev/null || true
    else
        yum remove -y accel-config accel-config-libs accel-config-devel accel-config-test &>/dev/null || true
    fi
    # Drop a stale source-built binary if the package removal left one behind.
    rm -f /usr/bin/accel-config
}

build_accel_config() {
    local src_dir rc=0
    src_dir="$(mktemp -d)"
    git clone --depth 1 --branch "${ACCEL_CONFIG_TAG}" \
        "${IDXD_CONFIG_REPO}" "${src_dir}/idxd-config" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        (
            cd "${src_dir}/idxd-config"
            ./autogen.sh &&
            ./configure CFLAGS='-g -O2' --prefix=/usr --sysconfdir=/etc \
                --libdir=/usr/lib64 --disable-docs --enable-test=yes &&
            make &&
            # Drop the harmless SELinux "security labeling handle failed"
            # warning emitted by coreutils install when no policy is present.
            make install 2> >(grep -v 'security labeling handle failed' >&2)
        ) || rc=$?
    fi
    ldconfig
    rm -rf "$src_dir"
    return "$rc"
}

ensure_accel_config() {
    # Install the pinned accel-config version, replacing any other version.
    local current
    current="$(accel_config_current)"

    if [[ "$current" == "$ACCEL_CONFIG_VERSION" ]]; then
        STATUS["accel-config ${ACCEL_CONFIG_VERSION}"]="OK (already installed)"
        return
    fi

    if [[ -n "$current" ]]; then
        echo "== accel-config $current found, want ${ACCEL_CONFIG_VERSION}; removing and rebuilding =="
        remove_accel_config
    else
        echo "== accel-config not found; building ${ACCEL_CONFIG_TAG} from source =="
    fi

    track "accel-config ${ACCEL_CONFIG_TAG} (source build)" build_accel_config
    accel-config --version || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    ensure_root "$@"
    detect_os
    install_system_packages
    ensure_accel_config
    install_repo_package
    echo "Environment ready. Kernel: $(uname -r)"
    print_summary
}

main "$@"
