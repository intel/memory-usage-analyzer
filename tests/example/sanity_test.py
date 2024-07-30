#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""sanity to test the functionality"""
import argparse
import subprocess
import sys
import os
import json
from jsonschema import validate
from logging import debug

SANITYSCHEMA = {
    "type": "object",
    "properties": {
        "max_mem": {"type": "number",
                   "minimum":8.00,
                   "maximum":8.5},
        "max_static_mem": {"type": "number",
                           "minimum": 7.00,
                           "maximum": 7.5},
        "max_swap": {"type": "number",
                    "minimum":1.00,
                    "maximum":2.00},
        "max_mem_10%_limit": {"type": "number",
                    "minimum":7.00,
                    "maximum":7.5},
        "max_dynamic_swap": {"type": "number",
                    "minimum":4.00,
                    "maximum":5.00}
    },
    "required":["max_mem", "max_static_mem", "max_swap", "max_mem_10%_limit", "max_dynamic_swap"]
}

def shell(cmd, quiet=False):
    """execute the cmd in the sub process"""
    result = None
    if not quiet:
        debug(f'  shell: {cmd}')
        result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE,\
                                stderr=subprocess.STDOUT, check=False).stdout
    try:
        result = result.decode().strip()
    except ImportError:
        pass
    if result and not quiet:
        debug(f'    result: {result}')
    return result

def ref_config_loading(refresults):
    """ref config parsing"""

    if not refresults.endswith('.json'):
        print("Invalid ref config file")
        sys.exit(1)

    if '%00'in refresults:
        print("ref config path has null bytes")
        sys.exit(1)

    if not os.path.lexists(refresults):
        print("ref config path not exist = %s", refresults)
        sys.exit(1)

    if os.path.islink(refresults):
        rpath = os.path.realpath(refresults)
        if not os.path.lexists(rpath):
            print("ref results path is symbolic path and not exist %s",\
            refresults)
            sys.exit(1)

    # load the config file
    config_file = f'{refresults}'
    with open(config_file, 'r', encoding="utf-8") as read_file:
        config = json.load(read_file)

    return config

