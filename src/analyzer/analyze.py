#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""statistics analyzer"""
import argparse
import subprocess

from src.core.util import cold_hot_total, max_memory_usage, read_stats_df,\
    compression_ratio, calculate_savings

def get_total_pf_count(df, counter, t_sample):
    """get the total paga fault"""
    # Get total page fault (Major+Minor)
    pf_rate_med = df[counter].diff().median() / t_sample
    pf_rate_max = df[counter].diff().max() / t_sample
    pf_rate_avg = df[counter].diff().mean() / t_sample
    total_pf = int(df[counter].max() - df[counter].min())
    print(f'Total PFs/sec (median, avg, max) = {pf_rate_med:.2f} {pf_rate_avg:.2f}\
          {pf_rate_max:.2f}')
    return total_pf

class Analyzer():
    """ Analyzes the statistics dumped in the file and creates the html report """
    def __init__(self,
                 resultpath='./stats.csv.gz'):
        self.resultpath = resultpath

    def memoryanalysis(self , df):
        """memory analysis"""
        print(f'Loading stats from {self.resultpath}/stats.csv.gz')
        df = read_stats_df(f'{self.resultpath}/stats.csv.gz')

        if 'cgroup_memory_current' in df.columns:
            inactive_anon = df.cgroup_memory_stat_inactive_anon.max() / (1 << 30)
        else:
            inactive_anon = df.cgroup_memory_stat_total_inactive_anon.max() / (1 << 30)

        zpool_size = df.zswap_pool_total_size.max() / (1 << 30)
        max_zram_used = df.zram_mem_used_total.max() / (1 << 30)
        incompressible_data_ratio = (df.zram_huge_pages * 4096 / df.zram_orig_data_size).max()

        max_memory_with_cache = max_memory_usage(df, True, False)
        full_total_memory_pressure = 0
        # This seems to be available only in some kernels.
        if 'cgroup_memory_pressure_full_total' in df.columns:
            full_total_memory_pressure = df.cgroup_memory_pressure_full_total.max() -\
                df.cgroup_memory_pressure_full_total.min()

        cold, hot, page_cache, total = cold_hot_total(df)
        ratio, ratio_with_same_filled = compression_ratio(df)
        potential_memory_savings_bytes, potential_maximum_memory_savings_percent,\
            potential_median_memory_savings_percent = calculate_savings(df)
        print("*** Totals without page cache ***")
        print(f'Maximum active+swap memory           = {max_memory_with_cache:.3f} GiB')
        print(f'Max active memory                 = {hot:.1f} GiB')
        print(f'Max swap memory                = {cold:.1f} GiB')
        print(f'Max page cache                 = {page_cache:.3f} GiB')
        print(f'Swap memory                    = {100 * cold / total:.1f}%')
        print(f'Max inactive anon              = {inactive_anon:.3f} GiB')
        print(f'Maximum zpool memory           = {zpool_size:3f} GiB')
        print(f'Maximum zram memory            = {max_zram_used:3f} GiB')
        print(f'incompressible data ratio(zram)= {100 * incompressible_data_ratio:.1f}%')

        try:
            print(f'full total memory pressure            = {full_total_memory_pressure} us')
        except ImportError:
            print("full total memory pressure            = None")

        if ratio > 1.001:
            print(f'Average swap memory comp ratio = {ratio:.2f}')
            print(f'Potential maximum compression savings in percent =\
                  {potential_maximum_memory_savings_percent:.1f}%')
            print(f'Potential median compression savings in percent =\
                  {potential_median_memory_savings_percent:.1f}%')
            print(f'Potential compression savings in bytes =\
                  {potential_memory_savings_bytes:.3f} GiB')

        if ratio_with_same_filled > 1.001:
            print(f'Average swap memory comp ratio = {ratio_with_same_filled:.2f}\
                  (including same filled pages)')

    def run(self):
        """Analyzer run method"""
        print(f'Loading stats from {self.resultpath}/stats.csv.gz')
        df = read_stats_df(f'{self.resultpath}/stats.csv.gz')
        self.memoryanalysis(df)
        t_sample = df.time.diff().mean()

        # Get Major page fault
        pf_rate_med = df.cgroup_memory_stat_pgmajfault.diff().median() / t_sample
        pf_rate_max = df.cgroup_memory_stat_pgmajfault.diff().max() / t_sample
        pf_rate_avg = df.cgroup_memory_stat_pgmajfault.diff().mean() / t_sample
        major_total_pf = int(df.cgroup_memory_stat_pgmajfault.max() -\
                             df.cgroup_memory_stat_pgmajfault.min())
        print(f'Major PFs/sec (median, avg, max) = {pf_rate_med:.2f} {pf_rate_avg:.2f}\
              {pf_rate_max:.2f}')

        total_pf = get_total_pf_count(df, 'cgroup_memory_stat_pgfault', t_sample)
        if 'cgroup_memory_stat_total_pgfault' in df.columns:
            total_pf = get_total_pf_count(df, 'cgroup_memory_stat_total_pgfault', t_sample)

        print(f'Total PFs (Major+Minor) = {total_pf}')
        print(f'Major PFs = {major_total_pf}')

        if "zswap_total_cpu_comp_calls" in df.columns:
            total_cpu_comp_calls = df.zswap_total_cpu_comp_calls.max() -\
                df.zswap_total_cpu_comp_calls.min()
            print(f'total_cpu_comp_calls = {total_cpu_comp_calls:.2f}')
        if "zswap_total_cpu_decomp_calls" in df.columns:
            total_cpu_decomp_calls = df.zswap_total_cpu_decomp_calls.max() -\
                df.zswap_total_cpu_decomp_calls.min()
            print(f'total_cpu_decomp_calls = {total_cpu_decomp_calls:.2f}')

        if 'zswap_primary_compressions' in df.columns:
            total_zswap_primary_compressions_calls = df.zswap_primary_compressions.max() -\
                df.zswap_primary_compressions.min()
            total_zswap_secondary_compressions_calls = df.zswap_secondary_compressions.max() -\
                df.zswap_secondary_compressions.min()
            total_zswap_primary_decompressions_calls = df.zswap_primary_decompressions.max() -\
                df.zswap_primary_decompressions.min()
            total_zswap_secondary_decompressions_calls = df.zswap_secondary_decompressions.max() -\
                df.zswap_secondary_decompressions.min()
            print(f'total zswap primary compressions calls =\
                  {total_zswap_primary_compressions_calls}')
            print(f'total zswap secondary compressions calls =\
                  {total_zswap_secondary_compressions_calls}')
            print(f'total zswap primary decompressions calls =\
                  {total_zswap_primary_decompressions_calls}')
            print(f'total zswap secondary decompressions calls =\
                  {total_zswap_secondary_decompressions_calls}')

        if 'zswap_compressions' in df.columns:
            total_zswap_compressions_calls = df.zswap_compressions.max() -\
                df.zswap_compressions.min()
            total_zswap_decompressions_calls = df.zswap_decompressions.max() -\
                df.zswap_decompressions.min()
            print(f'total zswap compressions calls = {total_zswap_compressions_calls}')
            print(f'total zswap decompressions calls = {total_zswap_decompressions_calls}')
        print(f'sampling period = {t_sample}')
        subprocess.run(f'plot.py -statfile {self.resultpath}/stats.csv.gz -respath\
                       {self.resultpath}', shell=True, check=False)

def main():
    """entry point"""
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('resultpath', nargs='?', default='.',\
        help='memoryusageanalyzer stats file path')
    args = parser.parse_args()
    al = Analyzer(args.resultpath)
    al.run()

if __name__ == "__main__":
    main()
