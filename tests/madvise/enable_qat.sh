#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2025, Intel Corporation
#Description: Configure QAT devices
rmmod qat_4xxx && rmmod intel_qat && modprobe intel_qat && modprobe qat_4xxx
