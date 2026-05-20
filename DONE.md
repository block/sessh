## Done

- Reconnect banners: handle single-line terminals by drawing at row 0, update second-level countdowns once retry time is under a minute, switch immediately to a reconnecting banner when retry starts or SPACE is pressed, and briefly show a reconnected banner after successful reconnect. The brief success banner says it can be dismissed with SPACE or by waiting 500ms, and SPACE dismisses it immediately.
- Client logging: keep a bounded in-memory client log with timestamped entries. SSH stderr contents are buffered in memory and displayed with timestamps according to `--log-level` / `client-log-level`; no client log or SSH stderr contents are written to persistent files.
