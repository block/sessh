import { chmodSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

import { test } from "vitest";

import {
  createTestTerminal,
  makeIsolatedEnv,
  makeTermlessTempRoot,
  REPO_ROOT,
  SESSH_BIN,
  sesshmuxArgs,
  screenCells,
  waitForText,
  waitForTitle,
  writeShellEmitter,
} from "./termless_support.mjs";

function writePersistentShortShell(path) {
  writeFileSync(
    path,
    [
      "#!/bin/sh",
      "printf 'OK\\r\\nP$ '",
      "while IFS= read -r line; do",
      "  [ \"$line\" = exit ] && exit 0",
      "  printf 'P$ '",
      "done",
      "",
    ].join("\n"),
  );
  chmodSync(path, 0o700);
}

function writeSesshConfig(root, contents) {
  const configDir = join(root, "config", "sessh");
  mkdirSync(configDir, { recursive: true });
  writeFileSync(join(configDir, "sessh.env"), contents);
}

// Closing the attached client is not enough here: the local session can still
// be tearing down under the isolated runtime/state directories. Tell the test
// shell to exit, then wait for the client process to observe that exit before
// deleting the temp root.
async function exitEmitterSession(term, timeoutMs = 5000) {
  if (!term?.alive) return;
  term.type("exit\r");

  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (!term.alive) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }

  throw new Error(`sessh did not exit after test shell was told to exit; current output:\n${term.getText()}`);
}

function staleVisibleRows(rows) {
  let prefill = "";
  for (let row = 1; row <= rows; row += 1) {
    prefill += `\x1b[${row};1H\x1b[36mSTALE_TAIL_SHOULD_CLEAR_0123456789\x1b[0m`;
  }
  prefill += "\x1b[1;1H";
  return prefill;
}

test("sessh local transport renders child pty output", async () => {
  if (!existsSync(SESSH_BIN)) {
    throw new Error(`missing sessh test binary: ${SESSH_BIN}; run 'zig build install-dev' first`);
  }

  const testRoot = makeTermlessTempRoot("sessh-termless-");
  const emitter = join(testRoot, "emit.sh");
  writeShellEmitter(emitter);
  let term;

  try {
    term = createTestTerminal({ cols: 80, rows: 24 });
    await term.spawn(sesshmuxArgs("new", "."), {
      cwd: REPO_ROOT,
      env: makeIsolatedEnv(testRoot, emitter),
    });

    await waitForText(term, "SESSH_TERMLESS_READY", 12000);
    await waitForTitle(term, "sessh-termless", 12000);
    await exitEmitterSession(term);
  } finally {
    await term?.close();
    rmSync(testRoot, { recursive: true, force: true });
  }
}, 20000);

test("sessh initial-scrollback=0 attach clears stale outer row tails", async () => {
  if (!existsSync(SESSH_BIN)) {
    throw new Error(`missing sessh test binary: ${SESSH_BIN}; run 'zig build install-dev' first`);
  }

  const testRoot = makeTermlessTempRoot("sessh-termless-initial-scrollback-");
  const emitter = join(testRoot, "short-shell.sh");
  writePersistentShortShell(emitter);
  writeSesshConfig(testRoot, "initial-scrollback=0\n");
  const env = makeIsolatedEnv(testRoot, emitter);
  let starter;
  let attach;

  try {
    starter = createTestTerminal({ cols: 40, rows: 8 });
    await starter.spawn(sesshmuxArgs("new", "--alias", "stale-tail", "."), {
      cwd: REPO_ROOT,
      env,
    });
    await waitForText(starter, "OK", 12000);
    starter.type("\r~d");
    await waitForText(starter, "sessh: detached", 12000);
    await starter.close();
    starter = null;

    attach = createTestTerminal({ cols: 40, rows: 8 });
    attach.feed(staleVisibleRows(8));
    await attach.spawn(sesshmuxArgs("attach", "--host", ".", "stale-tail"), {
      cwd: REPO_ROOT,
      env,
    });
    await waitForText(attach, "OK", 12000);
    await attach.waitForStable(100, 5000);

    const rows = screenCells(attach, 8, 40);
    const okRowIndex = rows.findIndex((cells) => cells[0]?.char === "O" && cells[1]?.char === "K");
    if (okRowIndex < 0) {
      throw new Error(`could not locate OK row after attach:\n${attach.getText()}`);
    }
    const promptRowIndexes = rows
      .map((cells, index) => (cells[0]?.char === "P" && cells[1]?.char === "$" ? index : -1))
      .filter((index) => index >= 0);
    if (promptRowIndexes.length === 0) {
      throw new Error(`could not locate prompt row after attach:\n${attach.getText()}`);
    }
    for (const [rowIndex, cells] of rows.entries()) {
      const protectedColumns = rowIndex === okRowIndex || promptRowIndexes.includes(rowIndex) ? 2 : 0;
      for (const [columnIndex, cell] of cells.entries()) {
        if (columnIndex < protectedColumns) continue;
        if (cell.char === " " && cell.fgMode === 0 && cell.bgMode === 0) continue;
        throw new Error(
          `stale cell survived after attach at row ${rowIndex}, column ${columnIndex}: ${JSON.stringify(cell)}\n\nTerminal text:\n${attach.getText()}`,
        );
      }
    }
    await exitEmitterSession(attach);
  } finally {
    await starter?.close();
    await attach?.close();
    rmSync(testRoot, { recursive: true, force: true });
  }
}, 20000);

test("sessh starts when the outer terminal does not answer terminal queries", async () => {
  if (!existsSync(SESSH_BIN)) {
    throw new Error(`missing sessh test binary: ${SESSH_BIN}; run 'zig build install-dev' first`);
  }

  const testRoot = makeTermlessTempRoot("sessh-termless-no-query-");
  const emitter = join(testRoot, "emit.sh");
  writeShellEmitter(emitter);
  let term;

  try {
    term = createTestTerminal({ cols: 80, rows: 24, respondToQueries: false });
    await term.spawn(sesshmuxArgs("new", "."), {
      cwd: REPO_ROOT,
      env: makeIsolatedEnv(testRoot, emitter),
    });

    await waitForText(term, "SESSH_TERMLESS_READY", 12000);
    await waitForTitle(term, "sessh-termless", 12000);
    await exitEmitterSession(term);
  } finally {
    await term?.close();
    rmSync(testRoot, { recursive: true, force: true });
  }
}, 20000);
