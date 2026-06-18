#!/usr/bin/env python3
from socket_harness_common import *
from socket_harness_daemon_cases import *
from socket_harness_protocol_cases import *
from socket_harness_reconnect_cases import *
from socket_harness_runner import main

if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        import sys
        print(f"socket_harness: {exc}", file=sys.stderr)
        raise
