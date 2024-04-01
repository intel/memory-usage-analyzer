#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""status collector module"""
import argparse
import os
import re
import signal
import subprocess
import time

STAT_PATHS = {
    'zswap': '/sys/kernel/debug/zswap',
    'vmstat': '/proc/vmstat:swap_ra',
}

IGNORE_REGEX = r'cgroup.procs|cgroup.threads|tasks|numa'
# global used to control the stat collection loop
ACTIVE = True

class BaseStats(object):
    """Empty base class used to identify classes that generate stats"""

class ZramStats(BaseStats):
    """collects the zram memory statistics"""
    def __init__(self):
        if not os.path.exists('/sys/block/zram0/mm_stat'):
            self.zram_enabled = False
        else:
            self.zram_enabled = True

    def headers(self):
        """returns the headers"""
        return 'zram_orig_data_size,zram_compr_data_size,zram_mem_used_total,zram_mem_limit,\
                zram_mem_used_max,zram_same_pages,zram_pages_compacted,zram_huge_pages'

    def values(self):
        """return values"""
        if self.zram_enabled:
            line = subprocess.run('cat /sys/block/zram0/mm_stat', shell=True, capture_output=True,
                                  check=False).stdout.decode().strip()
            values = line.split()
            if len(values) == 9:
                values.pop()
            result = ''
            for value in values:
                result += value + ','
            return result.strip(',')

        return '0,0,0,0,0,0,0,0,'

class BlkioStats(BaseStats):
    """collects the block I/O device memory statistics"""
    def __init__(self, cgpath, cgname):
        self.path = f'{cgpath}/{cgname}'

        self.device_map = {}
        devices = subprocess.run('lsblk -r | tail -n +2', shell=True, capture_output=True,
                                 check=False).stdout.decode().strip()
        for device in devices.split('\n'):
            name, number = device.split()[:2]
            self.device_map[number] = name

    def headers(self):
        """return headers"""
        return 'blkio_total_read_iops,blkio_total_write_iops,blkio_total_read_bytes,\
                blkio_total_write_bytes'

    def _total_cg2(self):
        """calculate the cgroup total read and write bytes"""
        lines = subprocess.run(f'cat {self.path}/io.stat', shell=True, capture_output=True,
                               check=False).stdout.decode().strip()
        blkio_total_read_iops = 0
        blkio_total_write_iops = 0
        blkio_total_read_bytes = 0
        blkio_total_write_bytes = 0
        for line in lines.split('\n'):
            # Example:
            # io.stat:
            # 8:16 rbytes=1576960 wbytes=16039936 rios=3 wios=36 dbytes=0 dios=0
            if line:
                if '=' not in line:
                    continue
                result = line.split()
                blkio_total_read_iops += int(result[-4].split('=')[1])
                blkio_total_write_iops += int(result[-3].split('=')[1])
                blkio_total_read_bytes += int(result[-6].split('=')[1])
                blkio_total_write_bytes += int(result[-5].split('=')[1])
        result = str(blkio_total_read_iops) + ',' + str(blkio_total_write_iops) + ',' +\
                    str(blkio_total_read_bytes) + ',' + str(blkio_total_write_bytes)
        return result

    def values(self):
        """return result"""
        result = ''
        result += self._total_cg2()
        return result

