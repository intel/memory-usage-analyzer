#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""script to config the swap and zram"""
import argparse
from getpass import getuser
import os
import platform
import re
import shutil
import subprocess
import sys
from subprocess import run
from logging import debug
from packaging import version

def shell(cmd):
    """execute the cmd in the subprocess"""
    debug(f'  shell: {cmd}')
    result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,\
                            check=False).stdout
    try:
        result = result.decode()
    except ImportError:
        pass
    debug(f'    result: {result}')
    return result

def check_requirements(self):
    """Check system configuration."""
    passed = True

    # check linux version
    min_linux_version = '4.18'
    linux_version = re.match(r'(\d+.\d+)', platform.release()).group(1)
    if version.parse(linux_version) >= version.parse(min_linux_version):
        print(f'[OK] Linux kernel version {linux_version} >= {min_linux_version}')
    else:
        print(f'[ERROR] Linux kernel version {linux_version} must be >= {min_linux_version}')
        passed = False

    # check cgroup
    if os.path.exists(self.cgpath):
        print('[OK] cgroup enabled')
    else:
        print('[ERROR] cgroup is not enabled')
        print('  Did not find: ' + self.cgpath)
        passed = False

    # check cgroup swap accounting
    memstat_path = f'{self.cgpath}/memory.stat'

    if os.path.exists(memstat_path):
        swapaccount_enabled = int(run(f'grep -c swap {memstat_path}',
                                    shell=True, capture_output=True, check=False).stdout)
        if swapaccount_enabled:
            print('[OK] swap accounting enabled')
        else:
            print('[ERROR] swap accounting not enabled (common issue on Ubuntu)')
            print('  Reboot with this kernel parameter: swapaccount=1')
            passed = False
    else:
        print('[ERROR] cgroup v1 memory controller not enabled')
        passed = False

    # check zswap
    zswap_path = '/sys/module/zswap'
    if os.path.exists(zswap_path):
        print('[OK] zswap enabled')
    else:
        print('[ERROR] zswap is not enabled')
        print('  Did not find: ' + zswap_path)
        print('  The zswap feature must be enabled in the Linux kernel.')
        passed = False

    # check perf
    perf_available = shutil.which('perf')
    if perf_available is not None:
        print(f'[OK] perf tool available ({perf_available})')
    else:
        print('[ERROR]. perf tool is not available')
        passed = False

    # check python version
    if sys.version_info >= (3,7):
        print('[OK] python version >= 3.7')
    else:
        print('[ERROR] python version < 3.7')
        passed = False

    if not passed:
        print('System config check failed')
        return 1
    return 0

