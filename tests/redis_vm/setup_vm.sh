#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# setup_vm.sh — Prepare VM images for the paired server/client Redis benchmark.
#
# Builds ONE Ubuntu cloud-init base image (redis-server + memtier runtime libs),
# then creates copy-on-write overlays and cloud-init ISOs for:
#   * SERVER_VMS server VMs (run INSTANCES redis instances each), and
#   * CLIENT_VMS client VMs (run memtier against their paired server).
#
# See benchmark.sh for the full topology description. This is the VM counterpart
# of tests/redis and reuses the image-prep flow of tests/kernelbuild_vm.
#
# Prerequisites: qemu-img, qemu-nbd (or libguestfs' virt-copy-out), an ISO tool
# (cloud-localds / genisoimage / mkisofs / xorrisofs), and a host-built
# memtier_benchmark binary (see tests/redis). Runs on Ubuntu/Debian and
# CentOS/RHEL/Rocky/AlmaLinux/Fedora hosts.

set -euo pipefail

THIS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REDIS_DIR="${THIS_DIR}/../redis"

# ─── Configuration ────────────────────────────────────────────────────
VM_IMAGE_DIR="${THIS_DIR}/images"
BASE_IMAGE="${VM_IMAGE_DIR}/ubuntu-base.qcow2"
CLOUD_IMAGE_URL="${CLOUD_IMAGE_URL:-https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img}"
VM_USER="bench"

SERVER_VMS="${SERVER_VMS:-1}"                 # number of server VMs (== client VMs)
INSTANCES="${INSTANCES:-1}"                   # redis instances per server VM
MEM_PER_INSTANCE_GB="${MEM_PER_INSTANCE_GB:-6}"
CLIENT_MEM_GB="${CLIENT_MEM_GB:-2}"
VM_DISK_GB="${VM_DISK_GB:-20}"

DB_FILE="${DB_FILE:-import_movies_10000r_10c.csv}"
DB_FILE_EXPLICIT=0
DATA_REPS="${DATA_REPS:-10000}"          # repeat_redis_file.py -r (dataset name + auto-generation)
DATA_COLS="${DATA_COLS:-10}"             # repeat_redis_file.py -c

# ─── Usage ────────────────────────────────────────────────────────────
print_usage() {
    cat <<'EOF'
Usage: setup_vm.sh [options]

Options:
  --server-vms <V>        Number of server VMs (client VMs match 1:1) (default: 1)
  --instances <N>         Redis instances per server VM (default: 1)
  --mem-per-instance <GB> RAM per redis instance; server VM RAM = N*this (default: 6)
  --client-mem <GB>       RAM per client VM (default: 2)
  --vm-disk <GB>          Overlay disk size in GB (default: 20)
  --db-file <name>        Redis dataset file (default: import_movies_<reps>r_<cols>c.csv)
  --data-reps <N>         repeat_redis_file.py -r used to name/generate the dataset (default: 10000)
  --data-cols <N>         repeat_redis_file.py -c used to name/generate the dataset (default: 10)
  --help, -h              Show this help

Dataset:
  Generated automatically with the bundled generator when missing (unless
  --db-file names an existing file):
        python repeat_redis_file.py -r <reps> -c <cols>

This script:
  1. Downloads a Ubuntu cloud image (if not cached)
  2. Extracts kernel/initrd for direct boot (no GRUB/UEFI)
  3. Stages a host-built memtier_benchmark binary (guests have no network)
  4. Creates per-VM overlays + cloud-init for SERVER_VMS servers + SERVER_VMS clients
  5. Prepares SSH keys for host->guest communication
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-vms)        SERVER_VMS="$2"; shift 2 ;;
        --instances)         INSTANCES="$2"; shift 2 ;;
        --mem-per-instance)  MEM_PER_INSTANCE_GB="$2"; shift 2 ;;
        --client-mem)        CLIENT_MEM_GB="$2"; shift 2 ;;
        --vm-disk)           VM_DISK_GB="$2"; shift 2 ;;
        --db-file)           DB_FILE="$2"; DB_FILE_EXPLICIT=1; shift 2 ;;
        --data-reps)         DATA_REPS="$2"; shift 2 ;;
        --data-cols)         DATA_COLS="$2"; shift 2 ;;
        --help|-h)           print_usage; exit 0 ;;
        *)                   echo "Unknown option: $1"; exit 1 ;;
    esac
done

CLIENT_VMS="$SERVER_VMS"
SERVER_MEM_GB=$(( INSTANCES * MEM_PER_INSTANCE_GB ))

