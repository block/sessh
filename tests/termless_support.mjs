import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

import { createTerminal, encodeKeyToAnsi } from "@termless/core";
import xterm from "@xterm/headless";

const { Terminal: XtermTerminal } = xterm;

export const REPO_ROOT = resolve(import.meta.dirname, "..");
export const SESSH_BIN = process.env.SESSH_BIN || join(REPO_ROOT, "zig-out", "bin", "sesshmux-dev");

const COLOR_MODE_DEFAULT = 0;
const COLOR_MODE_PALETTE = 0x01000000;
const COLOR_MODE_PALETTE_BRIGHT = 0x02000000;
const COLOR_MODE_RGB = 0x03000000;

const ANSI_16 = [
  [0, 0, 0],
  [205, 0, 0],
  [0, 205, 0],
  [205, 205, 0],
  [0, 0, 238],
  [205, 0, 205],
  [0, 205, 205],
  [229, 229, 229],
  [127, 127, 127],
  [255, 0, 0],
  [0, 255, 0],
  [255, 255, 0],
  [92, 92, 255],
  [255, 0, 255],
  [0, 255, 255],
  [255, 255, 255],
];

function paletteColor(index) {
  if (index < 0) return null;
  if (index < ANSI_16.length) {
    const [r, g, b] = ANSI_16[index];
    return { r, g, b };
  }
  if (index >= 16 && index <= 231) {
    const n = index - 16;
    const levels = [0, 95, 135, 175, 215, 255];
    return {
      r: levels[Math.floor(n / 36) % 6],
      g: levels[Math.floor(n / 6) % 6],
      b: levels[n % 6],
    };
  }
  if (index >= 232 && index <= 255) {
    const level = 8 + (index - 232) * 10;
    return { r: level, g: level, b: level };
  }
  return null;
}

function rgbColor(value) {
  if (value < 0) return null;
  return {
    r: (value >>> 16) & 0xff,
    g: (value >>> 8) & 0xff,
    b: value & 0xff,
  };
}

function color(mode, value) {
  switch (mode) {
    case COLOR_MODE_PALETTE:
    case COLOR_MODE_PALETTE_BRIGHT:
      return paletteColor(value);
    case COLOR_MODE_RGB:
      return rgbColor(value);
    case COLOR_MODE_DEFAULT:
    default:
      return null;
  }
}

function underlineStyle(style) {
  switch (style) {
    case 1:
      return "single";
    case 2:
      return "double";
    case 3:
      return "curly";
    case 4:
      return "dotted";
    case 5:
      return "dashed";
    case 0:
    default:
      return false;
  }
}

function blankCell() {
  return {
    char: " ",
    fg: null,
    bg: null,
    bold: false,
    dim: false,
    italic: false,
    underline: false,
    underlineColor: null,
    strikethrough: false,
    inverse: false,
    blink: false,
    hidden: false,
    wide: false,
    continuation: false,
    hyperlink: null,
    fgMode: COLOR_MODE_DEFAULT,
    fgColor: -1,
    bgMode: COLOR_MODE_DEFAULT,
    bgColor: -1,
    underlineColorMode: COLOR_MODE_DEFAULT,
    underlineColorValue: -1,
    overline: false,
  };
}

function cellFromXterm(cell) {
  if (!cell) return blankCell();

  const fgMode = cell.getFgColorMode();
  const fgColor = cell.getFgColor();
  const bgMode = cell.getBgColorMode();
  const bgColor = cell.getBgColor();
  const underlineColorMode = cell.getUnderlineColorMode();
  const underlineColorValue = cell.getUnderlineColor();
  const width = cell.getWidth();

  return {
    char: width === 0 ? "" : cell.getChars() || " ",
    fg: color(fgMode, fgColor),
    bg: color(bgMode, bgColor),
    bold: !!cell.isBold(),
    dim: !!cell.isDim(),
    italic: !!cell.isItalic(),
    underline: underlineStyle(cell.getUnderlineStyle()),
    underlineColor: color(underlineColorMode, underlineColorValue),
    strikethrough: !!cell.isStrikethrough(),
    inverse: !!cell.isInverse(),
    blink: !!cell.isBlink(),
    hidden: !!cell.isInvisible(),
    wide: width === 2,
    continuation: width === 0,
    hyperlink: null,
    fgMode,
    fgColor,
    bgMode,
    bgColor,
    underlineColorMode,
    underlineColorValue,
    overline: !!cell.isOverline(),
  };
}