class Config:
    """Configure the zwap and zram"""
    def __init__(self,
                check=True,
                report=True,
                maxpool=35,
                verbose=True,
                freq=None,
                disablezswap=True,
                zramcompressor='lzo',
                cgpath='/sys/fs/cgroup',
                cgname='memoryusageanalyzer',
                cguser=getuser(),
                swap=True,
                ratio=1.0,
                info_file=None):
        self.check = check
        self.report = report
        self.maxpool = maxpool
        self.verbose = verbose
        self.freq = freq
        self.disablezswap = disablezswap
        self.zramcompressor = zramcompressor
        self.cgpath = cgpath
        self.cgname = cgname
        self.cguser = cguser
        self.swap = swap
        self.ratio = ratio
        self.info_file = info_file


    def run(self):
        """run function"""
        script_dir = os.path.dirname(os.path.realpath(__file__))

        if self.info_file is not None:
            fp = open(self.info_file, 'a', encoding="utf-8")
            original_stdout = sys.stdout
            sys.stdout = fp

        ret = check_requirements(self)
        if self.check:
            return ret

        total_memory = os.sysconf('SC_PHYS_PAGES') * os.sysconf('SC_PAGE_SIZE')
        zram_mem_limit = total_memory * self.maxpool / 100
        zram_disksize = 0 if self.swap else zram_mem_limit * self.ratio
        zram_comp_algorithm = self.zramcompressor
        zswap_zpool = 'zsmalloc'
        zswap_enabled = 0 if self.disablezswap else 1
        vm_swappiness = 100

        config_args = ''
        config_args += f'{zram_comp_algorithm} '
        config_args += f'{int(zram_disksize)} '
        config_args += f'{int(zram_mem_limit)} '
        config_args += f'{zswap_zpool} '
        config_args += f'{self.maxpool} '
        config_args += f'{zswap_enabled} '
        config_args += f'{self.cgpath} '
        config_args += f'{self.cgname} '
        config_args += f'{self.cguser} '
        config_args += f'{vm_swappiness} '

        config_cmd = f'sudo bash {script_dir}/config.sh {config_args}'
        if self.verbose:
            print(config_cmd)
        run(config_cmd, shell=True, check=False)

        if self.freq:
            if self.freq == "dynamic":
                print("Setting dynamic frequency limits")
                min_freq = int(shell('cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq'))\
                                // 1000
                max_freq = int(shell('cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq'))\
                                // 1000
                shell(f'cpupower frequency-set -g performance --min {min_freq}MHz\
                      --max {max_freq}MHz > /dev/null')
            if self.freq.isdigit():
                print(f'Setting freqeuncy limits to {self.freq} MHz')
                shell(f'cpupower frequency-set -g performance --min {self.freq}MHz\
                      --max {self.freq}MHz > /dev/null')

        # check if swap device is available
        swap_cmd = 'swapon -s'
        swap_available = run(f'{swap_cmd}', shell=True, capture_output=True, check=False).\
                            stdout.decode()
        if not swap_available:
            print("**** Config.py : swap device is not available")
            return 1

        if self.verbose:
            run(f'sudo bash {script_dir}/report.sh {self.cgpath} {self.cgname}', shell=True,\
                 check=False)

        if self.info_file is not None:
            sys.stdout = original_stdout
        return 0

def main():
    """entry point"""
    os.environ['COLUMNS'] = '128'
    # parse args
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    show_all_args = '-a' in sys.argv or '--all' in sys.argv

    def add_hidden_arg(*args, **kwargs):
        if not show_all_args:
            kwargs['help'] = argparse.SUPPRESS
        parser.add_argument(*args, **kwargs)

    parser.add_argument('-a', '--all', action='help', help='show help message for all args\
                        and exit')
    parser.add_argument('-c', '--check', action='store_true', help='check requirements and exit')
    parser.add_argument('-m', '--max-pool', type=int, default=35, help='max size of compressed\
                        memory pool (%% total memory)')
    parser.add_argument('-v', '--verbose', action='store_true', help='verbose output')
    parser.add_argument('-f', '--freq', type=str, default=None, help='CPU frequency for cpupower\
                        command (MHz)')
    add_hidden_arg('-D', '--disable-zswap', action='store_true', help='disable zswap')
    add_hidden_arg('-R', '--zram-compressor', type=str, default='lzo',\
                   help='zram compression algorithm')
    add_hidden_arg('-p', '--cgpath', type=str, default='/sys/fs/cgroup',\
                   help='path to cgroup mount point')
    add_hidden_arg('-n', '--cgname', type=str, default='memoryusageanalyzer',\
        help='name of cgroup to be created')
    add_hidden_arg('-u', '--cguser', type=str, default=getuser(), help='username of cgroup owner')
    add_hidden_arg('-s', '--swap', action='store_true',\
                   help='use existing swap device instead of zram')
    add_hidden_arg('-z', '--ratio', type=float, default=1.0,\
                   help='compression ratio used to size zram.If 0, zram is disabled.')
    args = parser.parse_args()

    cf = Config(check=args.check,
                maxpool=args.max_pool,
                verbose=args.verbose,
                freq=args.freq,
                disablezswap=args.disable_zswap,
                zramcompressor=args.zram_compressor,
                cgpath=args.cgpath,
                cgname=args.cgname,
                cguser=args.cguser,
                swap=args.swap,
                ratio=args.ratio)
    ret = cf.run()
    if ret:
        sys.exit(1)
    else:
        sys.exit(0)

if __name__ == "__main__":
    main()
