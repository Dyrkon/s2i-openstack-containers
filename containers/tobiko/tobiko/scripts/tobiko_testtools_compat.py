"""TODO: remove the wa when OSPRH-36305 is solved.

testtools 2.8 dropped TestCase.skip(); the lockfile has testtools 2.9.
"""

import unittest

if not hasattr(unittest.TestCase, "skip"):
    unittest.TestCase.skip = unittest.TestCase.skipTest
