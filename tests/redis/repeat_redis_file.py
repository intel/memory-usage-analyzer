#!/usr/bin/env python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

# Script to create key-value entries from a .redis file, replace HSET with SET, and add data size plotting
# and optional CSV export for memtier_benchmark.

import argparse
import multiprocessing
import matplotlib.pyplot as plt
import pandas as pd
import re
import unicodedata
import os
import requests
import sys

def download_default_dataset(output_file="import_movies.redis"):
    """
    Download the default Redis movie dataset from GitHub.
    
    Args:
        output_file (str): Local filename to save the downloaded data
        
    Returns:
        str: Path to the downloaded file
        
    Raises:
        Exception: If download fails
    """
    raw_data_url = "https://raw.githubusercontent.com/redis-developer/redis-datasets/master/movie-database/import_movies.redis"
    
    print(f"Downloading default dataset from GitHub...")
    print(f"URL: {raw_data_url}")
    print(f"Output file: {output_file}")
    
    try:
        response = requests.get(raw_data_url, timeout=30)
        response.raise_for_status()  # Raise an exception for bad status codes
        
        with open(output_file, 'w', encoding='utf-8') as f:
            f.write(response.text)
            
        file_size = os.path.getsize(output_file)
        print(f"✓ Dataset downloaded successfully: {file_size:,} bytes")
        return output_file
        
    except requests.exceptions.RequestException as e:
        raise Exception(f"Failed to download dataset: {e}")
    except IOError as e:
        raise Exception(f"Failed to save dataset file: {e}")

def combine_lines(lines, combined_lines):
    """Combine specified number of lines into a single string."""
    combined = []
    count = 0
    line_count = 1
    combined_line = ""
    for line in lines:
        combined_line += line
        if (line_count % combined_lines) == 0:
            combined.append(combined_line)
            combined_line = ""
        line_count += 1
    return combined

def map_parallel(func, values):
    """Use pool of processes to run func in parallel and return the results."""
    with multiprocessing.Pool() as pool:
        return pool.map(func, values)

def format_redis_entry(data):
    """Format a Redis entry using SET with a unique key."""
    key, line = data
    #escaped_line = line.replace("'", "\\'")
    escaped_line = clean_sentence(line)
    escaped_line = unicodedata.normalize("NFKD", escaped_line).encode("ascii", "ignore").decode()
    return f"SET {key} '{escaped_line}'", len(escaped_line)

def create_redis_entries(combined_lines_list, reps):
    """Create Redis entries with parallel processing and repeat as specified."""
    entries_to_format = []
    key_id = 1
    for _ in range(reps):
        for combined_line in combined_lines_list:
            entries_to_format.append((key_id, combined_line))
            key_id += 1

    # Use map_parallel to process formatting in parallel
    formatted_entries = map_parallel(format_redis_entry, entries_to_format)

    # Separate entries and sizes into individual lists
    repeated_lines = [entry for entry, size in formatted_entries]
    datasize_list = [size for entry, size in formatted_entries]

    return repeated_lines, datasize_list, entries_to_format


def clean_sentence(text):
    """
    Clean and format text as a sentence for the data column.
    - Remove unwanted characters (quotes, newlines, tabs).
    - Normalize spacing.
    - Capitalize first letter.
    - Ensure it ends with a period (if not already ending with .!?).
    """
    # Remove unwanted characters
    text = text.replace('"', '').replace("'", '')
    text = text.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ')
    text = text.replace(',', ' ')  # Avoid commas to prevent CSV issues

    # Normalize spacing
    text = re.sub(r'\s+', ' ', text).strip()

    # Handle empty text
    if not text:
        text = "Empty"

    # Capitalize first letter
    text = text[0].upper() + text[1:]

    # Ensure it ends with a period if it's a sentence
    if text and text[-1] not in '.!?':
        text += '.'

    return text