# An explicit --db-file overrides both the name and the generation step.
if (( DB_FILE_EXPLICIT == 0 )); then
    DB_FILE="import_movies_${DATA_REPS}r_${DATA_COLS}c.csv"
fi

# ─── OS detection + tool helpers ─────────────────────────────────────
# OS_FAMILY: debian | rhel | unknown ; PKG: the package manager command.
detect_os() {
    OS_FAMILY="unknown"; PKG=""
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID:-}" in
            ubuntu|debian) OS_FAMILY="debian" ;;
            centos|rhel|rocky|almalinux|fedora) OS_FAMILY="rhel" ;;
            *) case " ${ID_LIKE:-} " in
                   *debian*) OS_FAMILY="debian" ;;
                   *rhel*|*fedora*|*centos*) OS_FAMILY="rhel" ;;
               esac ;;
        esac
    fi
    if [[ "$OS_FAMILY" == "rhel" ]]; then
        command -v dnf &>/dev/null && PKG=dnf || PKG=yum
    elif [[ "$OS_FAMILY" == "debian" ]]; then
        PKG=apt-get
    fi
}

# True if any cloud-init ISO builder is available.
have_iso_tool() {
    command -v cloud-localds &>/dev/null || command -v genisoimage &>/dev/null \
        || command -v mkisofs &>/dev/null || command -v xorrisofs &>/dev/null
}

# ─── Install host dependencies ───────────────────────────────────────
install_deps() {
    echo "Checking dependencies..."
    # Shared environment (pinned Python + venv, accel-config, build tools),
    # matching tests/redis/setup_redis.sh.
    "${THIS_DIR}/../scripts/install_dependencies.sh"
    detect_os
    local SUDO=""
    if [[ ${EUID:-$(id -u)} -ne 0 ]] && command -v sudo &>/dev/null; then SUDO="sudo"; fi

    local need_qemu=0 need_qemuimg=0 need_nbd=0 need_iso=0
    command -v qemu-system-x86_64 &>/dev/null || [[ -x /usr/libexec/qemu-kvm ]] || need_qemu=1
    command -v qemu-img &>/dev/null || need_qemuimg=1
    command -v qemu-nbd &>/dev/null || need_nbd=1
    have_iso_tool || need_iso=1
    if (( need_qemu==0 && need_qemuimg==0 && need_nbd==0 && need_iso==0 )); then
        echo "  Dependencies OK"; return 0
    fi

    echo "Installing host dependencies (OS family: ${OS_FAMILY})..."
    case "$OS_FAMILY" in
        debian)
            $SUDO apt-get update -qq || echo "  WARNING: 'apt-get update' reported an error (continuing)"
            $SUDO apt-get install -y -qq qemu-system-x86 qemu-utils cloud-image-utils genisoimage openssh-client \
                || echo "  WARNING: 'apt-get install' reported an error (continuing)"
            ;;
        rhel)
            # qemu-img provides qemu-nbd; cloud-utils provides cloud-localds.
            # genisoimage lives in EPEL, so fall back to xorriso from the base repo.
            $SUDO "$PKG" install -y qemu-kvm qemu-img cloud-utils openssh-clients \
                || echo "  WARNING: '$PKG install' (core) reported an error (continuing)"
            $SUDO "$PKG" install -y genisoimage 2>/dev/null \
                || $SUDO "$PKG" install -y xorriso 2>/dev/null \
                || echo "  WARNING: could not install genisoimage/xorriso; install an ISO tool manually."
            # The 'nbd' module used for kernel extraction ships in kernel-modules-extra.
            $SUDO "$PKG" install -y kernel-modules-extra 2>/dev/null || true
            ;;
        *) echo "  WARNING: unsupported distro; install qemu-kvm, qemu-img/qemu-nbd and an ISO tool (genisoimage/xorriso) manually." ;;
    esac

    local still=()
    command -v qemu-system-x86_64 &>/dev/null || [[ -x /usr/libexec/qemu-kvm ]] || still+=(qemu-kvm)
    command -v qemu-img &>/dev/null || still+=(qemu-img)
    # qemu-nbd is only required when libguestfs' virt-copy-out is unavailable.
    command -v qemu-nbd &>/dev/null || command -v virt-copy-out &>/dev/null || still+=("qemu-nbd/virt-copy-out")
    have_iso_tool || still+=("genisoimage/xorriso/cloud-localds")
    if (( ${#still[@]} > 0 )); then echo "ERROR: required tools still missing: ${still[*]}"; exit 1; fi
    echo "  Dependencies OK"
}

# ─── Download base cloud image ───────────────────────────────────────
download_base_image() {
    mkdir -p "$VM_IMAGE_DIR"
    [[ -f "$BASE_IMAGE" ]] && { echo "Base image already exists: $BASE_IMAGE"; return 0; }
    echo "Downloading Ubuntu cloud image..."
    local tmp="${BASE_IMAGE}.tmp"
    wget -q --show-progress -O "$tmp" "$CLOUD_IMAGE_URL"
    qemu-img convert -f qcow2 -O qcow2 "$tmp" "$BASE_IMAGE"
    rm -f "$tmp"
    echo "  Base image: $BASE_IMAGE ($(du -h "$BASE_IMAGE" | cut -f1))"
}

# ─── Build memtier_benchmark from source (OS-aware) ──────────────────
# Guest is always Ubuntu (newer glibc), so a host-built binary runs there
# because glibc is backward compatible.
build_memtier() {
    detect_os
    echo "  memtier_benchmark not found; building from source (OS family: ${OS_FAMILY})..."
    case "$OS_FAMILY" in
        debian)
            sudo apt-get update -qq
            sudo apt-get install -y -qq git build-essential autoconf automake libtool \
                pkg-config libevent-dev libssl-dev zlib1g-dev || return 1 ;;
        rhel)
            sudo "$PKG" install -y git gcc gcc-c++ make autoconf automake libtool \
                pkgconfig libevent-devel openssl-devel zlib-devel pcre-devel || return 1 ;;
        *)
            echo "  ERROR: unknown OS family; cannot auto-build memtier_benchmark."; return 1 ;;
    esac
    local build_dir="${REDIS_DIR}/memtier_benchmark"
    if [[ ! -d "$build_dir/.git" ]]; then
        rm -rf "$build_dir"
        git clone https://github.com/RedisLabs/memtier_benchmark.git "$build_dir" || return 1
    fi
    ( cd "$build_dir" && git checkout 2.4.0 && autoreconf -ivf && ./configure && make ) || return 1
    [[ -x "${build_dir}/memtier_benchmark" ]]
}

