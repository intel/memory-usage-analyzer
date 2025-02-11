#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation

import argparse
import glob
from multiprocessing import Process

parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
parser.add_argument('-d', '--dir', default='.', help='input and output data directory')
parser.add_argument('-e', '--event', default='zswap_compress_len', help='zswap_compress_len, zswap_batch_compress_len')
args = parser.parse_args()

files = glob.glob(f'{args.dir}/*.trace')

print("Dir: %s" % args.dir)
print("Event type: %s" % args.event)

def processFile(path):
        dir_file = path.split('/')
        file = dir_file[-1]
        file = file.split('.')
        filebase = file[0]
        print("Filename: %s" % path)
        avgfilename = "{}/{}_comp_avg.csv".format(args.dir, args.event)
        print("avgfilename: %s" % avgfilename)
        sizefilename = "{}/{}_size_stats.csv".format(args.dir, args.event)
        print("sizefilename: %s" % sizefilename)
        infile = open(path, 'r')
        avgfile = open(avgfilename, 'w')
        sizefile = open(sizefilename, 'w')

        lines = infile.readlines()

        count = 0
        total_dlen = 0
        total_orig_len = 0

        print("name,size", file=sizefile)

        for line in lines:
                sline = line.strip()
                if sline.find(args.event) != -1:
                        metrics = {}
                        for word in sline.split(' '):
                                if word.find('=') != -1:
                                        key, value = word.split('=', 1)
                                        try:
                                                metrics[key] = int(value)
                                        except ValueError:
                                                metrics[key] = value

                        length = 0
                        orig_length = 0
                        try:
                                length = metrics["len"]
                        except KeyError:
                                length = 0

                        try:
                                orig_length = metrics["origlen"]
                        except KeyError:
                                orig_length = 0
                                
                        if length > 0:
                                print("len{},{}".format(count, length), file=sizefile)
                                total_dlen += length
                                if orig_length > 0:
                                        total_orig_len += orig_length
                                count += 1

        print("total_dlen: %d" % total_dlen)
        print("count: %d" % count)
        print("total_size: %d" % total_orig_len)
        ratio = 0
        try:
                ratio = (total_orig_len / total_dlen)
        except:
                pass
        print("Compression ratio = total_size / total_dlen: %f" % ratio)

        print("Compression ratio: %f" % ratio, file=avgfile)

        avgfile.close()
        sizefile.close()
        infile.close()


processes = []

for path in files:
        process = Process(target=processFile, args=[path])
        process.start()

for process in processes:
        process.join()
