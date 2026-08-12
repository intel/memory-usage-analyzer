#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
rm -rf ./coreutils-9.5
# Install build prerequisites on both Ubuntu (apt-get) and CentOS (dnf/yum).
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y build-essential autoconf automake gperf texinfo wget xz-utils
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y gcc make autoconf automake gperf texinfo texinfo-tex wget xz
elif command -v yum >/dev/null 2>&1; then
    yum install -y gcc make autoconf automake gperf texinfo texinfo-tex wget xz
else
    echo "WARNING: no supported package manager (apt-get/dnf/yum); please install: gcc make autoconf automake gperf texinfo wget xz" >&2
fi
wget https://gnu.mirror.constant.com/coreutils/coreutils-9.5.tar.xz && tar -xvf coreutils-9.5.tar.xz
#git clone https://git.savannah.gnu.org/git/coreutils.git
cd coreutils-9.5
./bootstrap
export FORCE_UNSAFE_CONFIGURE=1 ;./configure --prefix=/opt/coreutils-9.5 --disable-doc CFLAGS="-O2 -Wno-error"
make -j$(nproc)
sudo make install
