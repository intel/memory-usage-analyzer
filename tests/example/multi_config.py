#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation
"""multi workload run in parallel"""
import argparse
import subprocess
import sys
import json
import os

def multi_config_loading(multiconfig):
    """config parsing"""
    if not multiconfig.endswith('.json'):
        print("Invalid multi config file")
        sys.exit(1)

    if '%00'in multiconfig:
        print("multi config path has null bytes")
        sys.exit(1)

    if not os.path.lexists(multiconfig):
        print("reclaimer config path not exist = %s", multiconfig)
        sys.exit(1)

    if os.path.islink(multiconfig):
        rpath = os.path.realpath(multiconfig)
        if not os.path.lexists(rpath):
            print("multi config path is symbolic path and not exist %s",\
            multiconfig)
            sys.exit(1)

    # load the config file
    config_file = f'{multiconfig}'
    with open(config_file, 'r', encoding="utf-8") as read_file:
        config = json.load(read_file)

    return config

def main():
    """main entry function"""
    os.environ['COLUMNS'] = '128'
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    show_all_args = '-a' in sys.argv or '--all' in sys.argv

    def add_hidden_arg(*args, **kwargs):
        if not show_all_args:
            kwargs['help'] = argparse.SUPPRESS
        parser.add_argument(*args, **kwargs)

    # parse args
    parser.add_argument('-a', '--help-all', action='help',
                        help='show help message for all args and exit')
    parser.add_argument('-v', '--verbose', action='store_true', help='verbose output')
    add_hidden_arg('-m', '--multiconfig', default=None, help='multi workload config path')
    args = parser.parse_args()


    config_list = multi_config_loading(args.multiconfig)
    processes = []
    if config_list:
        for config in config_list:
            cmd = f'memory_usage_analyzer.py -o {config["output"]} --cgname {config["cgroupname"]}\
                    -- {config["cmd"]} {config["options"]}'
            process = subprocess.Popen(cmd.split())
            processes.append(process)

        for process in processes:
            process.wait()

if __name__ == "__main__":
    main()