# ─── Stage memtier_benchmark (host-side, once) ───────────────────────
stage_memtier() {
    local staged="${VM_IMAGE_DIR}/memtier_benchmark"
    [[ -f "$staged" ]] && { echo "memtier_benchmark already staged: $staged"; return 0; }
    local src=""
    if command -v memtier_benchmark &>/dev/null; then
        src="$(command -v memtier_benchmark)"
    elif [[ -x "${REDIS_DIR}/memtier_benchmark/memtier_benchmark" ]]; then
        src="${REDIS_DIR}/memtier_benchmark/memtier_benchmark"
    fi
    if [[ -z "$src" ]]; then
        if build_memtier; then
            src="${REDIS_DIR}/memtier_benchmark/memtier_benchmark"
        else
            echo "ERROR: memtier_benchmark not found and automatic build failed."
            echo "  Build it manually (e.g. run ${REDIS_DIR}/setup_redis.sh), then re-run setup_vm.sh."
            exit 1
        fi
    fi
    cp "$src" "$staged"; chmod +x "$staged"
    echo "  memtier_benchmark staged from $src"
}

# ─── Extract kernel/initrd via libguestfs (no root / no nbd module) ──
extract_kernel_guestfs() {
    local vmlinuz="$1" initrd="$2"
    local tmp; tmp=$(mktemp -d)
    if ! virt-copy-out -a "$BASE_IMAGE" /boot "$tmp" 2>/dev/null; then rm -rf "$tmp"; return 1; fi
    local k i
    k=$(ls -1 "$tmp"/boot/vmlinuz-* 2>/dev/null | sort -V | tail -1)
    i=$(ls -1 "$tmp"/boot/initrd.img-* 2>/dev/null | sort -V | tail -1)
    if [[ -z "$k" || -z "$i" ]]; then rm -rf "$tmp"; return 1; fi
    cp -L "$k" "$vmlinuz"; cp -L "$i" "$initrd"; chmod 644 "$vmlinuz" "$initrd"
    rm -rf "$tmp"
    return 0
}