function cellsToTrimmedText(cells) {
  return cells
    .filter((cell) => !cell.continuation)
    .map((cell) => cell.char || " ")
    .join("")
    .trimEnd();
}

function createXtermBackend(backendOptions = {}) {
  const decoder = new TextDecoder();
  const encoder = new TextEncoder();
  let term = null;
  let title = "";
  let responseSink;
  const pendingResponses = [];

  const requireTerm = () => {
    if (!term) throw new Error("xterm backend is not initialized");
    return term;
  };

  const respond = (value) => {
    const bytes = typeof value === "string" ? encoder.encode(value) : value;
    if (responseSink) {
      responseSink(bytes);
    } else {
      pendingResponses.push(bytes);
    }
  };

  const backend = {
    name: "sessh-xterm-headless",
    capabilities: {
      name: "xterm-headless",
      version: "5.5.0",
      truecolor: true,
      kittyKeyboard: false,
      kittyGraphics: false,
      sixel: false,
      osc8Hyperlinks: true,
      semanticPrompts: false,
      unicode: "unicode",
      reflow: true,
      extensions: new Set(),
    },
    get onResponse() {
      return responseSink;
    },
    set onResponse(handler) {
      responseSink = handler;
      if (!responseSink) return;
      while (pendingResponses.length > 0) {
        responseSink(pendingResponses.shift());
      }
    },
    init(options) {
      term?.dispose();
      term = new XtermTerminal({
        cols: options.cols,
        rows: options.rows,
        scrollback: options.scrollbackLimit ?? 1000,
        allowProposedApi: true,
      });
      title = "";
      term.onTitleChange((value) => {
        title = value;
      });
      term.onData((value) => {
        if (backendOptions.respondToQueries === false) return;
        respond(value);
      });
    },
    destroy() {
      term?.dispose();
      term = null;
    },
    feed(data) {
      requireTerm()._core._writeBuffer.writeSync(decoder.decode(data, { stream: true }));
    },
    resize(cols, rows) {
      term?.resize(cols, rows);
    },
    reset() {
      requireTerm()._core._writeBuffer.writeSync("\x1bc");
      title = "";
    },
    getText() {
      const buffer = requireTerm().buffer.active;
      const lines = [];
      for (let row = 0; row < buffer.length; row += 1) {
        lines.push(cellsToTrimmedText(this.getLine(row)));
      }
      return lines.join("\n");
    },
    getTextRange(startRow, startCol, endRow, endCol) {
      const lines = [];
      for (let row = startRow; row <= endRow; row += 1) {
        const line = this.getLine(row);
        const from = row === startRow ? startCol : 0;
        const to = row === endRow ? endCol : line.length;
        lines.push(cellsToTrimmedText(line.slice(from, to)));
      }
      return lines.join("\n");
    },
    getCell(row, col) {
      const line = requireTerm().buffer.active.getLine(row);
      return cellFromXterm(line?.getCell(col));
    },
    getLine(row) {
      const active = requireTerm().buffer.active;
      const line = active.getLine(row);
      const cells = [];
      for (let col = 0; col < requireTerm().cols; col += 1) {
        cells.push(cellFromXterm(line?.getCell(col)));
      }
      return cells;
    },
    getLines() {
      const buffer = requireTerm().buffer.active;
      const lines = [];
      for (let row = 0; row < buffer.length; row += 1) {
        lines.push(this.getLine(row));
      }
      return lines;
    },
    getCursor() {
      const active = requireTerm().buffer.active;
      const coreService = term?._core?.coreService;
      return {
        x: active.cursorX,
        y: active.cursorY,
        visible: coreService ? !coreService.isCursorHidden : null,
        style: term?.options?.cursorStyle === "bar" ? "beam" : term?.options?.cursorStyle ?? null,
      };
    },
    getMode(mode) {
      const active = requireTerm().buffer.active;
      const coreService = term?._core?.coreService;
      const decPrivateModes = coreService?.decPrivateModes ?? {};
      switch (mode) {
        case "altScreen":
          return active.type === "alternate";
        case "cursorVisible":
          return coreService ? !coreService.isCursorHidden : true;
        case "bracketedPaste":
          return !!decPrivateModes.bracketedPasteMode;
        case "applicationCursor":
          return !!decPrivateModes.applicationCursorKeys;
        case "applicationKeypad":
          return !!decPrivateModes.applicationKeypad;
        case "originMode":
          return !!decPrivateModes.origin;
        case "autoWrap":
          return coreService?.modes?.wraparound ?? true;
        case "mouseTracking":
        case "focusTracking":
        case "insertMode":
        case "reverseVideo":
        default:
          return false;
      }
    },
    getTitle() {
      return title;
    },
    getScrollback() {
      const active = requireTerm().buffer.active;
      return {
        viewportOffset: active.viewportY,
        totalLines: active.length,
        screenLines: requireTerm().rows,
      };
    },
    encodeKey(key) {
      return encodeKeyToAnsi(key);
    },
    scrollViewport(delta) {
      requireTerm().scrollLines(delta);
    },
  };

  return backend;
}

