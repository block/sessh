The headless terminal emulator is implemented on top of libghostty-vt.

## Viewport misalignment

Unlike tmux/screen, we don't use the alternate screen (aka `smcup`/`rmcup`).
This allows for a seamless experience, but it means that our viewport might be
offset from the outer terminals viewport.

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

## Alternate screen handling

We don't use the outer-terminal's alternate screen, even when the
inner-terminal enters the alternate screen. Instead we let libghostty-vt tell
us how to render the current viewport, without concerning ourselves with
whether or not we're in the alternate screen. The only special handling we do
is aligning our viewports prior to entering the alternate screen. This is
necessary because otherwise the synthetic scrollback (the section of inner
terminal scrollback that is in the outer terminal's viewport) would be lost
when we render the alternate screen.

Perhaps it would be possible to avoid forced alignment by leveraging the outer
terminal's alternate screen.

## Mouse reporting

When mouse reporting is requested, we align the viewports and redraw before
forwarding the request on to the outer terminal. That way the outer terminal
never reports an event with pre-aligned coordinates.