# ─── Extract kernel/initrd for direct boot ───────────────────────────
extract_kernel() {
    local vmlinuz="${VM_IMAGE_DIR}/vmlinuz" initrd="${VM_IMAGE_DIR}/initrd.img"
    [[ -f "$vmlinuz" && -f "$initrd" ]] && { echo "Kernel/initrd already extracted"; return 0; }
    echo "Extracting kernel/initrd from base image..."
    # Prefer libguestfs (works on any distro without root or the nbd module).
    if command -v virt-copy-out &>/dev/null && extract_kernel_guestfs "$vmlinuz" "$initrd"; then
        echo "  Kernel:  $vmlinuz"
        echo "  Initrd:  $initrd"
        return 0
    fi
    command -v qemu-nbd &>/dev/null || { echo "ERROR: qemu-nbd required (or install libguestfs-tools for virt-copy-out)"; exit 1; }
    # Ubuntu cloud images keep /boot on partition 16, so nbd needs max_part>=16
    # to create the pNN device nodes.
    sudo modprobe nbd max_part=16 2>/dev/null || true
    if [[ "$(cat /sys/module/nbd/parameters/max_part 2>/dev/null || echo 0)" -lt 16 ]]; then
        if ! ls /sys/block/nbd*/pid >/dev/null 2>&1; then
            sudo rmmod nbd 2>/dev/null && sudo modprobe nbd max_part=16 2>/dev/null || true
        fi
    fi

    local nbd_dev=""
    for i in $(seq 0 15); do
        local sz="/sys/block/nbd${i}/size"
        if [[ -f "$sz" ]] && [[ "$(cat "$sz" 2>/dev/null)" == "0" ]]; then nbd_dev="/dev/nbd${i}"; break; fi
    done
    [[ -z "$nbd_dev" ]] && { echo "ERROR: no usable nbd device. Is the 'nbd' kernel module available? On RHEL/CentOS: sudo $PKG install kernel-modules-extra && sudo modprobe nbd. Or install libguestfs-tools (virt-copy-out)."; exit 1; }

    local mnt_dir=""
    cleanup_nbd() {
        [[ -n "$mnt_dir" ]] && sudo umount "$mnt_dir" 2>/dev/null || true
        [[ -n "$mnt_dir" ]] && rmdir "$mnt_dir" 2>/dev/null || true
        sudo qemu-nbd -d "$nbd_dev" 2>/dev/null || true
    }
    trap cleanup_nbd RETURN

    sudo qemu-nbd --connect "$nbd_dev" "$BASE_IMAGE" || { echo "ERROR: qemu-nbd connect failed"; exit 1; }
    sleep 1
    sudo partprobe "$nbd_dev" 2>/dev/null || true
    sudo partx -a "$nbd_dev" 2>/dev/null || true

    # Wait for partition nodes to appear.
    local tries=0
    while [[ -z "$(ls ${nbd_dev}p* 2>/dev/null)" ]] && (( tries < 20 )); do
        sleep 0.3; sudo partprobe "$nbd_dev" 2>/dev/null || true; sudo partx -a "$nbd_dev" 2>/dev/null || true; (( ++tries ))
    done

    # Locate the partition that holds the kernel/initrd. The /boot partition is
    # historically p16 on Ubuntu cloud images, but the index varies by release,
    # so probe each partition instead of hardcoding it.
    mnt_dir=$(mktemp -d)
    local boot_part="" part krnl_dir=""
    for part in $(ls -1 ${nbd_dev}p* 2>/dev/null | sort -t p -k3 -n); do
        [[ -b "$part" ]] || continue
        sudo mount -o ro "$part" "$mnt_dir" 2>/dev/null || continue
        if [[ -f "$mnt_dir/vmlinuz" && -f "$mnt_dir/initrd.img" ]]; then boot_part="$part"; krnl_dir="$mnt_dir"; break; fi
        if [[ -f "$mnt_dir/boot/vmlinuz" && -f "$mnt_dir/boot/initrd.img" ]]; then boot_part="$part"; krnl_dir="$mnt_dir/boot"; break; fi
        sudo umount "$mnt_dir" 2>/dev/null || true
    done
    [[ -z "$boot_part" ]] && { echo "ERROR: could not find kernel/initrd on any ${nbd_dev} partition"; exit 1; }

    sudo cp -L "$krnl_dir/vmlinuz" "$vmlinuz"
    sudo cp -L "$krnl_dir/initrd.img" "$initrd"
    sudo chmod 644 "$vmlinuz" "$initrd"
    echo "  Kernel:  $vmlinuz"
    echo "  Initrd:  $initrd"
}

# ─── SSH keypair ─────────────────────────────────────────────────────
setup_ssh_keys() {
    local keyfile="${THIS_DIR}/vm_key"
    [[ -f "$keyfile" ]] && { echo "SSH key already exists: $keyfile"; return 0; }
    ssh-keygen -t ed25519 -f "$keyfile" -N "" -q
    echo "  SSH key generated: $keyfile"
}

# ─── Build a cloud-init NoCloud ISO with whatever tool is available ──
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
        echo "ERROR: no ISO tool (cloud-localds/genisoimage/mkisofs/xorrisofs) found"; exit 1
    fi
}

