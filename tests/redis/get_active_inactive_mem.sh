#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
watch -n 1 "cat /sys/fs/cgroup/redisbench/memory.stat | egrep 'active_anon|inactive_anon'"
