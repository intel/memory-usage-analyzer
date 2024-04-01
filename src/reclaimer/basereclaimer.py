#!/usr/bin/python3
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""base reclaimer"""
import threading
class Reclaimer(threading.Thread):
    """Base reclaimer"""
    def __init__(self):
        threading.Thread.__init__(self)
    def config_sweep_param(self, param, range_value, path):
        """dummy config sweep method"""
        raise NotImplementedError
    def run(self):
        """dummy run method"""
        raise NotImplementedError
    def shutdown(self):
        """dummy shutdown method"""
        raise NotImplementedError