def write_csv_for_memtier(entries_to_format, output_csv_file):
    """
    Writes memtier_benchmark-compatible CSV file manually.

    Format expected by C++ file_reader::read_item:
    dumpflags, time, exptime, nbytes, nsuffix, it_flags, clsid, nkey, key, data\n

    Matches C++ parser:
    - nbytes = len(data) + 2 (for \r\n appended in read_item).
    - nkey = len(key_str).
    - No quotes around key or data (read_string handles unquoted strings).
    - Spaces after commas in header and data rows for consistency with open_file check.
    """
    #hset_pattern = re.compile(r'HSET\s+"?movie:\d+"?', re.IGNORECASE)

    with open(output_csv_file, "w", newline="\n") as fout:
        # Write CSV header with spaces after commas to match open_file check
        fout.write("dumpflags, time, exptime, nbytes, nsuffix, it_flags, clsid, nkey, key, data\n")

        for key, raw_data in entries_to_format:
            key_str = str(key)  # e.g., "1", "2", etc.

            # Remove HSET patterns
            #cleaned_data = hset_pattern.sub('', raw_data)
            cleaned_data =  raw_data

            # Apply clean_sentence to format as a sentence
            cleaned_data = clean_sentence(cleaned_data)
            """
            Specific Risks in Your data Field:
            Unicode characters like é in "Léon" (some parsers expect ASCII).
            Colons (:) might be misinterpreted by naive scanners.
            Long data values that might get truncated depending on buffer size in C++.
            Spaces in image URLs like
            
            Problem	: Fix
            Unicode characters (é):	Use unicodedata.normalize(...) to strip accents
            Colons (:):	Remove or replace with space
            Long or broken URLs: Optionally strip or truncate
            Extra numeric chunks in URLs: Remove _CR0 0 182 ... via regex
            """

            cleaned_data = unicodedata.normalize("NFKD", cleaned_data).encode("ascii", "ignore").decode()

            # # Calculate lengths
            nkey = len(key_str)  # Exact length of key (e.g., 1 for "1", 2 for "10")
            nbytes = len(cleaned_data) + 4  # Data length + 2 for \r\n appended by C++

            # No quotes, as read_string can handle unquoted strings
            escaped_key = key_str
            #import unicodedata
            #cleaned_data = unicodedata.normalize("NFKD", cleaned_data).encode("ascii", "ignore").decode()
            escaped_data = f"'{cleaned_data}'"

            # Calculate lengths
            #nkey = len(key_str)  # Exact length of key (e.g., 1 for "1", 2 for "10")
            #nbytes = len(cleaned_data) + 4  # Data length + 2 for \r\n appended by C++

            # Write row with spaces after commas to match header style
            row = f"0, 0, 0, {nbytes}, 0, 0, 0, {nkey}, {escaped_key}, {escaped_data}\n"
            fout.write(row)
        fout.write("\n")

def plot_data_distribution(datasize_list, output_image):
    """Plot and save the data distribution of entry sizes."""
    plt.hist(datasize_list, bins=20)
    plt.xlabel('Datasize (Bytes)')
    plt.ylabel('Frequency')
    plt.title("Data Size Distribution")
    plt.savefig(output_image)
    plt.close()

def print_dataset_statistics(datasize_list):
    """Print statistics about the generated Redis dataset."""
    import numpy as np
    
    num_keys = len(datasize_list)
    avg_size = np.mean(datasize_list)
    std_size = np.std(datasize_list)
    min_size = np.min(datasize_list)
    max_size = np.max(datasize_list)
    
    print("\n" + "="*50)
    print("REDIS DATASET STATISTICS")
    print("="*50)
    print(f"Number of Keys:        {num_keys:,}")
    print(f"Average Value Size:    {avg_size:.2f} bytes")
    print(f"Std Dev Value Size:    {std_size:.2f} bytes")
    print(f"Min Value Size:        {min_size} bytes")
    print(f"Max Value Size:        {max_size} bytes")
    print("="*50)

