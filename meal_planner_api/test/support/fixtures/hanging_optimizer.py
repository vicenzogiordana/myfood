"""Test-only optimizer stand-in that behaves like a busy solver.

It never reads stdin and never answers, so closing the port does not stop
it: only a force-kill does.
"""

import time

while True:
    time.sleep(60)
