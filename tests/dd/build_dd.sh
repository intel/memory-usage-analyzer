#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
rm -rf ./coreutils-9.5
yum install -y gperf texinfo texinfo-tex
wget https://gnu.mirror.constant.com/coreutils/coreutils-9.5.tar.xz && tar -xvf coreutils-9.5.tar.xz
#git clone https://git.savannah.gnu.org/git/coreutils.git
cd coreutils-9.5
./bootstrap
export FORCE_UNSAFE_CONFIGURE=1 ;./configure --prefix=/opt/coreutils-9.5 --disable-doc CFLAGS="-O2 -Wno-error"
make -j$(nproc)
sudo make install