def create_dataset_description(input_file, output_file, reps, combined_lines, datasize_list, output_desc_file):
    """Create a detailed text file with dataset description and statistics."""
    import numpy as np
    import os
    from datetime import datetime
    
    num_keys = len(datasize_list)
    avg_size = np.mean(datasize_list)
    std_size = np.std(datasize_list)
    min_size = np.min(datasize_list)
    max_size = np.max(datasize_list)
    total_size = np.sum(datasize_list)
    
    # Get file sizes
    input_file_size = os.path.getsize(input_file) if os.path.exists(input_file) else 0
    output_file_size = os.path.getsize(output_file) if os.path.exists(output_file) else 0
    
    # Count original lines in input file
    with open(input_file) as f:
        original_lines = sum(1 for line in f)
    
    # Calculate derived metrics
    combined_entries = original_lines // combined_lines if combined_lines > 0 else 0
    compression_ratio = output_file_size / input_file_size if input_file_size > 0 else 0
    
    description = f"""Redis Dataset Description and Statistics
================================================================

DATASET GENERATION DETAILS
================================================================
Generation Date:       {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}
Script Version:        Redis Dataset Generator v1.0
Input File:            {input_file}
Output File:           {output_file}

INPUT PARAMETERS
================================================================
Number of Repetitions:    {reps:,}
Combined Lines:            {combined_lines}
Original Input Lines:      {original_lines:,}
Combined Entries Created:  {combined_entries:,}

DATASET STATISTICS
================================================================
Total Number of Keys:      {num_keys:,}
Average Value Size:        {avg_size:.2f} bytes
Standard Deviation:        {std_size:.2f} bytes
Minimum Value Size:        {min_size} bytes
Maximum Value Size:        {max_size} bytes
Total Dataset Size:        {total_size:,} bytes ({total_size / (1024*1024):.2f} MB)

FILE SIZE INFORMATION
================================================================
Input File Size:           {input_file_size:,} bytes ({input_file_size / 1024:.2f} KB)
Output File Size:          {output_file_size:,} bytes ({output_file_size / (1024*1024):.2f} MB)
Size Expansion Ratio:      {compression_ratio:.2f}x

DATA PROCESSING DETAILS
================================================================
Data Cleaning Applied:     Yes (Unicode normalization, special character removal)
Key Format:                Sequential integers (1, 2, 3, ...)
Value Format:              SET commands with single-quoted values
Parallel Processing:       Yes (multiprocessing.Pool)

DATASET STRUCTURE
================================================================
Key Range:                 1 to {num_keys:,}
Command Format:            SET <key> '<cleaned_value>'
Character Encoding:        ASCII (normalized from Unicode)
Line Endings:              Unix (LF)

STATISTICAL SUMMARY
================================================================
Data Distribution:         {std_size/avg_size:.3f} (coefficient of variation)
Size Consistency:          {'High' if std_size/avg_size < 0.3 else 'Medium' if std_size/avg_size < 0.7 else 'Low'}
Memory Footprint:          {total_size / (1024*1024*1024):.3f} GB (estimated)

CALCULATION METHODOLOGY
================================================================
Statistical Calculations:
- Average Value Size:       np.mean(datasize_list)
- Standard Deviation:       np.std(datasize_list)
- Minimum Value Size:       np.min(datasize_list)
- Maximum Value Size:       np.max(datasize_list)
- Total Dataset Size:       np.sum(datasize_list)
- Coefficient of Variation: std_dev / mean (measures relative variability)

Size Calculations:
- Memory Footprint:         total_size / (1024^3) GB (estimated Redis memory usage)
- File Size Expansion:      output_file_size / input_file_size
- Combined Entries:         original_lines // combined_lines (integer division)

Size Consistency Categories:
- High:   Coefficient of Variation < 0.3 (low variability)
- Medium: Coefficient of Variation 0.3-0.7 (moderate variability)  
- Low:    Coefficient of Variation > 0.7 (high variability)

Data Processing Pipeline:
1. Read input file lines and strip whitespace
2. Combine multiple lines based on combined_lines parameter
3. Repeat combined entries reps times with sequential keys
4. Apply clean_sentence() for data sanitization:
   - Remove quotes, newlines, tabs, commas
   - Normalize whitespace with regex
   - Capitalize first letter and add period if needed
5. Apply Unicode normalization (NFKD) and ASCII encoding
6. Calculate byte length of processed values
7. Generate SET commands with sequential integer keys

USAGE NOTES
================================================================
- This dataset is optimized for Redis benchmarking with memtier_benchmark
- All values have been sanitized to ensure compatibility with Redis
- Unicode characters have been normalized to ASCII
- Sequential keys enable predictable access patterns
- Dataset can be loaded using Redis CLI or custom tools
- Memory footprint is estimated based on value sizes only (excludes Redis overhead)
- Actual Redis memory usage will be higher due to key storage and internal structures

================================================================
End of Dataset Description
================================================================
"""

    with open(output_desc_file, 'w') as f:
        f.write(description)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description='Load database with data',
                                     formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument('-r', '--reps', type=int, default=1, 
                        help='Number of times the dataset will be repeatedly written to the Redis database.')
    parser.add_argument('-c', '--combined_lines', type=int, default=1, 
                        help='Number of lines to combine to achieve a certain value size.')
    parser.add_argument('-i', '--input_file', help='Input data file (default: download import_movies.redis from GitHub)')
    parser.add_argument('-o', '--output_file', help='Output data .redis file (auto-generated if not provided)')
    parser.add_argument('-x', '--output_csv_file', help='Output data .csv file for memtier-benchmark import (auto-generated if not provided)')
    parser.add_argument('--output_image', help='Output image file for data size histogram (auto-generated if not provided)')
    parser.add_argument('--dataset_description', action='store_true', default=True,
                        help='Generate dataset description text file (default: True)')
    parser.add_argument('--output_desc_file', help='Output text file for dataset description (auto-generated if not provided)')
    args = parser.parse_args()

    # Handle input file - download default dataset if not provided
    if not args.input_file:
        default_file = "import_movies.redis"
        if os.path.exists(default_file):
            print(f"Using existing default dataset: {default_file}")
            args.input_file = default_file
        else:
            try:
                args.input_file = download_default_dataset(default_file)
            except Exception as e:
                print(f"Error downloading default dataset: {e}")
                print("Please provide an input file using -i/--input_file argument.")
                sys.exit(1)
    elif not os.path.exists(args.input_file):
        print(f"Error: Input file '{args.input_file}' does not exist.")
        sys.exit(1)

    # Auto-generate filenames if not provided
    if not args.output_file:
        input_basename = os.path.splitext(os.path.basename(args.input_file))[0]
        base_name = f"{input_basename}_{args.reps}r_{args.combined_lines}c"
        args.output_file = f"{base_name}.redis"
    else:
        # Use provided output_file as base for other files
        base_name = os.path.splitext(args.output_file)[0]
        
    # Auto-generate other filenames based on the base_name
    if not args.output_csv_file and args.output_csv_file is not False:
        args.output_csv_file = f"{base_name}.csv"
    
    if not args.output_image:
        args.output_image = f"{base_name}_datasize_distribution.png"
        
    if not args.output_desc_file:
        args.output_desc_file = f"{base_name}_dataset_description.txt"

    # Read lines from input file
    with open(args.input_file) as fin:
        lines = [line.strip() for line in fin]

    # Combine lines and create Redis entries
    combined_lines_list = combine_lines(lines, args.combined_lines)
    repeated_lines, datasize_list, entries_to_format = create_redis_entries(combined_lines_list, args.reps)

    # Write Redis entries to the output file
    with open(args.output_file, "w") as fout:
        fout.write("\n".join(repeated_lines))

    # Write to CSV file for memtier_benchmark if specified
    if args.output_csv_file:
        write_csv_for_memtier(entries_to_format, args.output_csv_file)

    # Plot and save data distribution
    plot_data_distribution(datasize_list, args.output_image)

    # Print dataset statistics
    print_dataset_statistics(datasize_list)

    # Create dataset description file if requested
    if args.dataset_description:
        create_dataset_description(args.input_file, args.output_file, args.reps, args.combined_lines, datasize_list, args.output_desc_file)



