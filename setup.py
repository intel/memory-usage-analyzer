#!/usr/bin/python
#SPDX-License-Identifier: BSD-3-Clause
#Copyright (c) 2026, Intel Corporation

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

    python_requires='>=3.10',  # raised from 3.7: pillow>=12.x (CVE-2026-25990/40192/42308/09/10/11 fixes) requires Python >=3.10
    # Security note: bokeh 3.x changes plot sizing defaults vs 2.x — review plot output after upgrade.
    # Remaining CVE fix versions (bokeh 3.8.2, pytest 9.0.3, pillow 12.2.0, requests 2.33.0, urllib3 2.7.0)
    # are not yet published to PyPI as of 2026-05-21; pinned to best currently available versions.
    install_requires=[
        'pandas',
        'bokeh>=3.4.3',          # was ==2.4.3; 3.4.3 is best available (CVE-2026-21883 full fix needs 3.8.2, not yet on PyPI)
        'shapely',
        'matplotlib',
        'pytest>=8.4.2',         # best available; CVE-2025-71176 full fix needs 9.0.3, not yet on PyPI
        'xlsxwriter',
        'numpy>=1.26.4',         # was ==1.26.4; relaxed pin
        'colorcet',
        'scipy',
        'jsonschema',
        'requests>=2.32.5',      # best available; fixes CVE-2023-32681, CVE-2024-35195, CVE-2024-47081 (CVE-2026-25645 needs 2.33.0, not yet on PyPI)
        # transitive dependency minimum versions required for security
        'urllib3>=2.6.3',        # best available; fixes CVE-2023-43804, CVE-2025-66418/66471, CVE-2026-21441, CVE-2025-50181 (CVE-2026-44431 needs 2.7.0, not yet on PyPI)
        'cryptography>=46.0.6',  # fixes CVE-2023-0286/23931/49083/50782, CVE-2024-0727, CVE-2026-26007/34073, GHSA-5cpq/jm77/v8gr
        'idna>=3.15',            # fixes CVE-2024-3651, CVE-2026-45409
        'pillow>=11.3.0',        # best available; CVE-2026-25990/40192/42308-42311 full fixes need 12.2.0, not yet on PyPI
        'lxml>=6.1.0',           # fixes CVE-2022-2309, CVE-2026-41066
    ],
    packages=find_packages(),
    scripts=['src/core/memory_usage_analyzer.py',
             'tests/example/multi_config.py',
             'src/core/stats.py',
             'src/analyzer/plot.py',
             'src/analyzer/analyze.py',
             'tests/config_script/config.py',
             'tests/config_script/config.sh',
             'tests/config_script/configure_iaa.sh',
             'tests/config_script/disable_iaa.sh',
             'tests/config_script/report.sh',
             'tests/config_script/zswapcompconfig.py'
         ],
    cmdclass={
        'install': PreInstallCommand,
        'develop': PreDevelopCommand,
    },
)
