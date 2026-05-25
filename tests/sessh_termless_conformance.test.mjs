import { spawnSync } from "node:child_process";
import { chmodSync, existsSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { test } from "vitest";

import {
  createTestTerminal,
  makeIsolatedEnv,
  makeTermlessTempRoot,
  REPO_ROOT,
  SESSH_BIN,
  terminalState,
  waitForTitle,
} from "./termless_support.mjs";

const MARKER_PREFIX = "sessh-termless-probe:";
const DEFAULT_PROBE_TIMEOUT_MS = 12000;
const DEFAULT_SUITE_TIMEOUT_MS = 120000;

function loadProbeCorpus() {
  // Reuse the Python harness corpus so the tmux and Termless suites do not drift.
  const exporter = `
import base64
import json
import sys

sys.path.insert(0, "tests")
import terminal_conformance_harness as harness

out = []
for probe in harness.PROBES:
    out.append({
        "name": probe.name,
        "payload": base64.b64encode(probe.payload).decode("ascii"),
        "expected_cursor": list(probe.expected_cursor) if probe.expected_cursor is not None else None,
        "expected_capture": probe.expected_capture,
        "expected_styled_capture": probe.expected_styled_capture,
        "rows": probe.rows,
        "cols": probe.cols,
    })
print(json.dumps(out))
`;

  const result = spawnSync("python3", ["-c", exporter], {
    cwd: REPO_ROOT,
    encoding: "utf8",
  });

  if (result.status !== 0) {
    throw new Error(
      [
        "failed to load tests/terminal_conformance_harness.py probe corpus",
        `exit=${result.status}`,
        `stdout:\n${result.stdout}`,
        `stderr:\n${result.stderr}`,
      ].join("\n"),
    );
  }

  return JSON.parse(result.stdout).map((probe) => ({
    ...probe,
    payload: Buffer.from(probe.payload, "base64"),
  }));
}

function selectProbes(probes) {
  let selected = probes;

  const filter = process.env.SESSH_TERMLESS_PROBE;
  if (filter) {
    const terms = filter
      .split(",")
      .map((term) => term.trim())
      .filter(Boolean);
    selected = selected.filter((probe) => terms.some((term) => probe.name.includes(term)));
  }

  const limit = Number.parseInt(process.env.SESSH_TERMLESS_PROBE_LIMIT || "", 10);
  if (Number.isFinite(limit) && limit > 0) {
    selected = selected.slice(0, limit);
  }

  return selected;
}

function writeBatchEmitter(path, probes) {
  // One sessh process handles the batch; each probe pauses on stdin after an OSC title marker.
  const payloads = probes.map((probe) => ({
    name: probe.name,
    payload: probe.payload.toString("base64"),
  }));

  writeFileSync(
    path,
    [
      "#!/usr/bin/env python3",
      "import base64",
      "import sys",
      "import time",
      "",
      `PROBES = ${JSON.stringify(payloads)}`,
      `MARKER_PREFIX = ${JSON.stringify(MARKER_PREFIX)}`,
      "",
      "for probe in PROBES:",
      '    sys.stdout.buffer.write(b"\\x1bc")',
      '    sys.stdout.buffer.write(base64.b64decode(probe["payload"]))',
      '    sys.stdout.buffer.write(b"\\x1b]2;" + MARKER_PREFIX.encode("ascii") + probe["name"].encode("ascii") + b"\\x07")',
      "    sys.stdout.buffer.flush()",
      "    if sys.stdin.buffer.readline() == b'':",
      "        break",
      "",
      "time.sleep(0.2)",
      "",
    ].join("\n"),
  );
  chmodSync(path, 0o700);
}

async function referenceState(probe) {
  const term = createTestTerminal({ cols: probe.cols, rows: probe.rows });
  try {
    term.feed(probe.payload);
    return terminalState(term, probe.rows, probe.cols);
  } finally {
    await term.close();
  }
}

function sameJson(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function firstLineDiff(expected, actual, maxDiffs = 8) {
  const expectedLines = expected.split("\n");
  const actualLines = actual.split("\n");
  const lines = ["--- direct xterm", "+++ through sessh"];
  let diffs = 0;

  for (let i = 0; i < Math.max(expectedLines.length, actualLines.length); i += 1) {
    if (expectedLines[i] === actualLines[i]) continue;
    lines.push(`@@ line ${i + 1} @@`);
    lines.push(`- ${JSON.stringify(expectedLines[i] ?? "")}`);
    lines.push(`+ ${JSON.stringify(actualLines[i] ?? "")}`);
    diffs += 1;
    if (diffs >= maxDiffs) {
      lines.push("...");
      break;
    }
  }

  return lines.join("\n");
}

function compactCell(cell) {
  const entries = Object.entries(cell).filter(([key, value]) => {
    if (value === false || value === null) return false;
    if (value === -1) return false;
    if (value === " " || value === "") return false;
    if (key.endsWith("Mode") && value === 0) return false;
    return true;
  });
  return `{ ${entries.map(([key, value]) => `${key}: ${JSON.stringify(value)}`).join(", ")} }`;
}

function firstCellDiffs(expectedRows, actualRows, maxDiffs = 8) {
  const diffs = [];
  for (let row = 0; row < Math.max(expectedRows.length, actualRows.length); row += 1) {
    const expectedLine = expectedRows[row] ?? [];
    const actualLine = actualRows[row] ?? [];
    for (let col = 0; col < Math.max(expectedLine.length, actualLine.length); col += 1) {
      const expectedCell = expectedLine[col];
      const actualCell = actualLine[col];
      if (sameJson(expectedCell, actualCell)) continue;
      diffs.push(
        `row ${row + 1}, col ${col + 1}: direct ${compactCell(expectedCell ?? {})}; sessh ${compactCell(actualCell ?? {})}`,
      );
      if (diffs.length >= maxDiffs) return diffs;
    }
  }
  return diffs;
}

function probeFailure(probe, expected, actual) {
  const sections = [`${probe.name}:`];

  if (!sameJson(expected.cursor, actual.cursor)) {
    sections.push(`cursor: direct ${JSON.stringify(expected.cursor)}; sessh ${JSON.stringify(actual.cursor)}`);
  }

  if (expected.capture !== actual.capture) {
    sections.push(`capture:\n${firstLineDiff(expected.capture, actual.capture)}`);
  }

  if (!sameJson(expected.cells, actual.cells)) {
    sections.push(`cells:\n${firstCellDiffs(expected.cells, actual.cells).join("\n")}`);
  }

  return sections.join("\n");
}

function formatFailures(failures, total) {
  const visible = failures.slice(0, 20);
  const hidden = failures.length - visible.length;
  return [
    `${failures.length}/${total} Termless terminal conformance probes failed.`,
    "",
    ...visible,
    hidden > 0 ? `\n... ${hidden} more failure(s) omitted.` : "",
  ]
    .filter(Boolean)
    .join("\n\n");
}

const probes = selectProbes(loadProbeCorpus());
const probeTimeoutMs = Number.parseInt(process.env.SESSH_TERMLESS_PROBE_TIMEOUT_MS || "", 10) || DEFAULT_PROBE_TIMEOUT_MS;
const suiteTimeoutMs = Number.parseInt(process.env.SESSH_TERMLESS_SUITE_TIMEOUT_MS || "", 10) || DEFAULT_SUITE_TIMEOUT_MS;

test(
  `sesshmux preserves terminal behavior across ${probes.length} Termless probe(s)`,
  async () => {
    if (!existsSync(SESSH_BIN)) {
      throw new Error(`missing sessh test binary: ${SESSH_BIN}; run 'zig build install-dev' first`);
    }
    if (probes.length === 0) {
      throw new Error(`no terminal conformance probes matched SESSH_TERMLESS_PROBE=${JSON.stringify(process.env.SESSH_TERMLESS_PROBE)}`);
    }

    const testRoot = makeTermlessTempRoot("sessh-termless-conformance-");
    const emitter = join(testRoot, "emit-probes.py");
    writeBatchEmitter(emitter, probes);

    let term;
    const failures = [];

    try {
      term = createTestTerminal({ cols: probes[0].cols, rows: probes[0].rows });
      await term.spawn([SESSH_BIN, "."], {
        cwd: REPO_ROOT,
        env: makeIsolatedEnv(testRoot, emitter),
      });

      for (let index = 0; index < probes.length; index += 1) {
        const probe = probes[index];
        const marker = `${MARKER_PREFIX}${probe.name}`;
        await waitForTitle(term, marker, probeTimeoutMs);

        const expected = await referenceState(probe);
        const actual = terminalState(term, probe.rows, probe.cols);

        if (!sameJson(expected.cursor, actual.cursor) || expected.capture !== actual.capture || !sameJson(expected.cells, actual.cells)) {
          failures.push(probeFailure(probe, expected, actual));
        }

        const next = probes[index + 1];
        if (next) {
          term.resize(next.cols, next.rows);
          term.type("\n");
        }
      }

      if (failures.length > 0) {
        throw new Error(formatFailures(failures, probes.length));
      }
    } finally {
      try {
        term?.type("\n");
      } catch {
        // The PTY may already be gone if sessh exited after a failure.
      }
      await term?.close();
      rmSync(testRoot, { recursive: true, force: true });
    }
  },
  suiteTimeoutMs,
);
