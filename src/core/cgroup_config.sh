#!/usr/bin/env bash
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

if [ $EUID -ne 0 ]
  then echo "Must run as root or with sudo."
  exit
fi

cgpath=$1; shift
cgname=$1; shift
cguser=$1; shift

if [[ -e ${cgpath}/${cgname} ]]; then
    # remove existing cgroup v2
    until rmdir ${cgpath}/${cgname} >& /dev/null; do
        cat ${cgpath}/${cgname}/cgroup.procs | xargs kill -9 >& /dev/null
        sleep 1
    done
fi

# setup cgroup
mkdir ${cgpath}/${cgname}
echo 'if path exist'
chown ${cguser} ${cgpath}/cgroup.procs
chown -R ${cguser} ${cgpath}/${cgname}
echo 'if path exist'
# set swappiness
echo max > ${cgpath}/${cgname}/memory.swap.max
