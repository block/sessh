`sessh` follows the
[XDG spec](https://specifications.freedesktop.org/basedir/latest/) for file
layout:

- `XDG_CONFIG_HOME` for user-defined `sessh` config (TODO: we should support `XDG_CONFIG_DIRS` too)
- `XDG_CACHE_HOME` for bootstrapping the binary when connecting to a new host
- `XDG_STATE_HOME` for client routes
- `XDG_RUNTIME_HOME` for session data
