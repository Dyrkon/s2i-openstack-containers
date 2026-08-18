"""TODO: remove the wa when OSPRH-36305 is solved.

urllib3 2.x dropped poolmanager._key_fields; the lockfile has urllib3 2.7.
Restore it from PoolKey._fields so tobiko.http._session can import.
"""

from urllib3 import poolmanager

if not hasattr(poolmanager, "_key_fields") and hasattr(poolmanager, "PoolKey"):
    poolmanager._key_fields = poolmanager.PoolKey._fields
