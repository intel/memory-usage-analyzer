#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

no_of_servers=${1:-1}
redis_server_cpu_start=${2:-2}

# kill existing redis servers
pkill -f redis-server
sleep 1

REDIS_CONFIGS="./redis_configs"
mkdir -p ${REDIS_CONFIGS} 


start_redis_server() {
  port_no=9001
  # Set up servers
  for ((i=1;i<=$no_of_servers;i++)); do
     cp -f redis.conf ${REDIS_CONFIGS}/temp-$i.conf
     echo "Update port number in temp-$i redis conf ...."
     sed -i "s/^port 6379$/port $port_no/" ${REDIS_CONFIGS}/temp-$i.conf
     sed -i "s/^unixsocket \/tmp\/redis.sock$/unixsocket \/tmp\/redis-$i.sock/" ${REDIS_CONFIGS}/temp-$i.conf
     port_no=$((port_no+1))
   done
  
  core=${redis_server_cpu_start}
  for (( i=1; i<=$no_of_servers; i++)); do
    echo "Starting redis server: ${i}"
    core1=$(( core ))
    #cmd="numactl -C $core1,$core2 --localalloc redis-server ./redis_configs/temp-$i.conf --save \"\" &"
    cmd="numactl -C $core1 --localalloc redis-server ./redis_configs/temp-$i.conf --save \"\" &"
    echo $cmd; eval $cmd 
    core=$((core + 1))
    # Sleep to make sure ith server is done binding with the address before launching (i+1)th server.
    #  Without the sleep sometimes (i+1)th  server crash with "Bind error (Address already in use)" error.
    sleep 2
  done
  echo "(${no_of_servers}) Redis server(s) running!"
}

clean_up() {
  echo "Cleaning up ...."
  for (( i=1; i<=$no_of_servers; i++)); do
    rm -f ${REDIS_CONFIGS}/temp-$i.conf
  done
  pkill -f redis-server
  echo "Clean up Done"

}

clean_up
start_redis_server
