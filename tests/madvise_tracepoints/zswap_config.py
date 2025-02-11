#!/usr/bin/env python
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation

import argparse
import os
import subprocess
import sys
import logging
from logging import info, debug, error


def shell(cmd, quiet=False):
    if not quiet:
        debug(f'  shell: {cmd}')
    result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT).stdout
    try:
        result = result.decode().strip()
    except:
        pass
    if result and not quiet:
        debug(f'    result: {result}')
    return result

def read_param(filename):
    if os.path.exists(filename):
        return shell(f'cat {filename}')
    return ""

def read_param_int(filename):
    if os.path.exists(filename):
        return int(shell(filename))
    return int(0)

def write_param(val, filename):
    #print(f'contents {val}, {filename}')
    if os.path.exists(filename):
        shell(f'echo {val} > {filename}')

def status():
    zswap_compressor = shell('cat /sys/module/zswap/parameters/compressor')
    compress_batch_size = read_param(f'/proc/sys/vm/compress-batchsize')
    page_cluster = read_param(f'/proc/sys/vm/page-cluster')
    singlemapped_ra = read_param(f'/sys/kernel/mm/swap/singlemapped_ra_enabled')
    zpool = read_param(f'/sys/module/zswap/parameters/zpool')
    sync_mode = read_param(f'/sys/bus/dsa/drivers/crypto/sync_mode')
    verify_compress = read_param(f'/sys/bus/dsa/drivers/crypto/verify_compress')
    mglru = read_param(f'/sys/kernel/mm/lru_gen/enabled')
    thp_enabled = shell('cat /sys/kernel/mm/transparent_hugepage/enabled')
    thp_defrag = shell('cat /sys/kernel/mm/transparent_hugepage/defrag')
    info('\n================================================================================')
    info('                           ZSWAP SETTINGS')
    info('================================================================================\n')
    info(f'Reclaim compress batchsize = {compress_batch_size}')
    info(f'Swapin readahead page-cluster = {page_cluster}')
    info(f'Singlemapped path readahead = {singlemapped_ra}\n')
    info(f'ZSWAP Compressor = {zswap_compressor}')
    info(f'ZSWAP zpool allocator = {zpool}')
    info(f'iaa_crypto sync mode = {sync_mode}')
    info(f'iaa_crypto verify_compress = {verify_compress}')
    if mglru:
        info(f'mglru = {mglru}')

    info('\n================================================================================')
    info('                           (m)THP SETTINGS')
    info('================================================================================\n')

    szs=(16, 32, 64, 128, 256, 512, 1024, 2048)
    for sz in szs:
        vsz = shell(f'cat /sys/kernel/mm/transparent_hugepage/hugepages-{sz}kB/enabled')
        info(f'hugepages-{sz}kB = {vsz}')
    
    info(f'\nPMD-SIZE THP ENABLED = {thp_enabled}')
    info(f'PMD-SIZE THP DEFRAG = {thp_defrag}')
    info('\n================================================================================\n')


def header(msg, sep='='):
    info('')
    info(msg)
    info(sep * len(msg))
        
def report(args):
    header('zswap')
    info(shell('grep -rH . /sys/module/zswap/parameters /sys/kernel/debug/zswap*', quiet=True))
    header('block devices')
    info(shell('lsblk'))
    header('memory')
    info(shell('free -h'))
    header('config')
    status()

