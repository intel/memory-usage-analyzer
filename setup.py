#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2023, Intel Corporation

"""python setup script"""
from setuptools import setup, find_packages
from setuptools.command.develop import develop
from setuptools.command.install import install

class PreDevelopCommand(develop):
    """Pre-installation for development mode."""
    def run(self):
        # build and install modules
        develop.run(self)

class PreInstallCommand(install):
    """Pre-installation for installation mode."""
    def run(self):
        # build and install modules
        install.run(self)

setup(
    name='memoryusageanalyzer',
    version='1.0',
    description='Memory compression profiling tool.',
    author='Pallavi G, Ravindran Binuraj',
    author_email='pallavi.g@intel.com, binuraj.ravindran@intel.com',
    # Fixing the bokeh version as newer versions like 3.0 shrink the plots
    install_requires=['pandas', 'bokeh==2.4.3', 'shapely', 'matplotlib','pytest', 'xlsxwriter',\
                      'numpy', 'colorcet', 'scipy', 'jsonschema'],
    packages=find_packages(),
    scripts=['src/core/memory-usage-analyzer.py',
             'src/core/stats.py',
             'src/analyzer/plot.py',
             'src/analyzer/analyze.py',
             'tests/config_script/config.py',
             'tests/config_script/config.sh',
             'tests/config_script/report.sh',
             'tests/config_script/zswapcompconfig.py'
         ],
    cmdclass={
        'install': PreInstallCommand,
        'develop': PreDevelopCommand,
    },
)
