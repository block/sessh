<!-- BEGIN sq-agents managed block (do not edit; managed by `sq agents`) -->
When sending messages on my behalf (Slack, email, PR comments, etc.), always clearly indicate the message is sent by my AI agent by prefixing with a 🤖.
<!-- END sq-agents managed block -->

Follow the advice from [CONTRIBUTING.md](CONTRIBUTING.md)

## Testing

Before finishing code changes, run at least:

```sh
scripts/check --fast
```

Also run the specific tests that cover the code paths you changed. Do not run
`scripts/check` with `--ci` or `--full` unless the user asks for it. If
`--ci`/`--full` seems warranted, tell the user why and ask before running it.
If you just changed comments, don't re-run tests.

You can use test-driven development for removing old features, but don't commit
tests that simply check if old functionality is no longer there.

## Docs

Detailed documentation should live alongside the implementation in comments.
Comments should not duplicate the source code unless esoteric language
features are used. Comments should be used to:

1. Provide higher-level overviews
2. Explain why the code does what it does

Truly high-level documentation lives in the `docs` folder in `.md` files. These
files are NOT detailed specs. They should be entertaining reads of interesting
design choices and requirements. Compare the contents of these files to the
actual source code. If you notice discrepancies, determine whether the problem
is in the code or the doc and address it. Don't make additions to these docs
unless you are confident your additions fit the spirit.

Comments and docs should not dwell on the past except when it pertains to
backwards compatibility and/or lessons learned. They should describe the
current state and/or plans for the future.