# ─── Cloud-init generation (role-aware hostname; same package set) ───
generate_cloud_init() {
    local role="$1" id="$2"
    local ci_dir="${VM_IMAGE_DIR}/${role}${id}"
    mkdir -p "$ci_dir"
    local ssh_pubkey; ssh_pubkey=$(cat "${THIS_DIR}/vm_key.pub")

    cat > "${ci_dir}/user-data" <<USERDATA
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
USERDATA

    if [[ -n "${http_proxy:-}" ]]; then
        local proxy_host proxy_port proxy_ip
        proxy_host=$(echo "$http_proxy" | sed -E 's|https?://||;s|:([0-9]+)/?$||')
        proxy_port=$(echo "$http_proxy" | grep -oE ':[0-9]+' | tail -1 | tr -d ':')
        proxy_ip=$(getent hosts "$proxy_host" 2>/dev/null | head -1 | awk '{print $1}')
        if [[ -n "$proxy_ip" ]]; then
            local https_port; https_port=$(echo "${https_proxy:-$http_proxy}" | grep -oE ':[0-9]+' | tail -1 | tr -d ':')
            cat >> "${ci_dir}/user-data" <<PROXYDATA

apt:
  http_proxy: http://${proxy_ip}:${proxy_port}
  https_proxy: http://${proxy_ip}:${https_port:-$proxy_port}
PROXYDATA
        fi
    fi

    cat >> "${ci_dir}/user-data" <<'USERDATA'

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

    cat > "${ci_dir}/meta-data" <<META
instance-id: ${role}${id}
local-hostname: ${role}${id}
META

    make_cloud_iso "${ci_dir}/cidata.iso" "${ci_dir}/user-data" "${ci_dir}/meta-data"
    echo "  ${role}${id}: cloud-init ISO created"
}

# ─── Per-VM overlay disk ─────────────────────────────────────────────
create_vm_disk() {
    local role="$1" id="$2"
    local disk="${VM_IMAGE_DIR}/${role}${id}/disk.qcow2"
    mkdir -p "$(dirname "$disk")"
    [[ -f "$disk" ]] && { echo "  ${role}${id}: disk already exists"; return 0; }
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$disk" "${VM_DISK_GB}G"
    echo "  ${role}${id}: overlay disk created (${VM_DISK_GB}GB, COW)"
}

# ─── Generate the redis dataset if missing (mirrors tests/redis/benchmark.sh) ─
generate_dataset() {
    [[ -f "${THIS_DIR}/${DB_FILE}" ]] && { echo "Dataset already present: ${THIS_DIR}/${DB_FILE}"; return 0; }
    if (( DB_FILE_EXPLICIT == 1 )); then
        echo "ERROR: --db-file '${DB_FILE}' not found in ${THIS_DIR}."
        echo "  Provide an existing file, or drop --db-file to auto-generate."
        exit 1
    fi
    echo "=== Generating dataset ${DB_FILE} (reps=${DATA_REPS}, combined_lines=${DATA_COLS}) ==="
    echo "    (this can take a while for large reps/combined_lines values)"
    ( cd "${THIS_DIR}" && python repeat_redis_file.py -r "${DATA_REPS}" -c "${DATA_COLS}" )
}

# ─── Main ─────────────────────────────────────────────────────────────
echo "========================================="
echo " Redis Server/Client VM Benchmark Setup"
echo "========================================="
echo "Server VMs:      $SERVER_VMS  (RAM ${SERVER_MEM_GB}GB = ${INSTANCES}×${MEM_PER_INSTANCE_GB}GB each)"
echo "Client VMs:      $CLIENT_VMS  (RAM ${CLIENT_MEM_GB}GB each)"
echo "Instances/server:$INSTANCES"
echo "Disk/VM:         ${VM_DISK_GB}GB"
echo "Dataset:         $DB_FILE"
echo "========================================="
echo ""

install_deps
generate_dataset
download_base_image
extract_kernel
stage_memtier
setup_ssh_keys

for (( i=1; i<=SERVER_VMS; i++ )); do
    echo "Setting up server$i..."
    create_vm_disk server "$i"
    generate_cloud_init server "$i"
done
for (( i=1; i<=CLIENT_VMS; i++ )); do
    echo "Setting up client$i..."
    create_vm_disk client "$i"
    generate_cloud_init client "$i"
done

echo ""
echo "========================================="
echo " Setup complete"
echo "========================================="
echo "VM images: ${VM_IMAGE_DIR}/{server,client}*/disk.qcow2"
echo "SSH key:   ${THIS_DIR}/vm_key"
echo ""
echo "Next steps:"
echo "  Run the benchmark:     ./benchmark.sh --server-vms ${SERVER_VMS} --instances ${INSTANCES}"
