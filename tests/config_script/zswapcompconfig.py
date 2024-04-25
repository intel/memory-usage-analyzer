#!/usr/bin/env python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""zswap compression config"""
import argparse
import os
import sys
import subprocess
import logging
from logging import info, debug, error

def shell(cmd, quiet=False):
    """execute the cmd"""
    if not quiet:
        debug(f'  shell: {cmd}')
    result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,\
                            check=False).stdout
    try:
        result = result.decode().strip()
    except ImportError:
        pass
    if result and not quiet:
        debug(f'    result: {result}')
    return result

def write_param(val, filename):
    """write the sysfs params"""
    print(f'contents {val}, {filename}')
    if os.path.exists(filename):
        shell(f'echo {val} > {filename}')

def status():
    """cat the zswap compressor params"""
    compressor = shell('cat /sys/module/zswap/parameters/compressor')
    info(f'Compressor = {compressor}')

def header(msg, sep='='):
    """header info"""
    info('')
    info(msg)
    info(sep * len(msg))

def report():
    """consolidated report"""
    header('zswap')
    info(shell('grep -rH . /sys/module/zswap/parameters /sys/kernel/debug/zswap*', quiet=True))
    header('block devices')
    info(shell('lsblk'))
    header('memory')
    info(shell('free -h'))
    header('config')
    status()

def main(inputs):
    """main entry"""
    debug(f'arguments = {inputs}')

    debug('Disable swap')
    write_param('0', f'{"/sys/module/zswap/parameters/enabled"}')
    shell('swapoff -a')

    write_param(f'{arguments.compressor}', f'{"/sys/module/zswap/parameters/compressor"}')

    debug('Enable swap')
    if not os.path.exists('/dev/zram0'):
        error('zram is not configured. Run config.py first.')
        sys.exit(1)
    shell('swapon /dev/zram0')

    write_param('1', f'{"/sys/module/zswap/parameters/enabled"}')

    debug('Check for swap device')
    swap_devices = int(shell('swapon --noheadings | wc -l'))
    debug(f'found {swap_devices} swap devices')
    if swap_devices < 1:
        error('No swap devices found. Setup a swap device before configuring zswap.')
        sys.exit(1)

    status()

if __name__ == '__main__':
    if os.geteuid() != 0:
        print('Must run as root or with sudo')
        sys.exit()

    MSG = 'config zswap compressor'
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter,\
                                     description=MSG)
    parser.add_argument('-r', '--report', action='store_true', help='report config and stats only')
    parser.add_argument('-c', '--compressor', default='lzo-rle', choices=\
            ('lzo-rle', 'zstd', 'rle1a'), help='compression engine (software)')
    parser.add_argument('-v', '--verbose', action='store_true', help='verbose output')

    arguments = parser.parse_args()

    # setup logging
    LOG_LEVEL = logging.DEBUG if arguments.verbose else logging.INFO
    handlers = [logging.StreamHandler()]
    if arguments.verbose:
        LOG_FORMAT = '%(levelname)-8s %(asctime)s : %(message)s'
    else:
        LOG_FORMAT = '%(message)s'

    logging.basicConfig(level=LOG_LEVEL, format=LOG_FORMAT, handlers=handlers)

    if arguments.report:
        report()
    else:
        main(arguments)
