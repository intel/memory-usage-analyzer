#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""Main Application module"""
import argparse
import os
import subprocess
import logging
import time
import sys
import json
import importlib.util
from getpass import getuser
from src.core.util import unique_dir
from src.analyzer.analyze import Analyzer
from src.core.workload import Workload

STATS_LOG = '/stats.csv'
ANALYZER_OUTPUT ='/analyze.out'
SAMPLE_PERIOD_MAX = 10

logger = logging.getLogger("memoryusageanalyzer")
logger.setLevel(level=logging.INFO)
handler = logging.FileHandler(f'output_{time.strftime("%Y%m%d-%H%M%S")}.log', 'w')
formatter = logging.Formatter('%(asctime)s - %(name)s - %(levelname)s - %(message)s')
handler.setFormatter(formatter)
logger.addHandler(handler)

console = logging.StreamHandler()
console.setLevel(logging.INFO)
console.setFormatter(formatter)
logger.addHandler(console)

class MemoryUsageAnalyzer:
    """  Memoryusageanalyzer entry class"""
    def __init__(self,
                verbose,
                output,
                outputforce,
                sampleperiod,
                docker,
                cgpath,
                cgname,
                reclaimerconfig,
                cmd):
        self.verbose = verbose
        self.output = output
        self.outputforce = outputforce
        self.sampleperiod = sampleperiod
        self.docker = docker
        self.cgpath = cgpath
        self.cgname = cgname
        self.reclaimerconfig = reclaimerconfig
        self.cmd = cmd
        self.job = None
        self.container_id = None
        self.rec_inst = None
        self.stats = None
        self.reclaimer = None
        self.report = None
        self.cgroup_path_create()

    def cgroup_path_create(self):
        """creation of cgroup directory based on cgname"""
        script_dir = os.path.dirname(os.path.realpath(__file__))
        config_args = ''
        config_args += f'{self.cgpath} '
        config_args += f'{self.cgname} '
        cguser = getuser()
        config_args += f'{cguser} '
        config_cmd = f'sudo bash {script_dir}/cgroup_config.sh {config_args}'
        if self.verbose:
            print(config_cmd)
        result = subprocess.run(config_cmd, shell=True, check=False)
        return result

    def reclaimer_config_module_loading(self, result_path):
        """Reclaimer config parsing and the reclaimer module loading"""
        rec_module = None
        params_list = None
        path = None
        if not self.reclaimerconfig.endswith('.json'):
            logger.error("Invalid reclaimer config file")
            sys.exit(1)

        if '%00'in self.reclaimerconfig:
            logger.error("reclaimer config path has null bytes")
            sys.exit(1)

        if not os.path.lexists(self.reclaimerconfig):
            logger.error("reclaimer config path not exist = %s", self.reclaimerconfig)
            sys.exit(1)

        if os.path.islink(self.reclaimerconfig):
            rpath = os.path.realpath(self.reclaimerconfig)
            if not os.path.lexists(rpath):
                logger.error("reclaimer config path is symbolic path and not exist %s",\
                    self.reclaimerconfig)
                sys.exit(1)

        # load the config file
        config_file = f'{self.reclaimerconfig}'
        with open(config_file, 'r', encoding="utf-8") as read_file:
            config = json.load(read_file)

        # find and load the reclaimer module
        spec = importlib.util.spec_from_file_location(config["reclaimer"], config["reclaimer_file"])
        rec_module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(rec_module)
        rec_class = getattr(rec_module, config["reclaimer"])
        self.make_resultdir(result_path, config["mode"])
        report = result_path + f'/{config["mode"]}'

        # sweep parameters parsing
        if 'params_ranges' in config:
            params_list = config["params_ranges"]
            path = result_path + f'/{config["mode"]}'

        return rec_class, config, params_list, report, path

    def make_resultdir(self,path, name):
        """creates the unique dir"""
        path = unique_dir(f'{path}/{name}')
        try:
            os.mkdir(path)
        except FileExistsError:
            pass

    def run_workload(self, cmd, report, rec_class, config, path=None, param=None, range_value=None):
        """Instantiate the reclaimer & workload and execute them with background stats collection"""
        if config:
            # initiate the reclaimer
            rec_inst = rec_class(self.cgpath,
                    self.cgname,
                    self.sampleperiod,
                    config)
            if rec_inst is None:
                print("No reclaimer initialized")
                sys.exit(1)
            reclaimer = True
        else:
            rec_inst = None
            reclaimer = False

        if param:
            # config the sweep parameter
            rec_inst.config_sweep_param(param, range_value, path)

        # initiate the workload with appropriate parameters
        wl = Workload(cmd,
            cgpath=self.cgpath,
            cgname=self.cgname,
            docker=self.docker,
            logger=logger,
            verbose=self.verbose,
            resultpath=report)

        # run the workload
        job, container_id = wl.run()

        # start stats collection
        logger.info("**** Starting stats")
        stats_cmd = f'stats.py -p {self.sampleperiod} -o {report + STATS_LOG} \
                        --cgpath {self.cgpath} --cgname {self.cgname}'
        stats = subprocess.Popen(stats_cmd.split())

        # start reclaimer
        if reclaimer:
            logger.info("**** Starting reclaimer")
            rec_inst.start()

        # wait for job to finish
        job_interrupted = False
        try:
            job.wait()
            logger.info("**** Job finished")
        except KeyboardInterrupt:
            logger.info("**** Job interrupted, cleaning up")
            job_interrupted = True
            if container_id:
                logger.info("**** Stopping docker container")
                subprocess.run(f'sudo docker stop {container_id}', shell=True, check=False)

        # save stats
        logger.info("**** Stopping stats")
        stats.terminate()
        stats.wait()

        # stop reclaimer
        if reclaimer:
            logger.info("**** Stopping reclaimer")
            rec_inst.shutdown()
            rec_inst.join()

        if job_interrupted:
            logger.warning("**** Job interrupted, exiting")
            sys.exit(1)

        print(report)
        # initiate the Analyzer
        al = Analyzer(report)
        # generate report
        with open(f'{report + ANALYZER_OUTPUT}', 'a', encoding="utf-8") as fp:
            original_stdout = sys.stdout
            sys.stdout = fp
            al.run()
            sys.stdout = original_stdout

        with open(f'{report + ANALYZER_OUTPUT}', 'r', encoding="utf-8") as fp:
            print(fp.read())

    def run_workload_schedule(self, cmd, report, rec_class, config, path=None, param=None,
                              range_value=None):
        """Instantiate the reclaimer & workload and execute them with background stats collection"""
        if config:
            # initiate the reclaimer
            self.rec_inst = rec_class(self.cgpath,
                    self.cgname,
                    self.sampleperiod,
                    config)
            if self.rec_inst is None:
                print("No reclaimer initialized")
                sys.exit(1)
            self.reclaimer = True
        else:
            self.rec_inst = None
            self.reclaimer = False

        if param:
            # config the sweep parameter
            self.rec_inst.config_sweep_param(param, range_value, path)

        # initiate the workload with appropriate parameters
        wl = Workload(cmd,
            cgpath=self.cgpath,
            cgname=self.cgname,
            docker=self.docker,
            logger=logger,
            verbose=self.verbose,
            resultpath=report)

        # run the workload
        self.job, self.container_id = wl.run()

        # start stats collection
        logger.info("**** Starting stats")
        stats_cmd = f'stats.py -p {self.sampleperiod} -o {report + STATS_LOG} \
                        --cgpath {self.cgpath} --cgname {self.cgname}'
        self.stats = subprocess.Popen(stats_cmd.split())

        # start reclaimer
        if self.reclaimer:
            logger.info("**** Starting reclaimer")
            self.rec_inst.start()

    def wait(self):
        """wait for job to finish"""
        job_interrupted = False
        try:
            if self.job:
                self.job.wait()
                logger.info("**** Job finished")
            else:
                return
        except KeyboardInterrupt:
            logger.info("**** Job interrupted, cleaning up")
            job_interrupted = True
            if self.container_id:
                logger.info("**** Stopping docker container")
                subprocess.run(f'sudo docker stop {self.container_id}', shell=True, check=False)

        # save stats
        logger.info("**** Stopping stats")
        self.stats.terminate()
        self.stats.wait()

        # stop reclaimer
        if self.reclaimer:
            logger.info("**** Stopping reclaimer")
            self.rec_inst.shutdown()
            self.rec_inst.join()

        if job_interrupted:
            logger.warning("**** Job interrupted, exiting")
            sys.exit(1)

        print(self.report)
        # initiate the Analyzer
        al = Analyzer(self.report)
        # generate report
        with open(f'{self.report + ANALYZER_OUTPUT}', 'a', encoding="utf-8") as fp:
            original_stdout = sys.stdout
            sys.stdout = fp
            al.run()
            sys.stdout = original_stdout

        with open(f'{self.report + ANALYZER_OUTPUT}', 'r', encoding="utf-8") as fp:
            print(fp.read())

    def run(self, schedule=False):
        """Reclaimer config parsing & Loading. Starting the workload runs"""

        if '%00'in self.output:
            logger.error("profiling output directory has null bytes")
            sys.exit(1)

        if self.output != 'profile':
            if not os.path.lexists(self.output):
                logger.info("output result path not exist = %s, creating one", self.output)

        if os.path.islink(self.output):
            rpath = os.path.realpath(self.output)
            if not os.path.lexists(rpath):
                logger.error("output result path is symbolic path and not exist %s",\
                    self.output)
                sys.exit(1)

        result_path = unique_dir(self.output) if self.outputforce is None else self.outputforce
        logger.info("**** Storing profiling results in %s", result_path)

        if self.cmd:
            if schedule:
                cmd = f'{self.cmd}'
            else:
                cmd = f'{" ".join(self.cmd)}'
        else:
            logger.error("cmd args not provided = %s", self.cmd)
            sys.exit(1)

        if self.sampleperiod > SAMPLE_PERIOD_MAX:
            logger.error("sample_period greater than the max limit")
            sys.exit(1)

        report = result_path + '/baseline'
        rec_class = None
        params_list = None
        path = None
        if self.reclaimerconfig:
            # reclaimer config and module loading
            rec_class, config, params_list, report, path =\
                    self.reclaimer_config_module_loading(result_path)
        else:
            # create the result dir
            self.make_resultdir(result_path, 'baseline')
            config = None

        # run the workload in the baseline mode. By default baseline is supported
        if schedule and (params_list is None):
            self.report = report
            self.run_workload_schedule(cmd, report, rec_class, config)
        else:
            self.run_workload(cmd, report, rec_class, config)

        # run the workloads with different sweep parameters ranges
        if params_list:
            for param in params_list:
                for range_value in param["range"]:
                    report = path + f'/{param["param"]}_{range_value}'
                    self.make_resultdir(path, f'{param["param"]}_{range_value}')
                    self.run_workload(cmd, report, rec_class, config, result_path, param,\
                                        range_value)


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
    parser.add_argument('-o', '--output', default='profile', help='profiling output directory,\
                        uses a unique directory')
    add_hidden_arg('-O', '--outputforce', default=None, help='profiling output directory,\
                    will reuse an existing directory')
    add_hidden_arg('-s', '--sampleperiod', type=int, default=5,
                   help='Squeeze sample period in seconds')
    add_hidden_arg('--docker', default=None, help='docker container name of workload')
    add_hidden_arg('--cgpath', default='/sys/fs/cgroup', help='cgroup path')
    add_hidden_arg('--cgname', default='memoryusageanalyzer', help='cgroup name')
    add_hidden_arg('-r', '--reclaimerconfig', default=None, help='reclaimer config path')
    add_hidden_arg('-m', '--multiconfig', default=None, help='multi workload config path')
    parser.add_argument('cmdoptions', nargs='*',
                        help='workload cmd to run with options')
    args = parser.parse_args()

    print(args.cmdoptions)
    logger.info("args = %s", args)
    config_list = []
    if args.multiconfig:
        config_list = multi_config_loading(args.multiconfig)
    inst_list = []
    if config_list:
        for config in config_list:
            if "reclaimerconfig" in config:
                args.reclaimerconfig = config["reclaimerconfig"]
            else:
                args.reclaimerconfig = None
            inst = MemoryUsageAnalyzer(args.verbose,
                    config["output"],
                    args.outputforce,
                    args.sampleperiod,
                    args.docker,
                    args.cgpath,
                    config["cgroupname"],
                    args.reclaimerconfig,
                    config["cmd"])
            inst.run(schedule=True)
            inst_list.append(inst)
        for inst in inst_list:
            inst.wait()
    else:
        inst = MemoryUsageAnalyzer(args.verbose,
               args.output,
               args.outputforce,
               args.sampleperiod,
               args.docker,
               args.cgpath,
               args.cgname,
               args.reclaimerconfig,
               args.cmdoptions)
        inst.run(schedule=False)

if __name__ == "__main__":
    main()