def tests(arguments):
    """main entry point"""
    result_path = arguments.output
    print("Running baseline example workload test")
    cmd = f'config.py -f 2000'
    shell(cmd)
    cmd=f'zswapcompconfig.py -c lzo-rle'
    shell(cmd)

    #Baseline test
    config = ref_config_loading("./ref_results/sanity_ref_results.json")
    validate(config, SANITYSCHEMA)
    for i in range(arguments.iterations):
        print("iteration =",i)
        cmd = f'memory_usage_analyzer.py -o {result_path} ./workload 8 60 3000'
        shell(cmd)
    max_mem = []
    exec_time = []
    max_swap = []
    for i in range(arguments.iterations):
        if i == 0:
            path = result_path +'/baseline/analyze.out'
            path1 = result_path +'/baseline/perf.log'
        else:
            path = result_path +f'.{i}/baseline/analyze.out'
            path1 = result_path +f'.{i}/baseline/perf.log'
        print(path)
        with open(path, 'r', encoding="utf-8") as output:
            for line in output:
                if "Maximum active+swap memory" in line:
                    print(line)
                    x = line.split()
                    max_mem.append(float(x[4]))

                if "Max swap memory" in line:
                    print(line)
                    x = line.split()
                    max_swap.append(float(x[4]))
                    break

        with open(path1, 'r', encoding="utf-8") as output:
            for line in output:
                if "elapsed" in line:
                    print(line)
                    x = line.split()
                    exec_time.append(float(x[0]))
                    break
    max_mem_total = 0
    exec_time_total = 0
    max_swap_total = 0
    for i in range(arguments.iterations):
        max_mem_total += max_mem[i]
        exec_time_total += exec_time[i]
        max_swap_total += max_swap[i]

    avg_max_mem = (max_mem_total)/len(max_mem)
    avg_exec_time = (exec_time_total)/len(exec_time)
    avg_max_swap = (max_swap_total)/len(max_swap)

    max_mem_diff = abs(avg_max_mem - config["max_mem"])

    if max_mem_diff <= (1*config["max_mem"]/100):
        print("Baseline max_mem is less than 1% limit of ref and test is passed")
    else:
        print("Baseline max_mem is greater than 1% limit of ref and test is failed", max_mem_diff)

    if avg_max_swap > 0:
        print("avg_max_swap greater than zero", avg_max_swap)

    print("Baseline avg_exec_time =", avg_exec_time)

    #static squeezer with 10% mem limit
    print("Running static squeezer with 10% memory limit")
    static_path = f'{result_path}_static'
    for i in range(arguments.iterations):
        print("iteration =",i)
        cmd = f'memory_usage_analyzer.py -o {static_path} -r ./squeezerstatic_sanityconfig.json\
                ./workload 8 60 3000'
        shell(cmd)
    max_mem = []
    exec_time = []
    max_swap = []
    for i in range(arguments.iterations):
        if i == 0:
            path = static_path +'/staticsweep/memory_10/analyze.out'
            path1 = static_path +'/staticsweep/memory_10/perf.log'
        else:
            path = static_path +f'.{i}/staticsweep/memory_10/analyze.out'
            path1 = static_path +f'.{i}/staticsweep/memory_10/perf.log'
        print(path)
        with open(path, 'r', encoding="utf-8") as output:
            for line in output:
                if "Maximum active+swap memory" in line:
                    print(line)
                    x = line.split()
                    max_mem.append(float(x[4]))

                if "Max swap memory" in line:
                    print(line)
                    x = line.split()
                    max_swap.append(float(x[4]))
                    break

        with open(path1, 'r', encoding="utf-8") as output:
            for line in output:
                if "elapsed" in line:
                    print(line)
                    x = line.split()
                    exec_time.append(float(x[0]))
                    break
    max_mem_total = 0
    exec_time_total = 0
    max_swap_total = 0
    for i in range(arguments.iterations):
        max_mem_total += max_mem[i]
        exec_time_total += exec_time[i]
        max_swap_total += max_swap[i]

    avg_max_mem = (max_mem_total)/len(max_mem)
    avg_max_swap = (max_swap_total)/len(max_swap)
    avg_exec_time = (exec_time_total)/len(exec_time)

    max_mem_diff = abs(avg_max_mem - config["max_static_mem"])
    max_swap_diff = abs(avg_max_swap - config["max_swap"])

    if max_mem_diff <= (1*config["max_mem"]/100):
        print("Static max_mem is less than 1% limit of ref and test is passed")
    else:
        print("Static max_mem is greater than 1% limit of ref and test is failed", max_mem_diff)

    if max_swap_diff <= (1*config["max_swap"]/100):
        print("Static max_swap is less than 1% limit of ref and test is passed")
    else:
        print("Static max_swap is greater than 1% limit of ref and test is failed", max_swap_diff)

    print("Static avg_exec_time =", avg_exec_time)
    if avg_max_mem == config["max_mem_10%_limit"]:
        print("avg_max_mem is equal to 10% max current memory", avg_max_mem)

    #Dynamic squeezer
    print("Running dynamic squeezer")
    dynamic_path = f'{result_path}_dynamic'
    for i in range(arguments.iterations):
        print("iteration =",i)
        cmd = f'memory_usage_analyzer.py -o {dynamic_path} -r\
            ../../src/reclaimer/squeezerdynamicconfig.json ./workload 8 60 3000'
        shell(cmd)
    max_mem = []
    exec_time = []
    max_swap = []
    max_zram = []
    for i in range(arguments.iterations):
        if i == 0:
            path = dynamic_path +'/dynamic/analyze.out'
            path1 = dynamic_path +'/dynamic/perf.log'
        else:
            path = dynamic_path +f'.{i}/dynamic/analyze.out'
            path1 = dynamic_path +f'.{i}/dynamic/perf.log'
        with open(path, 'r', encoding="utf-8") as output:
            for line in output:
                if "Maximum active+swap memory" in line:
                    print(line)
                    x = line.split()
                    max_mem.append(float(x[4]))

                if "Max swap memory" in line:
                    print(line)
                    x = line.split()
                    max_swap.append(float(x[4]))

                if "Maximum zram memory " in line:
                    print(line)
                    x = line.split()
                    max_zram.append(float(x[4]))
                    break

        with open(path1, 'r', encoding="utf-8") as output:
            for line in output:
                if "elapsed" in line:
                    print(line)
                    x = line.split()
                    exec_time.append(float(x[0]))
                    break
    max_mem_total = 0
    exec_time_total = 0
    max_swap_total = 0
    max_zram_total = 0
    for i in range(arguments.iterations):
        max_mem_total += max_mem[i]
        exec_time_total += exec_time[i]
        max_swap_total += max_swap[i]
        max_zram_total += max_zram[i]

    avg_max_mem = (max_mem_total)/len(max_mem)
    avg_max_swap = (max_swap_total)/len(max_swap)
    avg_exec_time = (exec_time_total)/len(exec_time)
    avg_max_zram = (max_zram_total)/len(max_zram)

    max_mem_diff = abs(avg_max_mem - config["max_mem"])
    max_swap_diff = abs(avg_max_swap - config["max_dynamic_swap"])

    if max_mem_diff <= (1*config["max_mem"]/100):
        print("Dynamic max_mem is less than 1% limit of ref and test is passed")
    else:
        print("Dynamic max_mem is greater than 1% limit of ref and test is failed", max_mem_diff)

    if max_swap_diff <= (5*config["max_dynamic_swap"]/100):
        print("Dynamic max_swap is less than 5% limit of ref and test is passed")
    else:
        print("Dynamic max_swap is greater than 5% limit of ref and test is failed", max_swap_diff)

    print("Dynamic avg_max_zram is",avg_max_zram)
    print("Dynamic avg_exec_time is",avg_exec_time)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    show_all_args = '-a' in sys.argv or '--all' in sys.argv

    # parse args
    parser.add_argument('-a', '--help-all', action='help', help='show help message for all args\
                        and exit')
    parser.add_argument('-v', '--verbose', action='store_true', help='verbose output')
    parser.add_argument('-i', '--iterations', type=int, default=3, help='no of iterations')
    parser.add_argument('-o', '--output', default='profile', required=True,\
                    help='profiling output directory, uses a unique directory')
    args = parser.parse_args()
    tests(args)
