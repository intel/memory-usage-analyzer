#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# vm_lib.sh — VM lifecycle library for the paired server/client Redis benchmark.
#
# Topology (see benchmark.sh header for the full description):
#
#   * SERVER_VMS server VMs, each running INSTANCES redis instances.
#       - server VM memory = INSTANCES * MEM_PER_INSTANCE_GB (+ OS headroom).
#       - ONLY server VMs are placed in the pressured cgroup ($CG); their
#         anonymous guest memory is what the host compresses (zswap/zram).
#   * CLIENT_VMS client VMs (== SERVER_VMS, paired 1:1). client<i> drives every
#     redis instance of server<i> through host port-forwards.
#
# Networking: QEMU user-mode (SLIRP). Each server VM forwards its instance ports
# 9001..900N to unique host ports; the paired client VM reaches them via the
# SLIRP gateway 10.0.2.2:<host_port> (no bridges / NET_ADMIN required).
#
# Required variables (set by benchmark.sh / setup_vm.sh before sourcing):
#   QEMU_BIN, VM_IMAGE_DIR, VM_DISK_GB,
#   SERVER_VMS, CLIENT_VMS, INSTANCES,
#   SERVER_MEM_GB, CLIENT_MEM_GB, SERVER_VCPUS, CLIENT_VCPUS,
#   SERVER_SSH_BASE, CLIENT_SSH_BASE, REDIS_HOST_BASE, REDIS_GUEST_BASE,
#   SSH_KEY, SSH_OPTS, VM_USER, CG,
#   DB_FILE, DURATION

# ─── Role helpers ─────────────────────────────────────────────────────
# A VM is identified by (role, id) where role is "server" or "client".

vm_count() {
    case "$1" in
        server) echo "$SERVER_VMS" ;;
        client) echo "$CLIENT_VMS" ;;
        *) echo 0 ;;
    esac
}

vm_dir() {
    echo "${VM_IMAGE_DIR}/$1$2"   # e.g. images/server1, images/client1
}

vm_ssh_port() {
    local role="$1" id="$2"
    if [[ "$role" == "server" ]]; then
        echo $(( SERVER_SSH_BASE + id - 1 ))
    else
        echo $(( CLIENT_SSH_BASE + id - 1 ))
    fi
}

vm_mem_gb() {
    [[ "$1" == "server" ]] && echo "$SERVER_MEM_GB" || echo "$CLIENT_MEM_GB"
}

vm_vcpus() {
    [[ "$1" == "server" ]] && echo "$SERVER_VCPUS" || echo "$CLIENT_VCPUS"
}

# Host port that maps to server<i> redis instance <j> (j = 1..INSTANCES).
redis_host_port() {
    local server_id="$1" instance_j="$2"
    echo $(( REDIS_HOST_BASE + (server_id - 1) * INSTANCES + (instance_j - 1) ))
}

# Space-separated list of host redis ports for a given server VM.
redis_host_ports_for_server() {
    local server_id="$1" j out=""
    for (( j=1; j<=INSTANCES; j++ )); do
        out+="$(redis_host_port "$server_id" "$j") "
    done
    echo "${out% }"
}

# ─── SSH helpers ──────────────────────────────────────────────────────
ssh_role() {
    local role="$1" id="$2"; shift 2
    local port; port=$(vm_ssh_port "$role" "$id")
    ssh $SSH_OPTS -p "$port" "${VM_USER}@localhost" "$@"
}

scp_to_role() {
    local role="$1" id="$2" src="$3" dest="$4"
    local port; port=$(vm_ssh_port "$role" "$id")
    scp $SSH_OPTS -P "$port" "$src" "${VM_USER}@localhost:${dest}"
}

# ─── CPU planning ─────────────────────────────────────────────────────
# Populates the global associative arrays SERVER_CPUSET / CLIENT_CPUSET with a
# host cpuset string per VM id. Honors explicit overrides; otherwise delegates
# to tests/scripts/get_redis_cpu_plan.sh so policy/placement matches redis/.
declare -gA SERVER_CPUSET=()
declare -gA CLIENT_CPUSET=()

