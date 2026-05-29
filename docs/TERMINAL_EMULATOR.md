The headless terminal emulator is implemented on top of libghostty-vt.

## Viewport misalignment

While the inner terminal is on its primary screen, we also use the
outer-terminal primary screen. This allows for a seamless experience, but it
means that our viewport might be offset from the outer terminal's viewport.

```
  outer terminal representation   inner terminal representation
+-------------------------------+-------------------------------+
|                               |                               |
|         scrollback            |                               |
|                               |                               |
|                               |          scrollback           |
+-------------------------------+                               |
|                               |                               |
|                               |                               |
|         viewport              |                               |
|                               +-------------------------------+
|                               |           viewport            |
+-------------------------------+-------------------------------+
```

This misalignment happens because when we start sessh, we want to preserve the
illusion that we're still in the same terminal (i.e. same behavior as `ssh`):
New lines should be rendered below the bottom of the screen, causing older
content to scroll out of the viewport and into scrollback.

Terminals don't provide APIs to read back from viewport/scrollback, so we can't
reconstruct the entire viewport, but we do have an escape hatch: We can emit
blank lines to cause the inner viewport to expand and fill the entire outer
viewport, aligning them.

```
       before viewport alignment      |     after viewport alignment        |
+-------------------------------------+-------------------------------------+
   outer terminal     inner terminal     outer terminal     inner terminal

                                      +------------------+------------------+
                                      |                  |                  |
+------------------+------------------+                  |                  |
|                  |                  |                  |                  |
|                  |                  |                  |                  |
|                  |                  |  pre-sessh-line  |  pre-sessh-line  |
+------------------+                  +------------------+------------------+
|  pre-sessh-line  |  pre-sessh-line  | post-sessh-line  | post-sessh-line  |
|                  +------------------+                  |                  |
| post-sessh-line  | post-sessh-line  |                  |                  |
+------------------+------------------+------------------+------------------+
```

i.e. the content is pushed upward until our viewport is the same size as the
outer terminal.

This has the side-effect of causing our content to scroll upwards. We could
remove those blank lines, but we'd still be left with our content at the top of
the viewport. So, we only align our viewports when necessary. Otherwise we wait
for content to come in normally, aligning the viewports naturally without any
side-effects. Once the viewports are aligned they stay aligned until the
session is detached.

## Window resize

When the window size changes, it can reflow the content within the synthetic
scrollback, modifying our viewport alignment. I don't think it's possible to
rediscover the new viewport alignment with confidence - the size change may
happen in the middle of our rendering. We do the safe thing: scroll the entire
outer terminal screen into scrollback (which aligns our viewports) and repaint.

## Alternate screen handling

When the inner terminal enters the alternate screen, we enter the
outer-terminal alternate screen too. That gives full-screen apps the terminal's
native behavior: primary scrollback is hidden, wheel scrolling does not browse
the primary history, and alternate-screen contents do not become primary
scrollback.

We still keep our own model of both screens. The session agent saves the
outer-primary cursor/grid state before switching buffers, draws the modeled
alternate screen in the outer alternate buffer, and sends the client a cleanup
payload that leaves the outer alternate screen and restores the modeled primary
screen on detach or session exit. A reconnecting client keeps that cleanup
payload in memory but does not apply it while it is still trying to recover the
session.

## Mouse reporting

When mouse reporting is requested, we align the viewports and redraw before
forwarding the request on to the outer terminal. That way the outer terminal
never reports an event with pre-aligned coordinates. Alternate-screen apps do
not need this alignment step because the outer alternate screen starts at the
same top-left origin as the inner alternate screen.
