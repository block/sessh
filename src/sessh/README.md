The sessh directory owns the public `sessh` command-line shape: parsing ssh-like
argv, deciding whether a request is a terminal session or proxy stream, and
passing the resulting request to transport code.
