#!/usr/bin/env python3
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025, Intel Corporation

import sys
filename = sys.argv[1]
subtest  = sys.argv[2]
nargs = len(sys.argv)

hits = 0
percentile = 98
thresh = hits * percentile / 100
print("Filename: %s" % filename)

infile = open(filename, 'r')
if nargs > 3:
        percentile = sys.argv[3]

print("Percentile: %s" % percentile)

lines = infile.readlines()

eq_0_map = {}

cur_event = ""
ret0 = False

for line in lines:
	sline = line.strip()
	if sline.find("hists:") != -1:
	   sline = sline.split(' ')
	   cur_event = sline[0]
	elif sline.find("Hits:") != -1:
	   sline = sline.split(':')
	   eq_0_map[cur_event] = int(sline[1])

infile.close()

infile = open(filename, 'r')

lines = infile.readlines()

for line in lines:
	sline = line.strip()
	if sline.find("hists:") != -1:
	   sline = sline.split(' ')
	   cur_event = sline[0]
	elif sline.find("trigger info") != -1:
	   if sline.find(f"{subtest}") != -1:
	   	hits = eq_0_map[cur_event]
	   	if hits == 0:
                        continue
	   	thresh = hits * .98
	   	print("\nhist event: %s" % cur_event)
	   	print("    event hit count: %s" % hits)
	   	print("    {} percent of hit count = {}".format(int(percentile), thresh))
	   	sum = 0
	   	printed = False
	elif sline.find('{ 'f'{subtest}') != -1:
	   print(sline)
	   sline = sline.split(':')
	   print(sline)
	   print(sline[2])
	   sys.stdout.flush()
	   sum += int(sline[2])
	   if sum >= thresh and not printed:
	   	   print("    hit threshold of %d at line:" % sum)
	   	   print("    %s" % line)
	   	   printed = True

infile.close()

