#!/usr/bin/env python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

"""zswap compression config"""
import argparse
import glob as glob_module
import os
import shlex
import sys
import subprocess  # nosec B404
import logging
from logging import info, debug, error

def shell(cmd, quiet=False):
    """execute the cmd"""
    if not quiet:
        debug(f'  shell: {cmd}')
    result = subprocess.run(shlex.split(cmd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,\
                            check=False).stdout  # nosec B603
    if result is not None:
        try:
            result = result.decode().strip()
        except (UnicodeDecodeError, AttributeError):
            pass
    if result and not quiet:
        debug(f'    result: {result}')
    return result

def write_param(val, filename):
    """write the sysfs params"""
    print(f'contents {val}, {filename}')
    if os.path.exists(filename):
        try:
            with open(filename, 'w') as f:
                f.write(str(val))
        except (IOError, OSError) as e:
            error(f'Failed to write {val} to {filename}: {e}')

def status():
    """cat the zswap compressor params"""
    with open('/sys/module/zswap/parameters/compressor', 'r') as f:
        compressor = f.read().strip()
    info(f'Compressor = {compressor}')

def header(msg, sep='='):
    """header info"""
    info('')
    info(msg)
    info(sep * len(msg))

def report():
    """consolidated report"""
    header('zswap')
    paths = ['/sys/module/zswap/parameters'] + glob_module.glob('/sys/kernel/debug/zswap*')
    grep_result = subprocess.run(['grep', '-rH', '.'] + paths,
                                 capture_output=True, check=False).stdout.decode().strip()  # nosec B603
    info(grep_result)
    header('block devices')
    info(shell('lsblk'))
    header('memory')
    info(shell('free -h'))
    header('config')
    status()

def run(inputs):
    """main entry"""
    debug(f'arguments = {inputs}')

    debug('Disable swap')
    write_param('0', f'{"/sys/module/zswap/parameters/enabled"}')
    shell('swapoff -a')

    debug('Clean zswap stats')
    for filepath in glob_module.glob('/sys/kernel/debug/zswap/total*'):
        try:
            with open(filepath, 'w') as f:
                f.write('0')
        except (IOError, OSError):
            pass
    for filepath in glob_module.glob('/sys/kernel/debug/total_zswap_*'):
        try:
            with open(filepath, 'w') as f:
                f.write('0')
        except (IOError, OSError):
            pass

    if inputs.compressor in ('deflate-iaa-canned' , 'deflate-iaa', 'deflate'):
        # Resolve to source tree's config_script dir via the installed 'src' package,
        # so editable installs use the source scripts, not stale copies in bin/.
        import src as _src_pkg
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(_src_pkg.__file__))),
                            'tests', 'config_script')
        sys.stdout.flush()
        write_param(f'lzo-rle', f'/sys/module/zswap/parameters/compressor')
        # Disable IAA crypto to allow configuration as some parameters needs this
        # Disable IAA to start with
        shell(f'{path}/disable_iaa.sh')
        write_param(f'false', f'/sys/module/zswap/parameters/zlib_compression_enabled')

        # This will reconfigure iaa_crypto_enable
        output = shell(f'{path}/configure_iaa.sh')
        sys.stdout.flush()
        info('\n'.join(output.split('\n')[-3:]))
        write_param(f'{inputs.compressor}', f'/sys/module/zswap/parameters/compressor')
    else:
        # Disable IAA if it was previously active, so sync_mode can be written
        import src as _src_pkg
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(_src_pkg.__file__))),
                            'tests', 'config_script')
        shell(f'{path}/disable_iaa.sh')
        write_param(f'{inputs.compressor}', f'/sys/module/zswap/parameters/compressor')
        write_param(f'sync', f'/sys/bus/dsa/drivers/crypto/sync_mode')
        write_param(f'false', f'/sys/module/zswap/parameters/zlib_compression_enabled')

    debug('Enable swap')
    if not os.path.exists('/dev/zram0'):
        error('zram is not configured. Run config.py first.')
        sys.exit(1)
    shell('swapon /dev/zram0')

    write_param('1', f'{"/sys/module/zswap/parameters/enabled"}')

    debug('Check for swap device')
    swap_result = subprocess.run(['swapon', '--noheadings'], capture_output=True,  # nosec
                                  check=False).stdout.decode().strip()
    swap_devices = len(swap_result.splitlines()) if swap_result else 0
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
    parser.add_argument('-c', '--compressor', default='lzo-rle', choices=('deflate',\
            'deflate-iaa', 'lzo-rle', 'zstd', 'rle1a'), help='compression engine (software)')
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
        run(arguments)
