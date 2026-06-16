#!/usr/bin/env python3
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation
import re
from dataclasses import dataclass
from typing import List, Optional

@dataclass
class WorkQueue:
    name: str
    comp_calls: int
    comp_bytes: int
    decomp_calls: int
    decomp_bytes: int

@dataclass
class IAADevice:
    id: int
    n_wqs: int
    comp_calls: int
    comp_bytes: int
    decomp_calls: int
    decomp_bytes: int
    wqs: List[WorkQueue]

class IAAReportParser:
    def __init__(self):
        self.devices = []
    
    def parse_file(self, filename: str) -> List[IAADevice]:
        """Parse IAA device report from file."""
        try:
            with open(filename, 'r') as f:
                content = f.read()
            return self.parse_report(content)
        except FileNotFoundError:
            print(f"Error: File '{filename}' not found.")
            return []
        except Exception as e:
            print(f"Error reading file: {e}")
            return []
    
    def parse_report(self, report_text: str) -> List[IAADevice]:
        """Parse the IAA device report text."""
        self.devices = []
        sections = re.split(r'iaa device:\s*\n', report_text)
        
        for section in sections:
            if section.strip():
                device = self._parse_device_section(section.strip())
                if device:
                    self.devices.append(device)
        
        return self.devices
    
    def _parse_device_section(self, section: str) -> Optional[IAADevice]:
        """Parse a single device section."""
        lines = section.split('\n')
        device_info = {}
        wq_lines = []
        in_wqs_section = False
        
        for line in lines:
            line = line.strip()
            if not line:
                continue
                
            if line == 'wqs:':
                in_wqs_section = True
                continue
            
            if not in_wqs_section and ':' in line:
                key, value = line.split(':', 1)
                key = key.strip()
                value = value.strip()
                
                if key in ['id', 'n_wqs', 'comp_calls', 'comp_bytes', 'decomp_calls', 'decomp_bytes']:
                    try:
                        device_info[key] = int(value)
                    except ValueError:
                        device_info[key] = 0
            else:
                wq_lines.append(line)
        
        # Check required fields
        required_fields = ['id', 'n_wqs', 'comp_calls', 'comp_bytes', 'decomp_calls', 'decomp_bytes']
        if not all(field in device_info for field in required_fields):
            return None
        
        wqs = self._parse_work_queues(wq_lines)
        
        return IAADevice(
            id=device_info['id'],
            n_wqs=device_info['n_wqs'],
            comp_calls=device_info['comp_calls'],
            comp_bytes=device_info['comp_bytes'],
            decomp_calls=device_info['decomp_calls'],
            decomp_bytes=device_info['decomp_bytes'],
            wqs=wqs
        )
    
    def _parse_work_queues(self, wq_lines: List[str]) -> List[WorkQueue]:
        """Parse work queue information."""
        wqs = []
        current_wq = {}
        
        for line in wq_lines:
            if not line:
                if current_wq and 'name' in current_wq:
                    wq = self._create_work_queue(current_wq)
                    if wq:
                        wqs.append(wq)
                    current_wq = {}
                continue
            
            if ':' in line:
                key, value = line.split(':', 1)
                key = key.strip()
                value = value.strip()
                
                if key == 'name':
                    if current_wq and 'name' in current_wq:
                        wq = self._create_work_queue(current_wq)
                        if wq:
                            wqs.append(wq)
                    current_wq = {'name': value}
                elif key in ['comp_calls', 'comp_bytes', 'decomp_calls', 'decomp_bytes']:
                    try:
                        current_wq[key] = int(value) if value else 0
                    except ValueError:
                        current_wq[key] = 0
        
        # Don't forget the last WQ
        if current_wq and 'name' in current_wq:
            wq = self._create_work_queue(current_wq)
            if wq:
                wqs.append(wq)
        
        return wqs
    
    def _create_work_queue(self, wq_data: dict) -> Optional[WorkQueue]:
        """Create a WorkQueue object."""
        required_fields = ['name', 'comp_calls', 'comp_bytes', 'decomp_calls', 'decomp_bytes']
        
        for field in required_fields[1:]:
            if field not in wq_data:
                wq_data[field] = 0
        
        if 'name' not in wq_data:
            return None
        
        return WorkQueue(
            name=wq_data['name'],
            comp_calls=wq_data['comp_calls'],
            comp_bytes=wq_data['comp_bytes'],
            decomp_calls=wq_data['decomp_calls'],
            decomp_bytes=wq_data['decomp_bytes']
        )
    
    def print_columnar_format(self):
        """Print in columnar format with proper indentation."""
        # Define column widths
        iaa_width = 5
        total_comp_width = 15
        total_decomp_width = 17
        wq0_comp_width = 15
        wq0_decomp_width = 17
        wq1_comp_width = 15
        wq1_decomp_width = 17
        
        # Print header
        print(f"{'IAA':<{iaa_width}} "
              f"{'total_comp_calls':>{total_comp_width}} "
              f"{'total_decomp_calls':>{total_decomp_width}} "
              f"{'wq0_comp_calls':>{wq0_comp_width}} "
              f"{'wq0_decomp_calls':>{wq0_decomp_width}} "
              f"{'wq1_comp_calls':>{wq1_comp_width}} "
              f"{'wq1_decomp_calls':>{wq1_decomp_width}}")
        
        # Print separator line
        print("-" * (iaa_width + total_comp_width + total_decomp_width + 
                     wq0_comp_width + wq0_decomp_width + wq1_comp_width + wq1_decomp_width + 6))
        
        # Print data rows
        for device in self.devices:
            # Get WQ data (pad with 0 if not enough WQs)
            wq0_comp = device.wqs[0].comp_calls if len(device.wqs) > 0 else 0
            wq0_decomp = device.wqs[0].decomp_calls if len(device.wqs) > 0 else 0
            wq1_comp = device.wqs[1].comp_calls if len(device.wqs) > 1 else 0
            wq1_decomp = device.wqs[1].decomp_calls if len(device.wqs) > 1 else 0
            
            print(f"{device.id:<{iaa_width}} "
                  f"{device.comp_calls:>{total_comp_width},} "
                  f"{device.decomp_calls:>{total_decomp_width},} "
                  f"{wq0_comp:>{wq0_comp_width},} "
                  f"{wq0_decomp:>{wq0_decomp_width},} "
                  f"{wq1_comp:>{wq1_comp_width},} "
                  f"{wq1_decomp:>{wq1_decomp_width},}")
    
    def save_columnar_format(self, filename: str = "iaa_report.txt"):
        """Save columnar format to file."""
        try:
            with open(filename, 'w') as f:
                # Define column widths
                iaa_width = 5
                total_comp_width = 15
                total_decomp_width = 17
                wq0_comp_width = 15
                wq0_decomp_width = 17
                wq1_comp_width = 15
                wq1_decomp_width = 17
                
                # Write header
                f.write(f"{'IAA':<{iaa_width}} "
                       f"{'total_comp_calls':>{total_comp_width}} "
                       f"{'total_decomp_calls':>{total_decomp_width}} "
                       f"{'wq0_comp_calls':>{wq0_comp_width}} "
                       f"{'wq0_decomp_calls':>{wq0_decomp_width}} "
                       f"{'wq1_comp_calls':>{wq1_comp_width}} "
                       f"{'wq1_decomp_calls':>{wq1_decomp_width}}\n")
                
                # Write separator line
                f.write("-" * (iaa_width + total_comp_width + total_decomp_width + 
                              wq0_comp_width + wq0_decomp_width + wq1_comp_width + wq1_decomp_width + 6) + "\n")
                
                # Write data rows
                for device in self.devices:
                    # Get WQ data (pad with 0 if not enough WQs)
                    wq0_comp = device.wqs[0].comp_calls if len(device.wqs) > 0 else 0
                    wq0_decomp = device.wqs[0].decomp_calls if len(device.wqs) > 0 else 0
                    wq1_comp = device.wqs[1].comp_calls if len(device.wqs) > 1 else 0
                    wq1_decomp = device.wqs[1].decomp_calls if len(device.wqs) > 1 else 0
                    
                    f.write(f"{device.id:<{iaa_width}} "
                           f"{device.comp_calls:>{total_comp_width},} "
                           f"{device.decomp_calls:>{total_decomp_width},} "
                           f"{wq0_comp:>{wq0_comp_width},} "
                           f"{wq0_decomp:>{wq0_decomp_width},} "
                           f"{wq1_comp:>{wq1_comp_width},} "
                           f"{wq1_decomp:>{wq1_decomp_width},}\n")
            
            print(f"\nReport saved to: {filename}")
        except Exception as e:
            print(f"Error saving file: {e}")

def main():
    import sys
    
    # Get input filename from command line or use default
    if len(sys.argv) > 1:
        input_file = sys.argv[1]
    else:
        input_file = "iaa_data.txt"  # Default filename
    
    # Parse the file
    parser = IAAReportParser()
    devices = parser.parse_file(input_file)
    
    if not devices:
        print("No devices found or error reading file.")
        return
    
    # Print columnar format
    parser.print_columnar_format()
    
    # Save to file
    output_file = input_file.replace('.txt', '_report.txt')
    parser.save_columnar_format(output_file)

if __name__ == "__main__":
    main()
