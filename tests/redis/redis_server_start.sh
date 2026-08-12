#!/bin/bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

no_of_servers=${1:-1}
redis_server_cpu_spec=${2:-2}
redis_server_numa_node=${3:-}
redis_server_cpus_per_instance=${4:-1}

# kill existing redis servers
pkill -f redis-server
sleep 1

REDIS_CONFIGS="./redis_configs"
mkdir -p ${REDIS_CONFIGS} 


is_primary_core() {
  local c=$1
  local first
  first=$(cut -d, -f1 /sys/devices/system/cpu/cpu"$c"/topology/thread_siblings_list 2>/dev/null)
  [[ "$c" -eq "$first" ]]
}

start_redis_server() {
  local use_core_list=0
  local -a selected_cores=()

  if [[ "$redis_server_cpu_spec" =~ ^list:(.+)$ ]]; then
    use_core_list=1
    IFS=',' read -r -a selected_cores <<< "${BASH_REMATCH[1]}"
    local required
    required=$(( no_of_servers * redis_server_cpus_per_instance ))
    if [[ "${#selected_cores[@]}" -lt "$required" ]]; then
      echo "ERROR: insufficient cores in explicit list (${#selected_cores[@]}) for ${no_of_servers} servers x ${redis_server_cpus_per_instance} cores"
      exit 1
    fi
  fi

  port_no=9001
  # Set up servers
  for ((i=1;i<=$no_of_servers;i++)); do
     cp -f redis.conf ${REDIS_CONFIGS}/temp-$i.conf
     echo "Update port number in temp-$i redis conf ...."
     sed -i "s/^port 6379$/port $port_no/" ${REDIS_CONFIGS}/temp-$i.conf
     sed -i "s/^unixsocket \/tmp\/redis.sock$/unixsocket \/tmp\/redis-$i.sock/" ${REDIS_CONFIGS}/temp-$i.conf
     port_no=$((port_no+1))
   done

  if [[ "$use_core_list" -eq 0 ]]; then
    # Snap to the first primary core at or after redis_server_cpu_spec.
    core=${redis_server_cpu_spec}
    while ! is_primary_core "$core"; do
      core=$(( core + 1 ))
    done
  fi

  for (( i=1; i<=$no_of_servers; i++)); do
    if [[ "$use_core_list" -eq 1 ]]; then
      local first_idx last_idx
      first_idx=$(( (i - 1) * redis_server_cpus_per_instance ))
      last_idx=$(( first_idx + redis_server_cpus_per_instance - 1 ))
      core=$(IFS=,; echo "${selected_cores[*]:$first_idx:$redis_server_cpus_per_instance}")
      echo "Starting redis server: ${i} on cores ${core}"
    else
      echo "Starting redis server: ${i} on core ${core}"
    fi
    cmd="numactl -C $core --localalloc redis-server ./redis_configs/temp-$i.conf --save \"\" &"
    echo $cmd; eval $cmd
    if [[ "$use_core_list" -eq 0 ]]; then
      core=$(( core + 1 ))
    fi
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
