#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
no_of_servers=${1:-1}
#db_file=${2-import_movies_10000r_10c.redis}
db_file=${2-import_movies_10000r_10c.redis}
db_file_type=$(echo "${db_file##*.}")
cpu_start=${3:-2}
log_dir=${4-test}
mode=${5-"all"}


# Clear caches
clear_cache(){
    ulimit -s unlimited
    sync; echo 3 | tee /proc/sys/vm/drop_caches > /dev/null 1>2&
}

clean_up() {
  echo "Cleaning up ...."
  port_no=9001
  for (( i=1; i<=$no_of_servers; i++)); do
    redis-cli -p $port_no shutdown > /dev/null 2>&1
    rm -f ${REDIS_CONFIGS}/temp-$i.conf
    port_no=$((port_no+1))
  done
  #pkill -f redis-server
  while read pid; do
     kill -TERM $pid
  done < /sys/fs/cgroup/redisbench/cgroup.procs

  echo "Clean up Done"
  sleep 5

}

get_max_keys() {
    port_no=$1
    max_keys=$(numactl --cpunodebind=0 --localalloc redis-cli -h localhost -p $port_no info | grep  db0:keys | cut -d, -f1 | cut -d= -f2) 
    echo "Max Keys: ${max_keys}"
    
}

populate_redis_server() {
  port_no=$1
  db_file=$2
  redis-cli -h localhost -p $port_no --pipe < $db_file

}

wait_redis_server() {
  port_no=$1
  # Wait till database is loaded
  #while [ $(redis-cli -h localhost -p $port_no info | grep -c loading:1) == "1" ]; do
  #  echo "Waiting for database loading. Status: $(redis-cli -h localhost -p $port_no info | grep -c loading:1)"
  #  sleep 10
  #done
  until pgrep redis-server > /dev/null ; do
       sleep 1
  done
  echo "Redis server started"
  until redis-cli -h localhost -p $port_no ping | grep -q PONG; do
      sleep 1
  done
  echo "Redis is ready"
}

populate_server_from_redis(){
   echo "Check if redis servers are ready ..."
   port_no=9001
   for (( i=1; i<=$no_of_servers;i++)); do
     wait_redis_server $port_no
     port_no=$((port_no+1))
   done
   echo "Servers are ready ..."

   # populate the databse if the input if .redis
   if [ ${db_file##*\.} == "redis" ]; then
       echo "Populating database started (parallel loading)"
       port_no=9001
       pids=()
       for (( i=1; i<=$no_of_servers;i++)); do
         echo "Starting data population for Redis server ${i} on port $port_no in background..."
         populate_redis_server $port_no $db_file &
         pids+=($!)
         port_no=$((port_no+1))
       done
       
       # Wait for all population processes to complete
       echo "Waiting for all Redis data population processes to complete..."
       for pid in "${pids[@]}"; do
         wait $pid
         echo "Population process $pid completed"
       done
       echo "Populating database done (all servers loaded in parallel)"
   fi

}


populate_redis_server_from_csv() {

   echo "Check if redis servers are ready ..."
   port_no=9001
   for (( i=1; i<=$no_of_servers;i++)); do
     wait_redis_server $port_no
     port_no=$((port_no+1))
   done
   echo "$no_of_servers Server(s) ready ..."

   port_no=9001
   # populate the databse if the input if .csv
   echo "Populating database started (parallel loading)"
   pids=()
   for (( i=1; i<=$no_of_servers;i++)); do
       echo "Starting data population for Redis server on port $port_no in background..."

        num_of_lines=`wc -l $db_file | awk '{print $1}'`
        # Removed header from csv
        num_of_lines=$((num_of_lines-1))
        echo "Adding ${num_of_lines} keys"
        cpu1=$(( cpu_start + 2*i ))
        cpu2=$(( cpu_start + 2*i + 1))
	cmd=(numactl -C $cpu1,$cpu2 --localalloc memtier_benchmark --server=localhost --port=$port_no --protocol=redis --ratio=1:0 --key-pattern=P:P -t 1 -c 1 --data-import=$db_file -n  ${num_of_lines} )
	echo "Running: ${cmd[*]}"
	"${cmd[@]}" &
	pids+=("$!")
        port_no=$((port_no+1))
    done

    # Wait for all population processes to complete
    echo "Waiting for all Redis data population processes to complete..."
    for pid in "${pids[@]}"; do
        wait $pid
        echo "Population process $pid completed"
    done
    echo "Populating database done (all servers loaded in parallel)"

    #check the contents
    port_no=9001
    for (( i=1; i<=$no_of_servers; i++)); do
      max_keys=0
      get_max_keys ${port_no}
      #if [ ${max_keys} == 0 ]; then
      if [ -z "$max_keys" ] || [ "$max_keys" -eq 0 ]; then
	  echo "Invalid number of keys"
	  exit
      fi
      echo "port:$port_no, max_keys=$max_keys"
      port_no=$((port_no+1))
    done
}


run_memtier(){

    local duration=$1
    # g.6 stddev = range/5
    # g.10 stddev = range/10
    # g.20 stddev = range/20
    # g.30 stddev = range/30 
    sd_ratio=6
    # Get total number of keys. This will help with controlling the ranges to sweep
    port_no=9001
    pids=()
    for (( i=1; i<=$no_of_servers; i++)); do
      max_keys=0
      get_max_keys ${port_no}
      key_spread=$((max_keys/sd_ratio))
      if [ ${max_keys} == 0 ]; then
	  echo "Invalid number of keys"
	  exit
      fi
      # Force to only specific CPU core
      echo "Run memtier benchmark instance:${i} ... "
      cpu1=$(( cpu_start + 2*i ))
      cpu2=$(( cpu_start + 2*i + 1))
      cmd=(numactl -C $cpu1,$cpu2 --localalloc memtier_benchmark -s localhost -p $port_no --key-prefix= --key-minimum=1 --key-maximum=${max_keys} --key-stddev=${key_spread} --test-time=$duration --show-config --threads=4 --clients=4 --pipeline=1  --ratio=0:1 --key-pattern=G:G )
      echo "Running: ${cmd[*]}  > ${log_dir}/run_${i}.log"
      "${cmd[@]}" > "${log_dir}/run_${i}.log"  &
      pids+=($!)
      port_no=$((port_no+1))

    done
    # Wait for all client processes to complete
    echo "Waiting for all load generation processes to complete..."
    for pid in "${pids[@]}"; do
        wait $pid
        echo "Load generation  process $pid completed"
    done
    echo "Load generations process(s) done"

    clean_up
}

#clear_cache
#populate_redis_server_from_${db_file_type}
#echo "Running Measurement stage"
#run_memtier 10
#clean_up

[[ "$mode" == "prefill" || "$mode" == "all" ]] && clear_cache; populate_redis_server_from_${db_file_type}
echo "Done with prefill"
[[ "$mode" == "run"     || "$mode" == "all" ]] && run_memtier 120
echo "Done with run"
