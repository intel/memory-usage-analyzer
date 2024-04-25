#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""squeezer to limit the memory"""
import re
import glob
import subprocess
import time
import os
import sys
import csv
import pandas
from jsonschema import validate
from src.core.util import kernel_version, max_memory_usage
from src.reclaimer.basereclaimer import Reclaimer

STATICSCHEMA = {
    "type": "object",
    "properties": {
        "mode": {"type": "string",
                 "maxLength": 64 },
        "reclaimer": {"type": "string",
                      "maxlength": 64},
        "reclaimer_file": {"type": "string",
                           "maxlength": 128},
        "params_ranges":{
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "with_baseline": {"type": "integer",
                                      "minimum": 0,
                                      "maximum": 1},
                    "param": {"type": "string",
                              "maxlength": 64},
                    "range": {"type": "array",
                              "maxlength": 32}
                },
                "required": ["with_baseline", "param", "range"]
            },
        },
        "init_limit": {"type": "integer",
                       "minimum": 0,
                       "maximum": 1125899906842624},
        "max_limit": {"type": "number",
                      "maximum": 1125899906842624},
    },
    "required": ["mode", "reclaimer", "reclaimer_file", "params_ranges"]
}

DYNAMICSCHEMA = {
    "type": "object",
    "properties": {
        "mode": {"type": "string",
                 "maxLength": 64},
        "reclaimer": {"type": "string",
                      "maxLength": 64},
        "reclaimer_file": {"type": "string",
                           "maxLength": 128},
        "init_limit": {"type": "integer",
                       "minimum": 0,
                       "maximum": 1125899906842624},
        "min_limit": {"type": "integer",
                      "minimum": 0,
                      "maximum": 1125899906842624},
        "max_limit": {"type": "number",
                      "maximum": 1125899906842624},
        "delay": {"type": "integer",
                  "maximum": 3},
        "fixed": {"type": "integer",
                  "minimum": 0,
                  "maximum": 0},
        "squeeze_max": {"type": "integer",
                        "maximum": 10},
        "squeeze_delta": {"type": "integer",
                          "minimum": 1,
                          "maximum": 10},
        "squeeze_timeout": {"type": "integer",
                            "minimum": 1,
                            "maximum": 5},
        "pf_rate_watermark": {"type": "integer",
                              "maximum": 10000},
    },
    "required": ["mode", "reclaimer", "reclaimer_file", "init_limit", "min_limit", "max_limit",\
                 "delay", "fixed", "squeeze_max", "squeeze_delta", "squeeze_timeout",\
                "pf_rate_watermark"]
}
def get_key_value(line):
    """get the key value pair"""
    try:
        key, value = line.split(':', 1)
    except ValueError:
        print(f'DEBUG: Unexpected stat result = {line}')
        return 0, 0
    key = key.split('/')[-1]

    value = value.split()
    if len(value) == 1:
        value = value[0]
    elif len(value) == 2:
        field, value = value
        key += ':' + field
    else:
        field = value[0]
        key += ':' + field
        value = "'" + ' '.join(value[1:]) + "'"
        m = re.search(r'total=(\d+)', value)
        if m:
            value = m.group(1)

    return key, value


def read_stats(paths):
    """read the status"""
    result = {}
    for path in paths:
        lines = subprocess.run(f'sudo grep . -rH {path}', shell=True, capture_output=True,\
                               check=False).stdout.decode().strip()
        for line in lines.split('\n'):
            key, value = get_key_value(line)
            try:
                result[key] = int(value)
            except:
                result[key] = value
    return result


