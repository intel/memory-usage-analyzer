#!/bin/bash

get_cpu_ranges() {
    local proc="$1"

    pgrep -f "^$proc" | while read -r pid; do
        taskset -pc "$pid" 2>/dev/null | awk -F': ' '{print $2}'
    done |
    tr ',' '\n' |
    awk '
    {
        if ($0 ~ /-/) {
            split($0,a,"-")
            for(i=a[1]; i<=a[2]; i++) print i
        } else {
            print $0
        }
    }' |
    sort -n | uniq |
    awk '
    BEGIN { first=1 }
    {
        cpu[NR]=$1
    }
    END {
        if (NR==0) exit

        start=cpu[1]
        prev=cpu[1]

        for (i=2; i<=NR; i++) {
            if (cpu[i] != prev+1) {
                if (!first) printf ","
                if (start==prev)
                    printf "%d", start
                else
                    printf "%d-%d", start, prev
                first=0
                start=cpu[i]
            }
            prev=cpu[i]
        }

        if (!first) printf ","
        if (start==prev)
            printf "%d\n", start
        else
            printf "%d-%d\n", start, prev
    }'
}

for proc in memtier_benchmark redis-server; do
    ranges=$(get_cpu_ranges "$proc")
    if [ -n "$ranges" ]; then
        echo "$proc : $ranges"
    else
        echo "$proc : not running"
    fi
done