class Stats(BaseStats):
    """collects the memory statistics"""
    def __init__(self, args = None):
        self.args = args

    def get_key_value(self, line):
        """get the key value pair"""
        try:
            key, value = line.split(':', 1)
        except ValueError:
            print(f'DEBUG: Unexpected stat result = {line}')
            return None, None
        key = key.split('/')[-1]

        value = value.split()
        if 'pressure' in key:
            # We only care about 'total' field in memory.pressure:
            # memory.pressure:some avg10=0.00 avg60=0.00 avg300=0.00 total=46740229
            # memory.pressure:full avg10=0.00 avg60=0.00 avg300=0.00 total=46740110
            key += '_' + value[0] + '_' + 'total'
            value = value[4].split('=')[1]
        elif len(value) == 1:
            value = value[0]
        elif len(value) == 2:
            field, value = value
            key += '_' + field
        else:
            field = value[0]
            key += '_' + field
            value = "'" + ' '.join(value[1:]) + "'"
            m = re.search(r'total=(\d+)', value)
            if m:
                value = m.group(1)
        return key, value

    def get_stats(self, paths, headers=False):
        """get the statistics"""
        if headers:
            result = 'time,'
        else:
            result = f'{time.time()},'

        for name, path in paths.items():
            # add support for stat classes
            if isinstance(path, BaseStats):
                if headers:
                    result += path.headers() + ','
                else:
                    result += path.values() + ','
                continue

            if ':' in path:
                path, regex = path.split(':')
            else:
                regex = '.'
            lines = subprocess.run(f'sudo grep {regex} -rH {path}', shell=True,
                                   capture_output=True, check=False).stdout.decode().strip()
            for line in lines.split('\n'):
                key, value = self.get_key_value(line)
                if key is None:
                    print(f'DEBUG: {path}')
                    continue

                if re.search(IGNORE_REGEX, key):
                    continue

                if '#' in name:
                    name = name.split('#')[0]

                key = f'{name}.{key}'

                if headers:
                    # use _ instead of . for pandas
                    result += f'{key.replace(".", "_")},'
                else:
                    result += f'{value},'
        return result

    def delay_gen(self, period_sec):
        """Return delay value based on period and initial start time."""
        next_time = time.time()

        while True:
            next_time += period_sec
            yield max(next_time - time.time(), 0)

    def run(self):
        """start the statistics data collection"""
        if os.path.exists(f'{"/sys/kernel/debug/zram/total_comp_bytes_out"}'):
            STAT_PATHS['zram_debug'] = '/sys/kernel/debug/zram'

        paths = STAT_PATHS
        # cg2 needs special care because io.stat has empty content at the beginning
        paths['cgroup#0'] = f'{self.args.cgroup}/{self.args.cgname}/cpu.stat'
        paths['cgroup#1'] = f'{self.args.cgroup}/{self.args.cgname}/memory.current'
        paths['cgroup#2'] = f'{self.args.cgroup}/{self.args.cgname}/memory.events'
        paths['cgroup#3'] = f'{self.args.cgroup}/{self.args.cgname}/memory.high'
        paths['cgroup#4'] = f'{self.args.cgroup}/{self.args.cgname}/memory.low'
        paths['cgroup#5'] = f'{self.args.cgroup}/{self.args.cgname}/memory.max'
        paths['cgroup#6'] = f'{self.args.cgroup}/{self.args.cgname}/memory.min'
        paths['cgroup#7'] = f'{self.args.cgroup}/{self.args.cgname}/memory.stat'
        paths['cgroup#8'] = f'{self.args.cgroup}/{self.args.cgname}/memory.swap.current'
        paths['cgroup#9'] = f'{self.args.cgroup}/{self.args.cgname}/memory.swap.max'
        if os.path.exists(f'{self.args.cgroup}/{self.args.cgname}/memory.pressure'):
            paths['cgroup#10'] = f'{self.args.cgroup}/{self.args.cgname}/memory.pressure'

        paths['blkio'] = BlkioStats(self.args.cgroup, self.args.cgname)
        paths['zram'] = ZramStats()

        print(self.get_stats(paths, headers=True), file=self.args.output)

        delay = self.delay_gen(self.args.period)
        while ACTIVE:
            print(self.get_stats(paths), file=self.args.output)
            self.args.output.flush()
            time.sleep(next(delay))

        print(f'**** Closing {self.args.output.name}.gz')
        self.args.output.close()
        subprocess.run(f'gzip -f {self.args.output.name}', shell=True, check=False)

def main():
    """start of the app"""
    # parse args
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('-v', '--verbose', action='store_true', help='verbose output')
    parser.add_argument('-p', '--period', type=int, default=5, help='sample period in seconds')
    parser.add_argument('-c', '--cgroup', default='/sys/fs/cgroup', help='cgroup path')
    parser.add_argument('-o', '--output', type=argparse.FileType('w'), default='stats.csv',
                        help='output filename')
    parser.add_argument('--cgpath', default='/sys/fs/cgroup', help='cgroup path')
    parser.add_argument('--cgname', default='memoryusageanalyzer', help='cgroup name')
    args = parser.parse_args()

    # register SIGTERM handler to stop stat collection loop
    def shutdown(sig, stack):
        global ACTIVE
        if sig==signal.SIGTERM and stack is not None:
            ACTIVE = False

    signal.signal(signal.SIGTERM, shutdown)
    st = Stats(args)
    st.run()

if __name__ == "__main__":
    main()
