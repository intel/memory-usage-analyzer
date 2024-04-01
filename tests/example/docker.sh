#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

sudo docker run --rm --name memoryusageanalyzer --cgroup-parent memoryusageanalyzer.slice -v $PWD:/memoryusageanalyzer ubuntu /memoryusageanalyzer/workload 4 30 1000
