#!/usr/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Set up the Memory Usage Analyzer environment on Ubuntu/Debian or CentOS/RHEL.
# Installs the OS packages needed by the redis/memtier tests, accel-config for
# the IAA devices, plus the python dependencies. The iaa-venv virtual
# environment and the repo install are handled by tests/redis/benchmark.sh.
#
# Usage:
#   sudo ./tests/scripts/install_dependencies.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root (use sudo)." >&2
    exit 1
fi

OS="Centos"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) OS="Ubuntu" ;;
        *) OS="Centos" ;;
    esac
fi
echo "Detected OS family: $OS"

echo "== Installing system packages =="
if [ "$OS" == "Ubuntu" ]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y \
        build-essential autoconf automake libtool pkg-config \
        git wget curl unzip vim \
        numactl libevent-dev libpcre3-dev libssl-dev zlib1g-dev \
        libxml2-dev libxslt1-dev libffi-dev \
        libjson-c-dev uuid-dev libkmod-dev libudev-dev \
        python3 python3-dev python3-pip python3-venv python-is-python3
    apt-get install -y accel-config || true
    apt-get install -y libaccel-config1 libaccel-config-dev || true
else
    yum install -y \
        gcc gcc-c++ make autoconf automake libtool pkgconfig \
        git wget curl unzip vim \
        numactl numactl-devel libevent libevent-devel pcre-devel \
        openssl-devel zlib-devel libxml2-devel libxslt-devel libffi-devel \
        json-c-devel libuuid-devel kmod-devel systemd-devel \
        python3 python3-devel python3-pip
    for pkg in accel-config accel-config-libs accel-config-devel; do
        yum install -y "$pkg" || true
    done
    # CentOS has no python-is-python3 package; provide the `python` alias.
    if ! command -v python &> /dev/null; then
        alternatives --set python /usr/bin/python3 2>/dev/null || \
            ln -sf /usr/bin/python3 /usr/bin/python
    fi
fi

if ! command -v accel-config &> /dev/null; then
    echo "== Building accel-config from source =="
    src_dir="$(mktemp -d)"
    git clone https://github.com/intel/idxd-config.git "${src_dir}/idxd-config"
    (
        cd "${src_dir}/idxd-config"
        ./autogen.sh
        ./configure CFLAGS='-g -O2' --prefix=/usr --sysconfdir=/etc --libdir=/usr/lib64 --disable-docs --enable-test=yes
        make
        make install
    )
    ldconfig
    rm -rf "$src_dir"
fi
accel-config --version || true

echo "Environment ready. Kernel: $(uname -r)"
