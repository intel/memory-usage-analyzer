#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""workload methods"""
import os
import signal
import shutil
import subprocess
import platform
import re
import time
import sys
from getpass import getuser
from threading import Thread
from subprocess import run
from packaging import version

PERF_LOG = '/perf.log'
WORKLOAD_LOG = '/workload.log'
INFO_LOG ='/info.log'

class Workload(Thread):
    """To run the given workload with the appropriate Cgroup"""
    def __init__(self,
                cmd,
                cgpath='/sys/fs/cgroup',
                cgname='memoryusageanalyzer',
                docker=None,
                logger=None,
                verbose=True,
                resultpath = '.'):
        Thread.__init__(self)
        self.cmd = cmd
        self.cgpath = cgpath
        self.cgname = cgname
        self.docker = docker
        self.run_perf = True
        self.verbose = verbose
        self.logger = logger
        self.resultpath = resultpath
        self.container_id = 0

        controller_path = os.path.join(self.cgpath, "cgroup.controllers")
        if os.path.exists(controller_path):
            controllers = subprocess.run(f'cat {controller_path}', shell=True, capture_output=True,\
                                         check=False).stdout.decode().strip()
            if 'memory' in controllers:
                self.cg2_detected = True
                self.logger.info('cgroup v2 enabled and memory controller detected')
            else:
                self.logger.error('cgroup v2 enabled but memory controller not detected')
                sys.exit(1)
        else:
            self.cg2_detected = False

        if self.docker and self.cg2_detected:
            self.cgname = 'slice'

    def __str__(self):
        """Return class attributes as a string (for debugging/logging)."""
        return str(vars(self))

    def stop(self):
        """Send SIGTERM to all tasks in the cgroup"""

        with open(f'{self.cgpath}/memory/{self.cgname}/tasks', encoding="utf-8") as fp:
            for pid in fp:
                os.kill(int(pid), signal.SIGTERM)

    def _cgroup_run(self):
        """Run workload command in the cgroup"""

        perf = f'perf stat -e minor-faults -e major-faults -o {self.resultpath + PERF_LOG} --'\
                if self.run_perf else '' # adding -d -d will create ~10s overhead
        string = r'\$$'
        cmd = f'bash -c "echo {string} > {self.cgpath}/{self.cgname}/cgroup.procs && {perf}\
                {self.cmd}" 2>&1 | tee { self.resultpath + WORKLOAD_LOG}'

        if self.verbose:
            self.logger.debug(cmd)
        return subprocess.Popen(cmd, shell=True)

    def print_config(self):
        """print the platform configuration"""
        # check linux version
        min_linux_version = '4.18'
        linux_version = re.match(r'(\d+.\d+)', platform.release()).group(1)
        if version.parse(linux_version) >= version.parse(min_linux_version):
            print(f'[OK] Linux kernel version {linux_version} >= {min_linux_version}')

        # check cgroup
        if os.path.exists(self.cgpath):
            print('[OK] cgroup enabled')
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

        # check zswap
        zswap_path = '/sys/module/zswap'
        if os.path.exists(zswap_path):
            print('[OK] zswap enabled.')

        # check perf
        perf_available = shutil.which('perf')
        if perf_available is not None:
            print(f'[OK] perf tool available ({perf_available})')

    def run(self):
        self.logger.info(f'{"**** In run Starting"}')
        print("workload start")
        # check and print the system config in the info file
        with open(f'{self.resultpath + INFO_LOG}', 'a', encoding="utf-8") as fp:
            original_stdout = sys.stdout
            sys.stdout = fp
            self.print_config()
            sys.stdout = original_stdout

        container_id = ''
        # start job
        if self.docker:
            self.logger.info(f'{"**** Starting job in docker"}')
            cmd = f'{self.cmd} 2>&1 | tee {self.resultpath + WORKLOAD_LOG}'
            perf = f'perf stat -d -d -o {self.resultpath + PERF_LOG} --' if self.run_perf else ''
            cmd = f'{perf} {cmd}'
            job = subprocess.Popen(cmd, shell=True)
            self.logger.info(f'**** Waiting for container "{self.docker}"')
            while not container_id:
                cmd = f'sudo docker ps -q --no-trunc --filter name=^{self.docker}$'
                container_id = subprocess.run(cmd, shell=True, capture_output=True, check=False).\
                                stdout.decode().strip()
                time.sleep(0.5)
            self.logger.info(f'**** Found container "{self.docker}" = {container_id}')
            self.container_id = container_id
            # chown -R to current user so the limits can be modified
            self.cgname = f'{"slice/"}'
            subprocess.run(f'sudo chown -R {getuser()} {self.cgpath}/{self.cgname}', shell=True,\
                           check=False)

        else:
            self.logger.info(f'{"**** Starting job in cgroup"}')
            job = self._cgroup_run()

        return job, container_id
