#!/usr/bin/bash
second_socket=$(lscpu --parse=SOCKET | awk -F, '!/^#/ && $1 != "" { sockets[$1]=1 } END { n=asorti(sockets, ordered); if (n >= 2) print ordered[2] }')

if [[ -z "$second_socket" ]]; then
	echo "NA,,"
	exit 0
fi

node=$(lscpu --parse=SOCKET,NODE | awk -F, -v socket="$second_socket" '!/^#/ && $1==socket { print $2; exit }')
node_path="/sys/devices/system/node/node$node"

if [[ -n "$node" && -r "$node_path/cpulist" ]]; then
	cpus=$(tr ',' '\n' <"$node_path/cpulist" | while read -r r; do [[ $r == *-* ]] && { IFS=- read -r a b <<<"$r"; seq "$a" "$b"; } || echo "$r"; done)
else
	# Fallback for systems without NUMA node directories: derive CPUs from second socket.
	cpus=$(lscpu --parse=CPU,SOCKET | awk -F, -v socket="$second_socket" '!/^#/ && $2==socket { print $1 }')
fi

prim=$(for c in $cpus; do s=$(cut -d, -f1 /sys/devices/system/cpu/cpu"$c"/topology/thread_siblings_list); [[ "$c" -eq "$s" ]] && echo "$c"; done | sort -n)
echo "${node:-NA},$(echo "$prim" | head -1),$(echo "$prim" | tail -1)"
