#!/usr/bin/bash
SCRIPT_DIR=$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)

cd /opt/
git clone --recursive https://github.com/intel/pcm.git
cd pcm
mkdir build
cd build
cmake ..
cmake --build . --parallel
make install
cp ${SCRIPT_DIR}/bhs-power-mode.sh /usr/local/sbin/
chmod +x /usr/local/sbin/bhs-power-mode.sh

