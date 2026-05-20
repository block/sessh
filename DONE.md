## Done

- Reconnect banners: handle single-line terminals by drawing at row 0, update second-level countdowns once retry time is under a minute, switch immediately to a reconnecting banner when retry starts or SPACE is pressed, and briefly show a reconnected banner after successful reconnect. Concern: the brief success banner intentionally adds a 500ms pause after reconnect; this is user-visible but bounded.
