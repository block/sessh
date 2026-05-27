<!-- BEGIN sq-agents managed block (do not edit; managed by `sq agents`) -->
When sending messages on my behalf (Slack, email, PR comments, etc.), always clearly indicate the message is sent by my AI agent by prefixing with a 🤖.
<!-- END sq-agents managed block -->

## Testing

Before finishing code changes, run at least:

```sh
scripts/check --fast
```

Also run the specific tests that cover the code paths you changed. Do not run
`scripts/check --ci` unless the user asks for it. If `--ci` seems warranted,
tell the user why and ask before running it.
