- Connection responsiveness
  - consider configurable idle ping/pong when there hasn't been any input after some time period
- thorough auditing of the code

- cursor query
  - if the app queries the cursor then we need to align the viewports first -
    even if we were willing to translate the coordinates it would be
    problematic if we aligned the viewports after we reported a cursor position to the app.
- I wonder if similar queries exist? Do we need a limited set of
  safe-to-perform-while-misaligned operations?
- if the outer terminal doesn't respond to our query we should handle it gracefully

- user alternate screen? codex says:
```
  The naive version is easy but wrong:

  - feed PTY bytes to libghostty-vt
  - notice active_screen_changed
  - emit smcup or rmcup
  - redraw whatever screen is active now

  That can mis-order output if one PTY read contains:

  main-screen updates
  smcup
  alternate-screen updates

  By the time we ask libghostty-vt for rendered state, it has already processed the whole batch, so we’ve lost the boundary where main-screen rendering needed to stop.

  The correct version would need to treat alternate-screen enter/exit as a render barrier. libghostty-vt can probably support this because our ModelTrackingHandler.vt(...) sees stream actions before delegating to
  ReadonlyHandler, so we could intercept set_mode / reset_mode for the alternate-screen modes before libghostty mutates the screen state.

  The shape would be:

  1. Before applying smcup: render and flush all pending primary-screen output.
  2. Emit outer smcup.
  3. Let libghostty-vt switch to alternate screen.
  4. Render alternate screen from scratch.
  5. Before applying rmcup: render and flush all pending alternate-screen output.
  6. Emit outer rmcup.
  7. Let libghostty-vt restore primary screen.
  8. Render primary screen from scratch.

  That is doable, but it is a real renderer architecture change. The barrier would need to be per attachment, ordered through each attachment’s output queue, and coordinated with cleanup bytes, detach/reconnect,
  resize, mouse mode, and slow clients.

  So: not impossible, but not a small libghostty-vt tweak. It’s exactly the kind of complexity we avoid by not using the outer alternate screen.
```