class Squeezer(Reclaimer):
    """dynamic and static memory squeezer"""
    def __init__(self, cgpath, cgname, sample_period, config):
        super().__init__()
        self.mode = config["mode"]
        if self.mode == 'staticsweep':
            validate(config, schema=STATICSCHEMA)
        if self.mode == 'dynamic':
            validate(config, schema=DYNAMICSCHEMA)

        self.cgpath = cgpath
        self.cgname = cgname
        self.sample_period = sample_period
        self.init_limit = config["init_limit"]
        self.max_limit = config["max_limit"]
        self.active = False

        if self.mode == 'dynamic':
            self.fixed = config["fixed"]
            self.min_limit = config["min_limit"]
            self.squeeze_max = config["squeeze_max"]
            self.squeeze_delta = config["squeeze_delta"]
            self.squeeze_timeout = config["squeeze_timeout"]
            self.pf_rate_watermark = config["pf_rate_watermark"]
            self.init_delay = config["delay"]

        self.state = None
        self.linux_version = kernel_version()
        self.update_state()

        if self.linux_version >= 5.15:
            self.csv_file = open('squeezer.csv', 'w', encoding="utf-8")
            self.csv_writer = csv.writer(self.csv_file)
            self.csv_writer.writerow(["time", "mem_limit"])

    def shutdown(self):
        """stop the squeezer"""
        self.active = False

    def delay_gen(self):
        """Return delay value based on sample_period and initial start time."""
        next_time = time.time()

        while True:
            next_time += self.sample_period
            yield max(next_time - time.time(), 0)

    def update_state(self):
        """read the environment state"""
        self.prev_state = self.state
        self.state = read_stats([f'{self.cgpath}/{self.cgname}'])

    def squeeze(self, percent):
        """set dynamic memory limit based on the squeeze percent"""
        success = True
        if self.fixed:
            print('Using fixed squeeze value')
            value = self.fixed
        else:
            value = int((100 - percent) / 100 * self.state['memory.current'])

        if self.fixed or percent > 0 and value > self.min_limit:
            print(f'   squeeze to {value:,}', end='')
            # save the timestamp and memory limit in squeezer.csv
            self.csv_writer.writerow([f'{time.time()}', f'{value}'])

            try:
                # cannot use sudo here, because killing process after a timeout will fail
                # therefore, we need to chown -R the cgroup path to the current user in
                # Memoryusageanalyzer.run
                cmd = f'echo {value} > {self.cgpath}/{self.cgname}/memory.high'
                subprocess.run(cmd,
                               shell=True,
                               check=True,
                               stderr=subprocess.DEVNULL,
                               timeout=self.squeeze_timeout)
                print(' -- ok')
            except subprocess.TimeoutExpired:
                print(' -- timeout')
                success = False
            except subprocess.CalledProcessError:
                print(' -- busy')
                success = False
            # release squeeze (twice because the first one fails sometimes when the try block
            # above fails)
            cmd = f'echo {self.max_limit} > {self.cgpath}/{self.cgname}/memory.high'
            subprocess.run(cmd, shell=True, check=False)
            subprocess.run(cmd, shell=True, check=False)
        else:
            cmd = f'echo {self.max_limit} > {self.cgpath}/{self.cgname}/memory.high'
            subprocess.run(cmd, shell=True, check=False)
            value = 0
        return value, success

    def config_sweep_param(self, param, range_value, path):
        """set the static memory limit"""
        if param["with_baseline"]:
            # if available, use baseline stats in result_path to set args.max_limit
            baseline_stats = glob.glob(f'{path}/{self.mode}/stats.csv.gz')
            if baseline_stats:
                max_limit = 0
                for stats in baseline_stats:
                    df = pandas.read_csv(stats)
                    # Set the max_limit to be the maximum memory used in baseline,
                    # excluding the page-cache if any
                    max_limit = max(max_limit, max_memory_usage(df, gb=False))

                self.max_limit = max_limit
                print(f'**** Using max_limit from baseline run: {self.max_limit} =\
                      {self.max_limit / (1<<30):.3f} GiB')
            else:
                print(f'**** Using max_limit from config: {self.max_limit}')

        if param["param"] == "memory":
            self.init_limit = int((100.0 - range_value) / 100.0 * self.max_limit)

    def run(self):
        """apply the static or dynamic memory limit"""

        # apply initial memory limit
        if self.init_limit:
            print(f'**** Initial memory limit = {self.init_limit}')
            subprocess.run(f'echo {self.init_limit} > {self.cgpath}/{self.cgname}/memory.high',\
                           shell=True, check=False)
        if self.mode == "staticsweep":
            print('**** Squeezer exiting')
            self.csv_file.close()
            return
        # set the initial delay
        if self.init_delay:
            time.sleep(self.init_delay)

        # get the delay to set between the dynamic squeeze
        delay = self.delay_gen()

        squeeze_percent = 0
        success = True

        # dynamic squeeze
        self.active = True
        while self.active:
            # read environment state
            self.update_state()
            try:
                pf_rate = (self.state['memory.stat:pgmajfault'] -\
                           self.prev_state['memory.stat:pgmajfault']) / self.sample_period
            except ImportError:
                if os.path.exists(f'{self.cgpath}/memory/{self.cgname}') or\
                    os.path.exists(f'{self.cgpath}/{self.cgname}'):
                    print("DEBUG: unexpected behavior in squeezer")
                else:
                    self.active = False
                    continue

            # adjust squeeze percent
            if pf_rate > self.pf_rate_watermark:
                squeeze_percent = 0
            elif not success:
                squeeze_percent -= self.squeeze_delta
            else:
                squeeze_percent += self.squeeze_delta

            squeeze_percent = max(0, min(squeeze_percent, self.squeeze_max))

            # apply action to environment
            print(f'memory usage = {self.state["memory.current"]:,} pf_rate = {pf_rate} =>\
                  squeeze percent = {squeeze_percent}% ')
            squeeze_value, success = self.squeeze(squeeze_percent)

            if squeeze_value == 0:
                squeeze_percent = 0

            # read environment state
            self.update_state()
            sys.stdout.flush()
            time.sleep(next(delay))

        print('**** Squeezer exiting')
        if self.linux_version >= 5.15:
            self.csv_file.close()