export function createTestTerminal(options = {}) {
  const { respondToQueries, ...terminalOptions } = options;
  return createTerminal({
    cols: 80,
    rows: 24,
    scrollbackLimit: 1000,
    ...terminalOptions,
    backend: createXtermBackend({ respondToQueries }),
  });
}

export function makeTermlessTempRoot(prefix) {
  return mkdtempSync(join("/tmp", prefix));
}

export function makeIsolatedEnv(root, shell) {
  const env = {
    PATH: process.env.PATH || "/usr/bin:/bin",
    TERM: "xterm-256color",
    HISTFILE: "/dev/null",
    SHELL: shell,
    SESSH_GUID: "",
    SESSH_ID: "",
    HOME: join(root, "home"),
    XDG_RUNTIME_DIR: join(root, "runtime"),
    XDG_CACHE_HOME: join(root, "cache"),
    XDG_CONFIG_HOME: join(root, "config"),
    XDG_DATA_HOME: join(root, "data"),
    XDG_STATE_HOME: join(root, "state"),
    TMPDIR: join(root, "tmp"),
  };

  for (const key of [
    "HOME",
    "XDG_RUNTIME_DIR",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "TMPDIR",
  ]) {
    mkdirSync(env[key], { recursive: true, mode: 0o700 });
  }

  return env;
}

export function writeShellEmitter(path) {
  writeFileSync(
    path,
    [
      "#!/bin/sh",
      "printf 'SESSH_TERMLESS_READY\\r\\n'",
      "printf '\\033]2;sessh-termless\\007'",
      "sleep 1",
      "",
    ].join("\n"),
  );
  chmodSync(path, 0o700);
}

export async function waitForTitle(term, expected, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (term.getTitle() === expected) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`Timeout waiting for title ${JSON.stringify(expected)}; current title: ${JSON.stringify(term.getTitle())}`);
}

export async function waitForText(term, expected, timeoutMs = 5000) {
  try {
    await term.waitFor(expected, timeoutMs);
  } catch (error) {
    throw new Error(`${error.message}\n\nTerminal text:\n${term.getText()}`);
  }
}

export function screenBase(term) {
  const scrollback = term.getScrollback();
  return scrollback.totalLines - scrollback.screenLines;
}

export function screenText(term, rows = term.rows) {
  const base = screenBase(term);
  const lines = [];
  for (let row = 0; row < rows; row += 1) {
    lines.push(cellsToTrimmedText(term.getLine(base + row)));
  }
  return `${lines.join("\n")}\n`;
}

function comparableCell(cell) {
  return {
    char: cell.char,
    bold: cell.bold,
    dim: cell.dim,
    italic: cell.italic,
    underline: cell.underline,
    underlineColorMode: cell.underlineColorMode,
    underlineColorValue: cell.underlineColorValue,
    strikethrough: cell.strikethrough,
    inverse: cell.inverse,
    blink: cell.blink,
    hidden: cell.hidden,
    wide: cell.wide,
    continuation: cell.continuation,
    fgMode: cell.fgMode,
    fgColor: cell.fgColor,
    bgMode: cell.bgMode,
    bgColor: cell.bgColor,
    overline: cell.overline,
  };
}

export function screenCells(term, rows = term.rows, cols = term.cols) {
  const base = screenBase(term);
  const lines = [];
  for (let row = 0; row < rows; row += 1) {
    const line = term.getLine(base + row);
    lines.push(line.slice(0, cols).map(comparableCell));
  }
  return lines;
}

export function terminalState(term, rows = term.rows, cols = term.cols) {
  const cursor = term.getCursor();
  return {
    cursor: [cursor.x, cursor.y],
    capture: screenText(term, rows),
    cells: screenCells(term, rows, cols),
  };
}
