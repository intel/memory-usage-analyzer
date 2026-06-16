#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

"""workload methods"""
import os
import signal
import shlex
import shutil
import subprocess  # nosec B404
import platform
import re
import time
import sys
from getpass import getuser
from threading import Thread
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
            with open(controller_path, 'r') as f:
                controllers = f.read().strip()
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
        tasks_path = os.path.realpath(
            os.path.join(self.cgpath, 'memory', self.cgname, 'tasks')
        )
        try:
            with open(tasks_path, encoding="utf-8") as fp:
                for pid in fp:
                    try:
                        os.kill(int(pid.strip()), signal.SIGTERM)
                    except (ProcessLookupError, PermissionError, ValueError) as e:
                        self.logger.warning('Failed to send SIGTERM to pid %s: %s', pid.strip(), e)
        except (IOError, OSError) as e:
            self.logger.error('Failed to open tasks file %s: %s', tasks_path, e)

    def _build_perf_cmd(self, perf_args):
        """Build perf command prefix as a list, or empty list if perf disabled."""
        if not self.run_perf:
            return []
        return ['perf', 'stat'] + perf_args + ['-o', self.resultpath + PERF_LOG, '--']

    def _run_with_logging(self, cmd_parts):
        """Run command list, piping stdout+stderr to both console and workload log."""
        workload_log_path = self.resultpath + WORKLOAD_LOG
        with open(workload_log_path, 'w') as log_file:
            proc = subprocess.Popen(cmd_parts, stdout=subprocess.PIPE,  # nosec
                                    stderr=subprocess.STDOUT)
            tee = subprocess.Popen(['tee', workload_log_path],  # nosec  # noqa: F841
                                   stdin=proc.stdout, stdout=log_file)
            proc.stdout.close()
        return proc

    def _cgroup_run(self):
        """Run workload command in the cgroup"""
        cg_procs_path = f'{self.cgpath}/{self.cgname}/cgroup.procs'
        try:
            with open(cg_procs_path, 'w') as f:
                f.write(str(os.getpid()))
        except (IOError, OSError) as e:
            self.logger.error('Failed to write to %s: %s', cg_procs_path, e)

        cmd_parts = self._build_perf_cmd(['-e', 'minor-faults', '-e', 'major-faults'])
        cmd_parts.extend(shlex.split(self.cmd))

        if self.verbose:
            self.logger.debug(cmd_parts)

        return self._run_with_logging(cmd_parts)

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
            with open(memstat_path, 'r') as f:
                swapaccount_enabled = sum(1 for line in f if 'swap' in line)
            if swapaccount_enabled:
                print('[OK] swap accounting enabled')
            else:
                print('[ERROR] swap accounting not enabled (common issue on Ubuntu)')
                print('  Reboot with this kernel parameter: swapaccount=1')

        # check zswap
        zswap_path = '/sys/module/zswap'
        if os.path.exists(zswap_path):
            print('[OK] zswap enabled. zswap parameters: ')

        # check perf
        perf_available = shutil.which('perf')
        if perf_available is not None:
            print(f'[OK] perf tool available ({perf_available})')

        import src as _src_pkg
        script_dir = os.path.join(os.path.dirname(os.path.abspath(_src_pkg.__file__)), 'core')
        result = subprocess.run(['sudo', 'bash', f'{script_dir}/memcomp-report.sh'],  # nosec
                                capture_output=True, text=True, check=False)
        print(result.stdout)

    def run(self):
        """Start the workload: print config, launch the job process, and return it."""
        self.logger.info('**** In run Starting')
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
            self.logger.info('**** Starting job in docker')
            cmd_parts = self._build_perf_cmd(['-d', '-d'])
            cmd_parts.extend(shlex.split(self.cmd))
            job = self._run_with_logging(cmd_parts)
            self.logger.info('**** Waiting for container "%s"', self.docker)
            while not container_id:
                container_id = subprocess.run(  # nosec
                    ['sudo', 'docker', 'ps', '-q', '--no-trunc',
                     '--filter', f'name=^{self.docker}$'],
                    capture_output=True, check=False).stdout.decode().strip()
                time.sleep(0.5)
            self.logger.info('**** Found container "%s" = %s', self.docker, container_id)
            self.container_id = container_id
            # chown -R to current user so the limits can be modified
            self.cgname = 'slice/'
            subprocess.run(['sudo', 'chown', '-R', getuser(),  # nosec
                           f'{self.cgpath}/{self.cgname}'], check=False)

        else:
            self.logger.info('**** Starting job in cgroup')
            job = self._cgroup_run()

        return job, container_id