def main(args):
    debug(f'args = {args}')

    write_param('1', f'/sys/module/zswap/parameters/enabled')

    debug('Set system vm options')

    # mTHP settings
    szs=(16, 32, 64, 128, 256, 512, 1024, 2048)
    for sz in szs:
        write_param(f'never', f'/sys/kernel/mm/transparent_hugepage/hugepages-{sz}kB/enabled')

    # Enable the mTHP size selected
    if args.mthp_size != '4' and args.mthp_size != 'all':
        write_param(f'always', f'/sys/kernel/mm/transparent_hugepage/hugepages-{args.mthp_size}kB/enabled')

    if args.mthp_size == 'all':
        for sz in szs:
            write_param(f'always', f'/sys/kernel/mm/transparent_hugepage/hugepages-{sz}kB/enabled')

    # PMD-size THP settings
    write_param(f'{args.trans_hugepage}', f'/sys/kernel/mm/transparent_hugepage/enabled')
    write_param(f'never', f'/sys/kernel/mm/transparent_hugepage/defrag')

    # Other vm settings
    shell('sysctl vm.swappiness=100')
    shell('sysctl vm.overcommit_memory=1')
    shell(f'sysctl vm.page-cluster={args.page_cluster}')
    shell(f'sysctl vm.compress-batchsize={args.compress_batchsize}')

    debug('Configure zswap')
    write_param(f'90', f'/sys/module/zswap/parameters/accept_threshold_percent')
    write_param(f'{args.max_pool}', f'/sys/module/zswap/parameters/max_pool_percent')
    write_param(f'{args.zpool}', f'/sys/module/zswap/parameters/zpool')

    if args.compressor == 'deflate-iaa-canned' or args.compressor == 'deflate-iaa':
        path = os.path.dirname(os.path.realpath(__file__))
        sys.stdout.flush()
        write_param('true', f'/sys/kernel/mm/swap/singlemapped_ra_enabled')

        write_param(f'false', f'/sys/module/zswap/parameters/zlib_compression_enabled')

        write_param(f'{args.compressor}', f'/sys/module/zswap/parameters/compressor')
    else:
        write_param(f'{args.compressor}', f'/sys/module/zswap/parameters/compressor')
        write_param(f'false', f'/sys/module/zswap/parameters/zlib_compression_enabled') 
        write_param('false', f'/sys/kernel/mm/swap/singlemapped_ra_enabled')

    write_param('0', f'/sys/module/zswap/parameters/shrinker_enabled')

    info('Check for swap device')
    swap_devices = int(shell('swapon --noheadings | wc -l'))
    info(f'found {swap_devices} swap devices')
    sys.stdout.flush()
    if swap_devices < 1:
        error('No swap devices found. Setup a swap device before configuring zswap.')
        exit(1)

    debug('Configure MGLRU')
    if os.path.exists('/sys/kernel/mm/lru_gen/enabled'):
        if (args.enable_mglru == True):
            write_param('Y', f'/sys/kernel/mm/lru_gen/enabled')
        else:
            write_param('N', f'/sys/kernel/mm/lru_gen/enabled')

    status()

if __name__ == '__main__':
    if os.geteuid() != 0:
        print('Must run as root or with sudo')
        exit()

    msg = 'configure zswap'
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter, description=msg)
    parser.add_argument('-r', '--report', action='store_true', help='report config and stats only')

    parser.add_argument('-c', '--compressor', default='deflate-iaa', choices=('deflate-iaa-canned', 'deflate-iaa', 'lzo-rle', 'zstd', 'lz4'),
                        help='compression engine (non-iaa_crypto uses software)')
    parser.add_argument('-p', '--page-cluster', type=int, default=3, help='linux readahead (prefetch) control')
    parser.add_argument('-cb_sz', '--compress-batchsize', type=int, choices=range(1, 33), metavar='[1-32]', default=1, help='Number of folios in reclaim compress batch.')
    parser.add_argument('-z', '--zpool', default='zsmalloc', choices=('zsmalloc', 'zbud'),
                        help='zpool allocator')
    parser.add_argument('-v', '--verbose', action='store_true', help='verbose output')
    parser.add_argument('-mp', '--max-pool', type=int, choices=range(1, 100), metavar='[1-99]', default=35,
                        help='Percentage of total memory allocated for the ZSWAP compressed memory pool.')
    parser.add_argument('-M', '--enable-mglru', action='store_true', help='enable mglru')
    parser.add_argument('-pthp', '--trans_hugepage', default='never', choices=('never', 'always', 'madvise'),
                        help='Kernel setting for enabling PMD-size Transparent Hugepages')
    parser.add_argument('-mthp', '--mthp_size', default='4', choices=('4', '16', '32', '64', '128', '256', '512', '1024', '2048', 'all'),
                        help='Kernel setting for enabling mTHP folio allocation size in KB')

    args = parser.parse_args()

    # setup logging
    log_level = logging.DEBUG if args.verbose else logging.INFO
    handlers = [logging.StreamHandler()]
    if args.verbose:
        log_format = '%(levelname)-8s %(asctime)s : %(message)s'
    else:
        log_format = '%(message)s'
        
    logging.basicConfig(level=log_level, format=log_format, handlers=handlers)

    if args.report:
        report(args)
    else:
        main(args)
