import { existsSync, rmSync } from "node:fs";
import { join } from "node:path";

import { test } from "vitest";

import {
  createTestTerminal,
  makeIsolatedEnv,
  makeTermlessTempRoot,
  REPO_ROOT,
  SESSH_BIN,
  waitForText,
  waitForTitle,
  writeShellEmitter,
} from "./termless_support.mjs";

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
    await term.spawn([SESSH_BIN, "."], {
      cwd: REPO_ROOT,
      env: makeIsolatedEnv(testRoot, emitter),
    });

    await waitForText(term, "SESSH_TERMLESS_READY", 12000);
    await waitForTitle(term, "sessh-termless", 12000);
  } finally {
    await term?.close();
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
    await term.spawn([SESSH_BIN, "."], {
      cwd: REPO_ROOT,
      env: makeIsolatedEnv(testRoot, emitter),
    });

    await waitForText(term, "SESSH_TERMLESS_READY", 12000);
    await waitForTitle(term, "sessh-termless", 12000);
  } finally {
    await term?.close();
    rmSync(testRoot, { recursive: true, force: true });
  }
}, 20000);
