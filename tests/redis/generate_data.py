#!/usr/bin/env python3
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Generate data to populate Redis server. Compression ratio will be an approximation
# Example:
#    python generate_data.py --output import_3x_2048v.csv  --keys 100000  --value-size 2048 --ratio 3.0

import argparse
import random
import string


def generate_value(size, ratio):
    comp_fraction = max(0.0, min(0.98, 1.0 - (1.0 / ratio)))
    comp_len = int(size * comp_fraction)
    rand_len = size - comp_len

    pattern = "user_profile_region_us_plan_premium_"
    comp = (pattern * ((comp_len // len(pattern)) + 1))[:comp_len]

    rand = "".join(random.choices(string.ascii_letters + string.digits, k=rand_len))  # nosec B311

    value = (comp + rand)[:size]

    # remove problematic characters
    value = value.replace("'", "")
    value = value.replace("\n", "")
    value = value.replace("\r", "")
    value = value.replace(",", "")

    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--keys", type=int, default=100000)
    parser.add_argument("--value-size", type=int, default=3072)
    parser.add_argument("--ratio", type=float, default=3.0)
    parser.add_argument("--seed", type=int, default=12345)

    args = parser.parse_args()

    random.seed(args.seed)

    with open(args.output, "w", newline="\n") as f:

        f.write("dumpflags, time, exptime, nbytes, nsuffix, it_flags, clsid, nkey, key, data\n")

        for i in range(1, args.keys + 1):

            key = str(i)
            value = generate_value(args.value_size, args.ratio)

            nbytes = len(value) + 4   # quotes + CRLF
            nkey = len(key)

            f.write(
                f"0, 0, 0, {nbytes}, 0, 0, 0, {nkey}, {key}, '{value}'\n"
            )

    print(f"Generated {args.keys} rows in {args.output}")


if __name__ == "__main__":
    main()

