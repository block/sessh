#!/usr/bin/env python3
from ssh_harness_common import *
from ssh_harness_transport_cases import *
from ssh_harness_diagnostics_cases import *
from ssh_harness_proxy_cases import *
from ssh_harness_terminal_cases import *
from ssh_harness_reconnect_cases import *
from ssh_harness_runner import main

if __name__ == "__main__":
    raise SystemExit(main())
