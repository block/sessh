# Client-rendered banners

TODO

# Session-agent-rendered banners

When the connection is active, we can't render banners purely client-side
without a risk of generating scrolling artifacts. So the client asks the
session-agent to render a banner.

For each attachment, the agent keeps transient banner state:

- banner text
- start row/column
- monotonic expiry timestamp
- saved restore byte sequence for the row currently covered by the banner

When the agent needs to send a normal draw to one attachment, it does this:

1. The agent builds the normal draw bytes from the terminal model.
   These are serialized terminal instructions like cursor moves, clears, text
   writes, scrollback updates, etc. At this point the agent has also updated its
   per-attachment presentation state to what the terminal should look like after
   the normal draw.
2. If no transient banner is active, the agent just serializes the normal Draw.
3. If a transient banner is active, the agent wraps the draw bytes:
    - First, it prepends the previously saved restore bytes.
      These are serialized instructions that tell the client terminal: “put
      back the row that was underneath the previous banner.”
    - Then it appends the normal draw bytes.
    - Then, using the rendered screen after that draw, the agent clips the
      banner to the current width and computes a new restore byte sequence for
      the banner row.  This is an agent-side calculation. It does not send these
      newly computed restore bytes yet.
    - Finally, it appends overlay bytes that draw the banner on top of the
      current screen.  Again, these are serialized instructions for the client
      terminal.

So the bytes sent for an active banner look like:

```
[restore previous banner row]
[apply real draw]
[paint banner overlay]
```

Meanwhile, the agent separately updates its saved restore buffer to match what
is underneath the newly painted banner, so the next draw can begin by removing
this banner before anything scrolls or mutates the visible region.

That ordering matters because if the real draw scrolls the banner row upward,
simply repainting the banner afterward is not enough. The old banner cells
must be removed from the client terminal before the draw executes, otherwise
the draw could scroll banner text into the terminal contents.

The agent never writes the banner into the PTY model, and it never sends the
banner to other attachments. It only decorates the serialized draw stream for
the attachment that requested the transient banner.

When a new transient banner arrives while an older one is active, the agent
keeps the old restore byte sequence for exactly one more draw. That draw clears
the old overlay first, applies the real repaint, captures the new underlay, and
then paints the new banner. The old banner cannot reappear when the newer
banner expires.