compute_cpu_plan() {
    SERVER_CPUSET=()
    CLIENT_CPUSET=()

    # 1) Explicit overrides win.
    if [[ -n "${SERVER_CPUSETS:-}" ]]; then
        local -a s=(); IFS=';' read -r -a s <<< "$SERVER_CPUSETS"
        local i
        for (( i=0; i<SERVER_VMS; i++ )); do SERVER_CPUSET[$((i+1))]="${s[$i]:-}"; done
    fi
    if [[ -n "${CLIENT_CPUSETS:-}" ]]; then
        local -a c=(); IFS=';' read -r -a c <<< "$CLIENT_CPUSETS"
        local i
        for (( i=0; i<CLIENT_VMS; i++ )); do CLIENT_CPUSET[$((i+1))]="${c[$i]:-}"; done
    fi
    if [[ -n "${SERVER_CPUSETS:-}" && -n "${CLIENT_CPUSETS:-}" ]]; then
        resolve_vm_mempolicies
        return 0
    fi

    # 2) Use the same host CPU planner as tests/redis/benchmark.sh.
    local plan_script="${THIS_DIR}/../scripts/get_redis_cpu_plan.sh"
    if [[ ! -x "$plan_script" ]]; then
        echo "ERROR: CPU planner not found/executable: $plan_script"
        return 1
    fi

    local cpu_plan server_cores_csv client_cores_csv
    cpu_plan=$("$plan_script" "$SERVER_VMS" "$SERVER_VCPUS" "$CLIENT_VCPUS" 0 "" "auto" "redis-vm" "siblings-first" "${CORE_POLICY:-spread-nodes}")
    server_cores_csv=$(echo "$cpu_plan" | sed -n 's/.*server_cores=\([^ ]*\).*/\1/p')
    client_cores_csv=$(echo "$cpu_plan" | sed -n 's/.*client_cores=\([^ ]*\).*/\1/p')
    if [[ -z "$server_cores_csv" || -z "$client_cores_csv" ]]; then
        echo "ERROR: invalid CPU planner output: $cpu_plan"
        return 1
    fi

    local -a server_flat=() client_flat=()
    IFS=',' read -r -a server_flat <<< "$server_cores_csv"
    IFS=',' read -r -a client_flat <<< "$client_cores_csv"

    local server_need client_need
    server_need=$(( SERVER_VMS * SERVER_VCPUS ))
    client_need=$(( CLIENT_VMS * CLIENT_VCPUS ))
    if (( ${#server_flat[@]} < server_need )); then
        echo "ERROR: CPU planner returned too few server CPUs (${#server_flat[@]} < $server_need)"
        return 1
    fi
    if (( ${#client_flat[@]} < client_need )); then
        echo "ERROR: CPU planner returned too few client CPUs (${#client_flat[@]} < $client_need)"
        return 1
    fi

    local i j off cpu cset
    for (( i=1; i<=SERVER_VMS; i++ )); do
        [[ -n "${SERVER_CPUSET[$i]:-}" ]] && continue
        off=$(( (i-1) * SERVER_VCPUS ))
        cset=""
        for (( j=0; j<SERVER_VCPUS; j++ )); do
            cpu="${server_flat[$((off+j))]}"
            cset+="${cpu},"
        done
        SERVER_CPUSET[$i]="${cset%,}"
    done
    for (( i=1; i<=CLIENT_VMS; i++ )); do
        [[ -n "${CLIENT_CPUSET[$i]:-}" ]] && continue
        off=$(( (i-1) * CLIENT_VCPUS ))
        cset=""
        for (( j=0; j<CLIENT_VCPUS; j++ )); do
            cpu="${client_flat[$((off+j))]}"
            cset+="${cpu},"
        done
        CLIENT_CPUSET[$i]="${cset%,}"
    done

    resolve_vm_mempolicies
}

vm_host_cpuset() {
    local role="$1" id="$2"
    if [[ "$role" == "server" ]]; then echo "${SERVER_CPUSET[$id]:-}"; else echo "${CLIENT_CPUSET[$id]:-}"; fi
}

# ─── NUMA memory policy per VM ────────────────────────────────────────
# A VM's cpuset can straddle two NUMA nodes (common under SNC, where each
# socket is split into several smaller nodes and the primary-core pool built
# by get_redis_cpu_plan.sh crosses node boundaries far more often than on a
# flat 1-node-per-socket topology). numactl --localalloc binds memory to
# whichever node the allocating vCPU thread happens to be scheduled on at
# fault time, so a straddled VM's guest memory placement varies run to run.
# Resolve a fixed policy instead: membind to the single node when the cpuset
# is node-local, or a deterministic interleave across nodes when it isn't.
declare -gA SERVER_MEMPOL=()
declare -gA CLIENT_MEMPOL=()
declare -gA _CPU_NODE=()

_load_cpu_node_map() {
    [[ ${#_CPU_NODE[@]} -gt 0 ]] && return 0
    local cpu node
    while IFS=, read -r cpu node; do
        [[ -z "$cpu" || -z "$node" ]] && continue
        _CPU_NODE[$cpu]="$node"
    done < <(lscpu --parse=CPU,NODE 2>/dev/null | grep -v '^#')
}

# Prints a numactl policy fragment (e.g. "membind=2" or "interleave=2,3") for
# a comma-separated cpuset, or nothing if node info can't be resolved.
resolve_mempolicy_for_cpuset() {
    local cpuset="$1"
    [[ -z "$cpuset" ]] && return 0
    _load_cpu_node_map
    local -a cpus; IFS=',' read -r -a cpus <<< "$cpuset"
    local -A nodes_seen=(); local -a nodes_order=()
    local c n
    for c in "${cpus[@]}"; do
        n="${_CPU_NODE[$c]:-}"
        [[ -z "$n" ]] && return 0   # unknown topology; caller falls back to --localalloc
        if [[ -z "${nodes_seen[$n]:-}" ]]; then nodes_seen[$n]=1; nodes_order+=("$n"); fi
    done
    if [[ ${#nodes_order[@]} -eq 1 ]]; then
        echo "membind=${nodes_order[0]}"
    else
        local joined; joined=$(IFS=,; echo "${nodes_order[*]}")
        echo "interleave=${joined}"
    fi
}

# Populates SERVER_MEMPOL / CLIENT_MEMPOL from the already-assigned cpusets.
# Call after compute_cpu_plan (and after any manual SERVER_CPUSET/CLIENT_CPUSET edits).
resolve_vm_mempolicies() {
    SERVER_MEMPOL=(); CLIENT_MEMPOL=()
    local i pol
    for (( i=1; i<=SERVER_VMS; i++ )); do
        pol=$(resolve_mempolicy_for_cpuset "${SERVER_CPUSET[$i]:-}")
        [[ -n "$pol" ]] && SERVER_MEMPOL[$i]="$pol"
        if [[ "$pol" == interleave=* ]]; then
            echo "WARNING: server${i} cpuset (${SERVER_CPUSET[$i]}) spans NUMA nodes ${pol#interleave=}; binding with --${pol} instead of single-node membind. This is expected under SNC when a VM needs more cores than one node provides." >&2
        fi
    done
    for (( i=1; i<=CLIENT_VMS; i++ )); do
        pol=$(resolve_mempolicy_for_cpuset "${CLIENT_CPUSET[$i]:-}")
        [[ -n "$pol" ]] && CLIENT_MEMPOL[$i]="$pol"
        if [[ "$pol" == interleave=* ]]; then
            echo "WARNING: client${i} cpuset (${CLIENT_CPUSET[$i]}) spans NUMA nodes ${pol#interleave=}; binding with --${pol} instead of single-node membind." >&2
        fi
    done
}

vm_host_mempol() {
    local role="$1" id="$2"
    if [[ "$role" == "server" ]]; then echo "${SERVER_MEMPOL[$id]:-}"; else echo "${CLIENT_MEMPOL[$id]:-}"; fi
}

# ─── Wait for SSH ─────────────────────────────────────────────────────
wait_for_vm_ssh() {
    local role="$1" id="$2" max_wait="${3:-420}"
    local port; port=$(vm_ssh_port "$role" "$id")
    local dir; dir=$(vm_dir "$role" "$id")
    local pidfile="${dir}/qemu.pid"
    local console_log="${dir}/console.log"
    local fallback_user="ubuntu"
    echo "  Waiting for ${role}${id} SSH (port $port)..."
    local elapsed=0 heartbeat=0
    while true; do
        if ssh $SSH_OPTS -p "$port" "${VM_USER}@localhost" "true" 2>/dev/null; then
            break
        fi
        if [[ "$VM_USER" != "$fallback_user" ]] && ssh $SSH_OPTS -p "$port" "${fallback_user}@localhost" "true" 2>/dev/null; then
            echo "  ${role}${id}: SSH ready via fallback user '${fallback_user}'"
            VM_USER="$fallback_user"
            break
        fi
        if [[ -f "$pidfile" ]]; then
            local pid; pid=$(cat "$pidfile" 2>/dev/null || true)
            if [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; then
                echo "ERROR: ${role}${id} process exited before SSH became ready"
                [[ -f "$console_log" ]] && { echo "--- ${role}${id} console tail ---"; tail -n 80 "$console_log" || true; }
                return 1
            fi
        fi
        sleep 5; elapsed=$((elapsed+5)); heartbeat=$((heartbeat+5))
        if (( heartbeat >= 30 )); then
            echo "    still waiting for ${role}${id} SSH... ${elapsed}/${max_wait}s"; heartbeat=0
        fi
        if (( elapsed >= max_wait )); then
            echo "ERROR: ${role}${id} did not become reachable within ${max_wait}s"
            [[ -f "$console_log" ]] && { echo "--- ${role}${id} console tail ---"; tail -n 120 "$console_log" || true; }
            return 1
        fi
    done
    echo "  ${role}${id}: SSH ready (${elapsed}s)"
}

# ─── VM start ─────────────────────────────────────────────────────────
start_vm() {
    local role="$1" id="$2"
    local dir; dir=$(vm_dir "$role" "$id")
    local disk="${dir}/disk.qcow2"
    local cidata="${dir}/cidata.iso"
    local ssh_port; ssh_port=$(vm_ssh_port "$role" "$id")
    local pidfile="${dir}/qemu.pid"
    local monitor="${dir}/monitor.sock"
    local mem_gb; mem_gb=$(vm_mem_gb "$role")
    local vcpus; vcpus=$(vm_vcpus "$role")

    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
        echo "  ${role}${id} already running (pid $(cat "$pidfile"))"
        return 0
    fi

    local vmlinuz="${VM_IMAGE_DIR}/vmlinuz"
    local initrd="${VM_IMAGE_DIR}/initrd.img"
    if [[ ! -f "$vmlinuz" || ! -f "$initrd" ]]; then
        echo "ERROR: Kernel/initrd not found. Run setup_vm.sh first."
        return 1
    fi

    # Build the netdev host-forward string.
    local netdev="user,id=net0,hostfwd=tcp::${ssh_port}-:22"
    if [[ "$role" == "server" ]]; then
        local j gport hport
        for (( j=1; j<=INSTANCES; j++ )); do
            gport=$(( REDIS_GUEST_BASE + j ))          # guest 9001..900N
            hport=$(redis_host_port "$id" "$j")        # unique host port
            netdev+=",hostfwd=tcp::${hport}-:${gport}"
        done
    fi

    # CPU pinning. Memory policy is a fixed membind/interleave resolved from the
    # VM's actual cpuset (see resolve_vm_mempolicies) rather than --localalloc,
    # which is schedule-dependent and a source of run-to-run variance whenever
    # a cpuset straddles NUMA nodes (e.g. under SNC).
    local host_cpuset; host_cpuset=$(vm_host_cpuset "$role" "$id")
    local host_mempol; host_mempol=$(vm_host_mempol "$role" "$id")
    local pin_cmd=""
    if [[ -n "$host_cpuset" ]]; then
        if command -v numactl >/dev/null 2>&1; then
            pin_cmd="numactl --physcpubind=${host_cpuset} --${host_mempol:-localalloc}"
        else
            pin_cmd="taskset -c ${host_cpuset}"
        fi
    fi

    echo "  Starting ${role}${id} (${mem_gb}GB, ${vcpus} vCPU, ssh:${ssh_port}${host_cpuset:+, cpus:${host_cpuset}})..."

    $pin_cmd $QEMU_BIN \
        -name "${role}${id}" \
        -machine type=q35,accel=kvm \
        -cpu host \
        -smp "$vcpus" \
        -m "${mem_gb}G" \
        -mem-prealloc \
        -kernel "$vmlinuz" \
        -initrd "$initrd" \
        -append "root=LABEL=cloudimg-rootfs rw console=ttyS0 systemd.mask=boot.mount systemd.mask=boot-efi.mount" \
        -drive file="$disk",format=qcow2,if=virtio,cache=none \
        -cdrom "$cidata" \
        -device virtio-balloon-pci,free-page-reporting=on \
        -netdev "$netdev" \
        -device virtio-net-pci,netdev=net0 \
        -serial file:"${dir}/console.log" \
        -display none \
        -pidfile "$pidfile" \
        -monitor unix:"$monitor",server,nowait \
        -daemonize

    if [[ $? -ne 0 ]] || [[ ! -f "$pidfile" ]]; then
        echo "ERROR: Failed to start ${role}${id}"
        return 1
    fi
    echo "  ${role}${id} started (pid $(cat "$pidfile"))"
}

stop_vm() {
    local role="$1" id="$2"
    local dir; dir=$(vm_dir "$role" "$id")
    local pidfile="${dir}/qemu.pid"
    local port; port=$(vm_ssh_port "$role" "$id")
    if [[ -f "$pidfile" ]]; then
        local pid; pid=$(cat "$pidfile" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            ssh $SSH_OPTS -p "$port" "${VM_USER}@localhost" "sudo poweroff" 2>/dev/null || true
            local w=0
            while kill -0 "$pid" 2>/dev/null && (( w < 30 )); do sleep 1; w=$((w+1)); done
            kill -9 "$pid" 2>/dev/null || true
        fi
        rm -f "$pidfile"
    fi
}

stop_all_vms() {
    local i
    for (( i=1; i<=SERVER_VMS; i++ )); do stop_vm server "$i"; done
    for (( i=1; i<=CLIENT_VMS; i++ )); do stop_vm client "$i"; done
}

kill_all_qemu_processes() {
    local qemu_base="${QEMU_BIN##*/}"
    local names=("qemu-system-x86_64" "qemu-kvm" "$qemu_base")
    echo "  Force-cleaning residual QEMU processes..."
    for name in "${names[@]}"; do
        [[ -z "$name" ]] && continue
        pkill -9 -x "$name" 2>/dev/null || true
        sudo -n pkill -9 -x "$name" 2>/dev/null || true
    done
}

# Dead-VM detection. With no argument, checks server VMs only (the pressured
# ones that may OOM); pass "all" to include client VMs.
get_dead_vms() {
    local scope="${1:-server}"
    local dead="" role i n pidfile pid
    local roles=(server)
    [[ "$scope" == "all" ]] && roles=(server client)
    for role in "${roles[@]}"; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            pidfile="$(vm_dir "$role" "$i")/qemu.pid"
            if [[ ! -f "$pidfile" ]]; then dead+="${role}${i} "; continue; fi
            pid=$(cat "$pidfile" 2>/dev/null || true)
            if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then dead+="${role}${i} "; fi
        done
    done
    echo "${dead% }"
}

wait_for_ports_free() {
    local max_wait="${1:-30}" elapsed=0
    while (( elapsed < max_wait )); do
        local busy=0 i port
        for (( i=1; i<=SERVER_VMS; i++ )); do
            port=$(vm_ssh_port server "$i")
            ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && { busy=1; break; }
        done
        if (( busy == 0 )); then
            for (( i=1; i<=CLIENT_VMS; i++ )); do
                port=$(vm_ssh_port client "$i")
                ss -tlnH "sport = :$port" 2>/dev/null | grep -q . && { busy=1; break; }
            done
        fi
        (( busy == 0 )) && return 0
        sleep 1; elapsed=$((elapsed+1))
    done
    echo "WARNING: ports still in use after ${max_wait}s — continuing anyway"
}

# ─── Overlay disk creation ────────────────────────────────────────────
create_vm_overlay_disk() {
    local dir="$1"
    local target_gb="${VM_DISK_GB:-20}"
    local disk_path="${dir}/disk.qcow2"
    local target_bytes=$(( target_gb * 1073741824 ))
    qemu-img create -f qcow2 -b "${VM_IMAGE_DIR}/ubuntu-base.qcow2" -F qcow2 "$disk_path" "${target_gb}G" >/dev/null
    qemu-img resize "$disk_path" "${target_gb}G" >/dev/null 2>&1 || true
    local actual_bytes
    actual_bytes=$(qemu-img info --force-share "$disk_path" 2>/dev/null | awk -F'[()]' '/virtual size:/ {print $2}' | awk '{print $1}' | head -1)
    if [[ ! "$actual_bytes" =~ ^[0-9]+$ ]] || (( actual_bytes < target_bytes )); then
        echo "ERROR: Overlay disk size validation failed for $disk_path"
        return 1
    fi
}

create_fresh_overlays() {
    echo "Creating fresh VM disk overlays..."
    local role i n dir
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            dir=$(vm_dir "$role" "$i"); mkdir -p "$dir"
            rm -f "${dir}/disk.qcow2" "${dir}/console.log" "${dir}/qemu.pid"
            create_vm_overlay_disk "$dir" || return 1
        done
    done
    echo "  Done"
}

# ─── Cloud-init (used when regeneration is needed at runtime) ─────────
# Build a cloud-init NoCloud ISO with whatever tool is available (portable
# across Ubuntu/Debian and CentOS/RHEL, which may only ship xorriso).
make_cloud_iso() {
    local iso="$1" user_data="$2" meta_data="$3"
    if command -v cloud-localds &>/dev/null; then
        cloud-localds "$iso" "$user_data" "$meta_data"
    elif command -v genisoimage &>/dev/null; then
        genisoimage -output "$iso" -volid cidata -joliet -rock "$user_data" "$meta_data" 2>/dev/null
    elif command -v mkisofs &>/dev/null; then
        mkisofs -output "$iso" -volid cidata -joliet -rock "$user_data" "$meta_data" 2>/dev/null
    elif command -v xorrisofs &>/dev/null; then
        xorrisofs -output "$iso" -volid cidata -joliet -rock "$user_data" "$meta_data" 2>/dev/null
    else
        echo "ERROR: no ISO tool (cloud-localds/genisoimage/mkisofs/xorrisofs) found"; return 1
    fi
}

generate_cidata() {
    local role="$1" id="$2"
    local dir; dir=$(vm_dir "$role" "$id")
    local ssh_pubkey; ssh_pubkey=$(cat "${SSH_KEY}.pub")
    mkdir -p "$dir"

    local apt_proxy_block=""
    if [[ -n "${http_proxy:-}" ]]; then
        apt_proxy_block="
apt:
  http_proxy: ${http_proxy}
  https_proxy: ${https_proxy:-${http_proxy}}"
    fi

    cat > "${dir}/user-data" <<USERDATA
#cloud-config
hostname: ${role}${id}
users:
  - default
  - name: ${VM_USER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    lock_passwd: true
    groups: sudo, users
    ssh_authorized_keys:
      - ${ssh_pubkey}
${apt_proxy_block}

package_update: true
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
packages:
  - redis-server
  - redis-tools
  - numactl
  - sysstat
  - time
  - libevent-2.1-7t64
  - libevent-openssl-2.1-7t64
  - libevent-pthreads-2.1-7t64
  - libpcre2-8-0
  - libssl3
  - zlib1g
  - cloud-guest-utils
runcmd:
  - systemctl stop redis-server || true
  - systemctl disable redis-server || true
USERDATA

    cat > "${dir}/meta-data" <<META
instance-id: ${role}${id}
local-hostname: ${role}${id}
META

    make_cloud_iso "${dir}/cidata.iso" "${dir}/user-data" "${dir}/meta-data"
}

ensure_cidata_all_vms() {
    local ssh_pubkey; ssh_pubkey=$(cat "${SSH_KEY}.pub")
    local role i n dir
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            dir=$(vm_dir "$role" "$i")
            local regen=0
            if [[ ! -f "${dir}/cidata.iso" ]]; then
                regen=1
            elif [[ -f "${dir}/user-data" ]] && ! grep -qF "$ssh_pubkey" "${dir}/user-data"; then
                regen=1
            elif [[ -f "${dir}/user-data" ]] && ! grep -qF -- "- name: ${VM_USER}" "${dir}/user-data"; then
                regen=1
            elif [[ -f "${dir}/user-data" ]] && ! grep -qF "redis-server" "${dir}/user-data"; then
                regen=1
            fi
            if (( regen )); then
                echo "  Generating cloud-init for ${role}${i}..."
                generate_cidata "$role" "$i"
            fi
        done
    done
}

# ─── Workload deployment ─────────────────────────────────────────────
deploy_workload_scripts() {
    echo "Deploying workload scripts to VMs..."
    local role i n
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            ssh_role "$role" "$i" "cat > /home/${VM_USER}/run_workload.sh && chmod +x /home/${VM_USER}/run_workload.sh" <<'VMSCRIPT'
#!/bin/bash
#
# run_workload.sh — guest-side Redis/memtier workload (role-aware).
#
#   server-start   : start INSTANCES empty redis instances (ports 9001..900N).
#   client-prefill : populate the paired remote server (TARGET_HOST:TARGET_PORTS)
#                    from the dataset — redis-cli --pipe for .redis files, or
#                    memtier_benchmark --data-import for .csv files.
#   client-run     : run one memtier per remote instance (TARGET_HOST:TARGET_PORTS)
#                    and aggregate throughput/p99 into benchmark_result.txt:
#                        throughput <sum ops/sec across this VM's instances>
#                        p99         <max p99 across instances, ms>
#                        instances   <number of instances with a valid result>
#                        keys        <sum of keys measured>
#
set -uo pipefail

MODE=${1:-client-run}
INSTANCES=${INSTANCES:-1}
DB_FILE=${DB_FILE:-import_movies_10000r_10c.csv}
VCPUS=${VCPUS:-2}
DURATION=${DURATION:-120}
TARGET_HOST=${TARGET_HOST:-10.0.2.2}
TARGET_PORTS=${TARGET_PORTS:-}

DATASET=/home/bench/${DB_FILE}
RESULT=/home/bench/benchmark_result.txt
MEMTIER=/usr/local/bin/memtier_benchmark
REDIS_GUEST_BASE=9000

# Guest core for the k-th (0-based) worker, leaving core 0 free when possible.
worker_cpu() {
    local k="$1"
    if (( VCPUS > 1 )); then echo $(( 1 + (k % (VCPUS - 1)) )); else echo 0; fi
}

write_redis_conf() {
    local port="$1" conf="$2" logf="$3"
    cat > "$conf" <<EOF
protected-mode no
port ${port}
tcp-backlog 128
timeout 0
tcp-keepalive 300
daemonize no
loglevel notice
logfile ${logf}
databases 16
save ""
appendonly no
maxclients 2048
EOF
}

start_one_redis() {
    local j="$1"                       # instance index 1..INSTANCES
    local port=$(( REDIS_GUEST_BASE + j ))
    local conf="/home/bench/redis_${j}.conf"
    local logf="/home/bench/redis_${j}.log"
    local cpu; cpu=$(worker_cpu $((j-1)))
    write_redis_conf "$port" "$conf" "$logf"
    setsid numactl -C "$cpu" --localalloc redis-server "$conf" &>/home/bench/redis_${j}_stdout.log &
    local tries=0
    until redis-cli -p "$port" ping 2>/dev/null | grep -q PONG; do
        sleep 1; tries=$((tries+1))
        if (( tries > 60 )); then echo "ERROR: redis instance $j (port $port) did not become ready"; return 1; fi
    done
    echo "  redis instance $j ready on port ${port} (cpu ${cpu})"
}

server_start() {
    pkill -f "redis-server" 2>/dev/null || true
    sleep 1
    echo "Starting ${INSTANCES} redis instance(s)..."
    local j
    for (( j=1; j<=INSTANCES; j++ )); do start_one_redis "$j" || return 1; done
    echo "Server start complete (${INSTANCES} instance(s))."
}

# Populate the paired remote server from the dataset. .redis files stream via
# redis-cli --pipe; .csv files load through memtier_benchmark --data-import.
client_prefill() {
    if [[ -z "$TARGET_PORTS" ]]; then echo "ERROR: TARGET_PORTS not set"; return 1; fi
    if [[ ! -f "$DATASET" ]]; then echo "ERROR: dataset ${DATASET} missing on client"; return 1; fi
    local -a ports=($TARGET_PORTS)
    local ext="${DB_FILE##*.}"

    # Verify connectivity to each redis instance before starting bulk import
    local port
    for port in "${ports[@]}"; do
        local tries=0
        until redis-cli -h "$TARGET_HOST" -p "$port" ping 2>/dev/null | grep -q PONG; do
            sleep 2; tries=$((tries+1))
            if (( tries > 30 )); then
                echo "ERROR: cannot reach redis at ${TARGET_HOST}:${port} after 60s"
                return 1
            fi
        done
    done

    echo "Populating ${#ports[@]} instance(s) on ${TARGET_HOST} from ${DB_FILE} (${ext})..."
    local k=0 pids=() port cpu
    for port in "${ports[@]}"; do
        cpu=$(worker_cpu "$k")
        if [[ "$ext" == "csv" ]]; then
            local num_lines; num_lines=$(( $(wc -l < "$DATASET") - 1 ))
            numactl -C "$cpu" --localalloc "$MEMTIER" \
                --server="$TARGET_HOST" --port="$port" --protocol=redis \
                --ratio=1:0 --key-pattern=P:P --threads=1 --clients=1 \
                --data-import="$DATASET" -n "$num_lines" \
                > /home/bench/prefill_${port}.log 2>&1 &
        else
            numactl -C "$cpu" --localalloc \
                redis-cli -h "$TARGET_HOST" -p "$port" --pipe < "$DATASET" \
                > /home/bench/prefill_${port}.log 2>&1 &
        fi
        pids+=($!)
        k=$((k+1))
    done
    local rc=0
    for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
    for port in "${ports[@]}"; do
        local n; n=$(redis-cli -h "$TARGET_HOST" -p "$port" dbsize 2>/dev/null | awk '{print $1}')
        echo "  ${TARGET_HOST}:${port} -> ${n:-0} keys resident"
    done
    return $rc
}

client_run() {
    if [[ -z "$TARGET_PORTS" ]]; then echo "ERROR: TARGET_PORTS not set"; return 1; fi
    local -a ports=($TARGET_PORTS)
    echo "Running memtier against ${#ports[@]} instance(s) on ${TARGET_HOST} for ${DURATION}s..."

    local k=0 pids=() port cpu max_keys key_spread
    for port in "${ports[@]}"; do
        if ! redis-cli -h "$TARGET_HOST" -p "$port" ping 2>/dev/null | grep -q PONG; then
            echo "  WARNING: instance ${TARGET_HOST}:${port} not reachable"
            k=$((k+1)); continue
        fi
        max_keys=$(redis-cli -h "$TARGET_HOST" -p "$port" dbsize | awk '{print $1}')
        [[ -z "$max_keys" || "$max_keys" -eq 0 ]] && { echo "  WARNING: no keys on ${port}"; k=$((k+1)); continue; }
        key_spread=$(( max_keys / 6 )); (( key_spread < 1 )) && key_spread=1
        cpu=$(worker_cpu "$k")
        numactl -C "$cpu" --localalloc "$MEMTIER" \
            -s "$TARGET_HOST" -p "$port" \
            --key-prefix= --key-minimum=1 --key-maximum="$max_keys" \
            --key-stddev="$key_spread" --test-time="$DURATION" \
            --threads=1 --clients=4 --pipeline=1 --ratio=20:80 --key-pattern=G:G \
            > /home/bench/memtier_${port}.log 2>&1 &
        pids+=($!)
        k=$((k+1))
    done

    for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

    local sum_tput=0 max_p99=0 valid=0 sum_keys=0 t p9 mk
    for port in "${ports[@]}"; do
        local log="/home/bench/memtier_${port}.log"
        [[ -f "$log" ]] || continue
        t=$(awk '/^Totals/ {print $2; exit}' "$log")
        p9=$(awk '/^Totals/ {print $7; exit}' "$log")
        [[ -n "$t" ]] && awk -v v="$t" 'BEGIN{exit !(v+0>0)}' || continue
        mk=$(redis-cli -h "$TARGET_HOST" -p "$port" dbsize 2>/dev/null | awk '{print $1}')
        sum_tput=$(awk -v a="$sum_tput" -v b="$t" 'BEGIN{printf "%.2f", a+b}')
        max_p99=$(awk -v a="$max_p99" -v b="${p9:-0}" 'BEGIN{printf "%.2f", (b+0>a+0)?b:a}')
        sum_keys=$(( sum_keys + ${mk:-0} ))
        valid=$((valid+1))
    done

    {
        echo "throughput ${sum_tput}"
        echo "p99 ${max_p99}"
        echo "instances ${valid}"
        echo "keys ${sum_keys}"
    } > "$RESULT"
    cat "$RESULT"
}

case "$MODE" in
    server-start)   server_start ;;
    client-prefill) client_prefill ;;
    client-run)     client_run ;;
    *) echo "Usage: run_workload.sh {server-start|client-prefill|client-run}"; exit 1 ;;
esac
VMSCRIPT
        done
    done
    echo "  Workload scripts deployed"
}

# ─── VM initialization (cloud-init + package verification) ───────────
wait_for_cloud_init_and_packages() {
    echo "  Waiting for cloud-init to finish in VMs..."
    local role i n
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            ssh_role "$role" "$i" "cloud-init status --wait" >/dev/null 2>&1 || true
        done
    done
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            if ! ssh_role "$role" "$i" "command -v redis-server && command -v redis-cli" >/dev/null 2>&1; then
                echo "  ${role}${i}: redis missing, installing..."
                local proxy_env=""
                [[ -n "${http_proxy:-}" ]] && proxy_env="http_proxy=${http_proxy} https_proxy=${https_proxy:-${http_proxy}}"
                ssh_role "$role" "$i" "sudo $proxy_env apt-get update -qq && sudo $proxy_env apt-get install -y -qq redis-server redis-tools numactl sysstat time libevent-2.1-7t64 libevent-openssl-2.1-7t64 libevent-pthreads-2.1-7t64 libpcre2-8-0 libssl3 zlib1g" >/dev/null 2>&1 || {
                    echo "ERROR: Failed to install redis on ${role}${i}"; return 1;
                }
            fi
            ssh_role "$role" "$i" "sudo systemctl stop redis-server 2>/dev/null; sudo systemctl disable redis-server 2>/dev/null" >/dev/null 2>&1 || true
        done
    done
}

# Stage memtier + dataset into clients (clients drive population and load).
populate_workload_data() {
    echo "  Staging memtier + dataset -> clients..."
    local memtier_bin="${VM_IMAGE_DIR}/memtier_benchmark"
    local dataset="${VM_IMAGE_DIR}/${DB_FILE}"
    [[ -f "$memtier_bin" ]] || { echo "ERROR: staged memtier not found ($memtier_bin). Run setup_vm.sh."; return 1; }
    [[ -f "$dataset" ]] || { echo "ERROR: staged dataset not found ($dataset). Run setup_vm.sh."; return 1; }

    local pids=() failed=0 i
    for (( i=1; i<=CLIENT_VMS; i++ )); do
        (
            scp_to_role client "$i" "$memtier_bin" "/home/${VM_USER}/memtier_benchmark" || { echo "ERROR: memtier stage failed on client$i"; exit 1; }
            ssh_role client "$i" "sudo install -m 0755 /home/${VM_USER}/memtier_benchmark /usr/local/bin/memtier_benchmark" || { echo "ERROR: memtier install failed on client$i"; exit 1; }
            scp_to_role client "$i" "$dataset" "/home/${VM_USER}/${DB_FILE}" || { echo "ERROR: dataset stage failed on client$i"; exit 1; }
        ) > "$(vm_dir client "$i")/init.log" 2>&1 &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
    if (( failed == 1 )); then
        echo "ERROR: one or more staging jobs failed"
        return 1
    fi
    echo "  Staging complete"
}

# Boot servers (in $CG) + clients (outside $CG), wait, deploy, stage, snapshot.
prepare_fresh_vms_for_scenario() {
    local label="$1"
    local boot_wait="${VM_BOOT_WAIT:-420}"
    local start_stagger="${VM_START_STAGGER_SEC:-2}"

    echo ""
    echo "Preparing fresh VMs for $label ..."
    kill_all_qemu_processes
    sleep 3
    echo 1 | sudo tee "$CG/cgroup.kill" >/dev/null 2>/dev/null || true
    sudo rmdir "$CG" 2>/dev/null || true
    wait_for_ports_free 30

    local role i n dir
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            dir=$(vm_dir "$role" "$i")
            rm -f "${dir}/disk.qcow2" "${dir}/console.log" "${dir}/qemu.pid"
            create_vm_overlay_disk "$dir" || return 1
        done
    done

    # Recreate the (unlimited) server cgroup before booting; boot_all_vms places
    # server QEMU into it and leaves client QEMU in the root cgroup.
    sudo mkdir -p "$CG"
    echo "max" | sudo tee "$CG/memory.max" >/dev/null
    echo "max" | sudo tee "$CG/memory.swap.max" >/dev/null 2>/dev/null || true

    boot_all_vms "$start_stagger"

    for (( i=1; i<=SERVER_VMS; i++ )); do wait_for_vm_ssh server "$i" "$boot_wait"; done
    for (( i=1; i<=CLIENT_VMS; i++ )); do wait_for_vm_ssh client "$i" "$boot_wait"; done

    wait_for_cloud_init_and_packages || exit 1
    deploy_workload_scripts
    populate_workload_data || exit 1

    stop_all_vms
    sleep 2
    echo 1 | sudo tee "$CG/cgroup.kill" >/dev/null 2>/dev/null || true
    sudo rmdir "$CG" 2>/dev/null || true
}

# Start server VMs inside $CG, client VMs outside it.
boot_all_vms() {
    local start_stagger="${1:-2}" i
    # Server VMs: place this shell in the pressured cgroup so forked QEMU inherits it.
    echo $$ | sudo tee "$CG/cgroup.procs" >/dev/null
    for (( i=1; i<=SERVER_VMS; i++ )); do
        start_vm server "$i"
        if (( start_stagger > 0 && i < SERVER_VMS )); then sleep "$start_stagger"; fi
    done
    # Move back to the root cgroup so client QEMU stays UNLIMITED.
    echo $$ | sudo tee /sys/fs/cgroup/cgroup.procs >/dev/null
    for (( i=1; i<=CLIENT_VMS; i++ )); do
        start_vm client "$i"
        if (( start_stagger > 0 && i < CLIENT_VMS )); then sleep "$start_stagger"; fi
    done
    return 0
}

# ─── Overlay snapshot/restore ────────────────────────────────────────
snapshot_vm_overlays() {
    local snapshot_dir="${VM_IMAGE_DIR}/.snapshots"
    mkdir -p "$snapshot_dir"
    echo "  Snapshotting VM overlays..."
    local role i n
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            cp "$(vm_dir "$role" "$i")/disk.qcow2" "${snapshot_dir}/${role}${i}_disk.qcow2"
        done
    done
    echo "  Snapshot saved to ${snapshot_dir}"
}

restore_vm_overlays() {
    local snapshot_dir="${VM_IMAGE_DIR}/.snapshots"
    [[ -d "$snapshot_dir" ]] || { echo "ERROR: No snapshot at ${snapshot_dir}."; return 1; }
    echo "  Restoring VM overlays from snapshot..."
    local role i n dir
    for role in server client; do
        n=$(vm_count "$role")
        for (( i=1; i<=n; i++ )); do
            dir=$(vm_dir "$role" "$i")
            rm -f "${dir}/disk.qcow2"
            cp "${snapshot_dir}/${role}${i}_disk.qcow2" "${dir}/disk.qcow2"
        done
    done
    echo "  Overlays restored"
}

# ─── Pre-flight checks ───────────────────────────────────────────────
preflight_checks() {
    local ok=1

    if [[ ! -f "$SSH_KEY" ]]; then
        echo "Generating SSH key pair..."
        ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -q
    fi
    [[ -f "${SSH_KEY}.pub" ]] || { echo "ERROR: SSH public key not found at ${SSH_KEY}.pub"; ok=0; }

    local cmd
    for cmd in $QEMU_BIN qemu-img awk; do
        command -v "$cmd" &>/dev/null || { echo "ERROR: Required command '$cmd' not found."; ok=0; }
    done
    # Any one cloud-init ISO builder is sufficient (genisoimage on Ubuntu,
    # xorriso on CentOS/RHEL, or cloud-localds/mkisofs).
    if ! command -v cloud-localds &>/dev/null && ! command -v genisoimage &>/dev/null \
        && ! command -v mkisofs &>/dev/null && ! command -v xorrisofs &>/dev/null; then
        echo "ERROR: no ISO tool found (need one of: genisoimage, xorrisofs, mkisofs, cloud-localds)."; ok=0
    fi
    # This benchmark drives cgroup v2 (memory.max, cgroup.kill); bail out early
    # on cgroup v1 hosts (e.g. RHEL/CentOS 8 defaults) with a clear message.
    if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
        echo "ERROR: cgroup v2 unified hierarchy required. Boot with 'systemd.unified_cgroup_hierarchy=1'."; ok=0
    fi

    if [[ ! -f "${VM_IMAGE_DIR}/vmlinuz" || ! -f "${VM_IMAGE_DIR}/initrd.img" ]]; then
        echo "ERROR: Kernel/initrd not found. Run ./setup_vm.sh."; ok=0
    fi
    [[ -f "${VM_IMAGE_DIR}/ubuntu-base.qcow2" ]] || { echo "ERROR: Base image missing. Run ./setup_vm.sh."; ok=0; }
    [[ -f "${VM_IMAGE_DIR}/memtier_benchmark" ]] || { echo "ERROR: staged memtier missing. Run ./setup_vm.sh."; ok=0; }
    [[ -f "${VM_IMAGE_DIR}/${DB_FILE}" ]] || { echo "ERROR: staged dataset '${DB_FILE}' missing. Run ./setup_vm.sh."; ok=0; }
    [[ -w /dev/kvm ]] || { echo "ERROR: /dev/kvm not writable."; ok=0; }

    if ! python -c "import numpy" 2>/dev/null; then
        echo "  Installing numpy..."; pip install -q numpy 2>/dev/null || echo "WARNING: numpy install failed"
    fi
    if ! python -c "import pandas" 2>/dev/null; then
        echo "  Installing pandas..."; pip install -q pandas 2>/dev/null || echo "WARNING: pandas install failed"
    fi
    if ! python -c "import bokeh" 2>/dev/null; then
        echo "  Installing bokeh..."; pip install -q bokeh 2>/dev/null || echo "WARNING: bokeh install failed"
    fi

    if (( ok == 0 )); then
        echo ""
        echo "Pre-flight checks failed. Fix the above errors and re-run."
        return 1
    fi
    echo "Pre-flight checks passed."

    if [[ -f /sys/module/kvm/parameters/ignore_msrs ]]; then
        if [[ "$(cat /sys/module/kvm/parameters/ignore_msrs)" != "Y" ]]; then
            echo 1 | sudo tee /sys/module/kvm/parameters/ignore_msrs >/dev/null
        fi
    fi
}

# ─── Variance reduction ──────────────────────────────────────────────
reduce_variance() {
    echo "Applying variance-reduction settings..."
    [[ -f /proc/sys/kernel/numa_balancing ]] && echo 0 > /proc/sys/kernel/numa_balancing 2>/dev/null && echo "  NUMA balancing: disabled"
    [[ -f /sys/kernel/mm/transparent_hugepage/enabled ]] && echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && echo "  THP: disabled"
    [[ -f /sys/kernel/mm/transparent_hugepage/defrag ]] && echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null && echo "  THP defrag: disabled"
    if systemctl is-active --quiet irqbalance 2>/dev/null; then
        systemctl stop irqbalance 2>/dev/null && echo "  irqbalance: stopped"
    fi
    echo "  Variance reduction applied"
}
