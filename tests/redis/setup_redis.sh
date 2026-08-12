#!/usr/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Install Redis

#redis_version=`redis-server -v | awk -F" " '{print $3}'`
#echo $redis_version
#if [ ${redis_version} == "v=6.0.10" ]

OS="Centos"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) OS="Ubuntu" ;;
        *) OS="Centos" ;;
    esac
fi

# Install dependencies
#
if [ "$OS" == "Centos" ];then
    yum install libevent libevent-devel pcre-devel numactl -y
else
    apt install -y numactl build-essential autoconf automake libtool pkg-config \
			                       libevent-dev libssl-dev zlib1g-dev
fi

if ! command -v redis-server  &> /dev/null 
then
    echo "Installing Redis"
    wget https://download.redis.io/releases/redis-8.8.0.tar.gz
    tar xzf redis-8.8.0.tar.gz
    cd redis-8.8.0
    make
    make install
else
    redis-server -v
fi

if ! command -v memtier_benchmark  &> /dev/null 
then
    if [ "$OS" == "Centos" ];then
        yum install libevent libevent-devel pcre-devel numactl -y
    else
        apt install -y build-essential autoconf automake libtool pkg-config \
                       libevent-dev libpcre3-dev numactl
    fi
    git clone https://github.com/RedisLabs/memtier_benchmark.git
    cd memtier_benchmark
    git checkout 2.4.0
    autoreconf -ivf
    ./configure
    make
    make install
else
    memtier_benchmark -v 
fi
