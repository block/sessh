# Reconnecting banner

When the connection dies, we try reconnect immediately, and then retry with
exponential backoff. While disconnected we bell on input.

When actively reconnecting we show this banner:

```
--- sessh: disconnected: Reconnecting... Ctrl-C detach ---
```

When exponentially backing off, we show this banner, counting down:

```
--- sessh: disconnected: Retry connecting 10sec. CTRL-R now. CTRL-C detach ---
```

For an unresponsive connection, reconnecting and switching are separate. We may
prepare a replacement connection in the background without showing UI, because
the current connection might recover and we do not want to show a banner
unnecessarily.

Once a replacement connection is ready, we still keep the current connection
active unless the switch is safe or the user explicitly chooses `CTRL-R`.

# Avoiding reconnection confusion

To avoid confusion, we disable/delay automatically switching connections when
it would be potentially confusing. There are 3 cases, described below:

## Avoiding reconnection confusion #1: user actively typing

If you are typing when the connection disconnects and reconnects, some of your
keystrokes may be lost. To avoid confusion, we delay switching connections for
10 seconds if there was unacknowledged input, or if we dropped input after the
connection died, and show this banner, counting down:

```
--- sessh: disconnected: Connection ready. Switch 10sec. CTRL-R now. CTRL-C detach ---
```

## Avoiding reconnection confusion #2: copy/pasting

You copy/paste a chunk of text when the connection disconnects and reconnects,
causing some of the text to be lost. To avoid confusion, we disable automatic
connection switch if paste-like input was sent to the old connection but was
not fully acknowledged before the connection disconnected or became
unresponsive.

For now, we treat input as paste-like if either:

- a single terminal read forwards at least 32 bytes, or
- at least 64 forwarded bytes arrive within a 250ms monotonic-time window.

In the future we should recognize bracketed paste, but that will require
parsing input on the client for bracketed paste delimiters.

Pastes while disconnected are discarded by sessh. That should not disable
automatic switching, because none of it can be partially delivered.

When automatic switching is disabled, we show this banner:

```
--- sessh: disconnected: Connection ready. CTRL-R switch. CTRL-C detach ---
```

## Avoiding reconnection confusion #3: unresponsive connection

If the connection is unresponsive there is a possibility it might recover on
its own. Switching connections automatically might make the user experience
worse. So when a replacement connection is ready, we continue to pump input to
the original connection while showing this banner. `CTRL-R` explicitly switches
to the replacement connection (`CTRL-R` acknowledges that prior input may have
been lost):

```
--- sessh: unresponsive: Connection ready. CTRL-R switch. CTRL-C detach ---
```
