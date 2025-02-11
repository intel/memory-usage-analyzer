#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation

import argparse
import glob
from multiprocessing import Process

parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
parser.add_argument('-d', '--dir', default='.', help='input and output data directory')
parser.add_argument('-e', '--event', default='zswap_batch_compress',
                    help='zswap_compress, zswap_decompress, zswap_batch_compress, zswap_batch_decompress, or all')
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
        outfilename = "{}/{}_lat_stats.csv".format(args.dir, args.event)
        print("Outfilename: %s" % outfilename)
        infile = open(path, 'r')
        outfile = open(outfilename, 'w')
        outfile.write("name,lat\n")

        lines = infile.readlines()

        count = 0

        for line in lines:
	        sline = line.strip()
	        if sline.find(args.event) != -1:
	                sline = sline.split(' ')
	                i = 0
	                for elt in sline:
	                        if elt.find("lat=") != -1:
                                        elt = elt.split('=')
                                        outfile.write("lat{},{}\n".format(count, int(elt[1])))
                                        i += 1
                                        count = count + 1
        outfile.close()
        infile.close()


processes = []

for path in files:
        process = Process(target=processFile, args=[path])
        process.start()

for process in processes:
        process.join()
