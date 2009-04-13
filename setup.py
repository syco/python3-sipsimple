#!/usr/bin/env python

from distutils.core import setup
from distutils.extension import Extension
from distutils.command.build_scripts import build_scripts
import re
import os
import glob

from setup_pjsip import PJSIP_build_ext

version = re.search('__version__ = "([0-9.]+)"', open(os.path.join(os.path.dirname(__file__), "sipsimple", "__init__.py")).read()).group(1)

title = "SIP SIMPLE client"
description = "Python SIP SIMPLE client library using PJSIP"
scripts = [os.path.join('scripts', x) for x in os.listdir('scripts') if re.match('^sip_.*\\.py$', x) or re.match('^xcap_.*\\.py$', x)]
data_files = glob.glob(os.path.join('share/sipclient', '*.wav'))

if os.name == 'posix':
    class my_build_scripts(build_scripts):
        "remove .py extension from the scripts"

        def run (self):
            res = build_scripts.run(self)
            for script in self.scripts:
                filename = os.path.basename(script)
                if filename.endswith('.py'):
                    path = os.path.join(self.build_dir, filename)
                    print 'renaming %s -> %s' % (path, path[:-3])
                    os.rename(path, path[:-3])
else:
    my_build_scripts = build_scripts


setup(name         = "python-sipsimple",
      version      = version,
      author       = "AG Projects",
      author_email = "support@ag-projects.com",
      url          = "http://sipsimpleclient.com",
      description  = title,
      long_description = description,
      platforms    = ["Platform Independent"],
      classifiers  = [
          "Development Status :: 4 - Beta",
          #"Development Status :: 5 - Production/Stable",
          #"Development Status :: 6 - Mature",
          "Intended Audience :: Service Providers",
          "License :: GNU Lesser General Public License (LGPL)",
          "Operating System :: OS Independent",
          "Programming Language :: Python"
      ],
      packages     = ["sipsimple", "sipsimple.green", "sipsimple.clients", "sipsimple.applications", "sipsimple.configuration", "sipsimple.configuration.backend"],
      package_data = {
          'sipsimple.applications' : ['xml-schemas/*']
      },
      data_files = [('share/sipclient', data_files)],
      scripts = scripts,
      ext_modules  = [
            Extension(name = "sipsimple.core",
            sources = ["sipsimple/core.pyx", "sipsimple/core.pxd"] + glob.glob(os.path.join("sipsimple", "core.*.pxi")))
            ],
      cmdclass = { 'build_scripts' : my_build_scripts,
                   'build_ext': PJSIP_build_ext }
)
