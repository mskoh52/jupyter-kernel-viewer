# Developing Jupyter Kernel Viewer

## Overview

Jupyter Kernel Viewer is a single-file browser app (`jupyter_kernel_viewer.html`) that connects to a running Jupyter server's WebSocket `iopub`-style channel and displays execution activity in real time. It is **read-only**: it never sends execute requests. It subscribes to the kernel's `/api/kernels/<id>/channels` WebSocket, parses every incoming message, and builds an in-memory history of cells. Users can browse that history, inspect outputs, annotate entries, and delete them.

---

## File Structure

The file is a single `index.html` with three major sections:

1. **CSS** (`<style>`, lines 6–141) — all visual styling. Dark theme. Defines the three-panel layout (`#sidebar`, `#output-panel`, `#right-panel`), the resize handles, tab bar, sidebar item styles, badge styles, and annotation input.

2. **HTML** (`<body>`, lines 143–179) — static skeleton only. A `#config` bar (URL input, kernel select, Connect/Disconnect/Undo buttons, status badge) and a `#workspace` flex row containing the three panels and two resize handles. All dynamic content is written by JavaScript.

3. **JavaScript** (`<script>`, lines 180–623) — all application logic. No external libraries (Plotly is loaded lazily inside an iframe srcdoc). Sections, in order:
   - Global state declarations
   - Resize handle logic (IIFE)
   - Config bar height measurement (IIFE)
   - WebSocket helpers (`parseUrl`, `fetchKernels`, `connect`, `disconnect`, `setStatus`)
   - Message handler (`handleMsg`)
   - Cell selection and deletion (`selectCell`, `deleteCell`)
   - Undo system (`saveUndo`, `applyUndo`, `updateUndoBtn`)
   - Tab switching (`switchTab`)
   - Render functions (`renderSidebar`, `renderOutput`, `renderRightPanel`)
   - HTML escape helper (`esc`)
   - Keyboard navigation
   - Config persistence (`saveConfig`, `loadConfig` IIFE)
   - Initial render call

---

## State Model

All state is module-level `let` variables declared at line 181:

| Variable | Type | Purpose |
|---|---|---|
| `ws` | `WebSocket \| null` | Active WebSocket connection, or `null` when disconnected. |
| `cells` | `Object<id, Cell>` | Map from message ID to cell object. |
| `order` | `Array<string>` | Cell IDs in display order — newest first (prepended via `unshift`). |
| `selected` | `string \| null` | ID of the currently selected cell. |
| `activeTab` | `'input' \| 'stderr' \| 'tb'` | Which right-panel tab is showing. |
| `insertMode` | `boolean` | When `true`, the selected sidebar item shows the annotation text input instead of normal content. |
| `undoSnapshot` | `Object \| null` | Depth-1 snapshot of `{cells, order, selected}` saved before a delete. |
| `lastD` | `number` | Timestamp of the last `d` keypress, used to detect the `dd` double-press. |

---

## Cell Object Shape

Each entry in `cells` has this shape (created in `handleMsg` on `execute_input`):

```js
{
  id:          string,    // parent msg_id (or header.msg_id if parent is absent)
  input:       string,    // source code from execute_input content.code
  count:       number,    // execution_count from execute_input
  outputs:     Array,     // stdout lines and rich results (see below)
  stderr:      string[],  // text chunks from stream/stderr messages
  tracebacks:  Array,     // {ename, evalue, tb} objects from error messages
  hasError:    boolean,   // true once any error message arrives
  annotation:  string,    // user-entered label, default ''
  ts:          number,    // Date.now() at creation time
}
```

Each entry in `outputs` is one of:
- `{ type: 'stdout', text }` — from `stream` with `name === 'stdout'`
- `{ type: 'result', text, html, img, plotly }` — from `execute_result` or `display_data`; only one of `html`/`img`/`plotly` is typically set

---

## Message Handling

`handleMsg(msg)` is called for every WebSocket message after JSON parsing.

**Routing key:** `msg.parent_header.msg_id` (`pid`) ties a reply back to the cell that triggered it. All message types except `execute_input` are silently dropped when `pid` is missing or not in `cells`.

| `msg_type` | Action |
|---|---|
| `execute_input` | Creates a new cell keyed on `pid` (falls back to `msg.header.msg_id` if `pid` is absent). Prepends the ID to `order`. Calls `selectCell` to make it selected. Always calls `renderSidebar`. |
| `stream` | Appends text to `cell.stderr` if `content.name === 'stderr'`; otherwise pushes a `stdout` output. |
| `execute_result` / `display_data` | Pushes a `result` output containing whichever of `image/png`, `text/html`, `application/vnd.plotly.v1+json`, or `text/plain` is present in `content.data`. |
| `error` | Strips ANSI escape codes from `content.traceback` with `/\x1b\[[0-9;]*m/g`, pushes to `cell.tracebacks`, sets `cell.hasError = true`. |

After any mutating branch (all except `execute_input`), `renderSidebar()` is called unconditionally, and `renderOutput()` + `renderRightPanel()` are called only when `selected === pid`.

---

## Rendering Pipeline

Three render functions rebuild their DOM section from scratch each call (except `renderSidebar`, which reuses existing elements by `data-id`).

| Function | Triggered by | What it touches |
|---|---|---|
| `renderSidebar()` | `handleMsg`, `selectCell`, `deleteCell`, `applyUndo`, `renderSidebar` (self, from insert-mode blur) | `#sidebar` — list of `.hist-item` elements |
| `renderOutput()` | `selectCell`, `deleteCell`, `applyUndo`, `handleMsg` (if selected matches) | `#output-panel` — clears and rebuilds all output blocks |
| `renderRightPanel()` | `selectCell`, `deleteCell`, `applyUndo`, `handleMsg` (if selected matches), `switchTab`, initial call at startup | `#right-panel` tab bar counts + `#tab-content` |

`renderSidebar` is incremental: it queries existing `.hist-item` elements by `data-id`, reuses them if already in the DOM, appends new ones, and removes stale ones. This avoids destroying the annotation input while the user is typing.

---

## Output Rendering

`renderOutput()` iterates `cell.outputs` then `cell.tracebacks`. For each output object in `cell.outputs`:

- **`image/png`** — rendered as `<img src="data:image/png;base64,…">` directly inside a `.out-block` div.
- **`application/vnd.plotly.v1+json`** — rendered in a sandboxed `<iframe srcdoc="…">`. The srcdoc loads Plotly from `https://cdn.plot.ly/plotly-latest.min.js` and calls `Plotly.newPlot`. Dark-theme overrides (`paper_bgcolor`, `plot_bgcolor`, `font.color`) are merged into the layout. An `onload` handler resizes the iframe height to `contentDocument.body.scrollHeight`.
- **`text/html`** — rendered in an `<iframe srcdoc="…">` with a minimal dark-theme wrapper. Same `onload` height resize.
- **`text/plain`** (fallback) — set as `textContent` on a pre-wrap `.out-block`.

Tracebacks from `cell.tracebacks` are rendered as red (`#cb6b6b`) `.out-block` divs showing `ename: evalue` only (the full `tb` string appears in the right panel traceback tab).

---

## Right Panel Tabs

`activeTab` (`'input'` | `'stderr'` | `'tb'`) controls what `renderRightPanel()` puts in `#tab-content`.

- **input** — shows `cell.annotation` (blue, above a divider) if set, then `cell.input` as monospace pre-wrap text.
- **stderr** — sets `content.className = 'stderr'` (red text), joins `cell.stderr` array as a single string.
- **traceback** — renders each entry in `cell.tracebacks` as a `.tb-block` div with `ename: evalue\n<stripped traceback>`.

The stderr and traceback tab buttons show a red count badge (`.tab-count.show`) when the selected cell has content in those arrays. The badge elements are rebuilt inline via `innerHTML` each render because `textContent` assignment earlier in the function wipes the child spans.

---

## Keyboard Shortcuts

The keydown listener (line 584) ignores events when `e.target.tagName === 'INPUT'` or when `insertMode` is `true`, so typing in the URL bar or annotation field is never intercepted.

| Key | Action |
|---|---|
| `j` | Move selection down (toward older entries, higher index in `order`). |
| `k` | Move selection up (toward newer entries, lower index in `order`). |
| `dd` | Two `d` presses within 400 ms deletes the selected cell (saves undo first). |
| `z` | Apply undo (calls `applyUndo()`). |
| `i` | Enter insert mode for the selected cell — shows annotation input in sidebar. |
| `Escape` (in annotation input) | Saves annotation value and exits insert mode (handled by `ai.onkeydown` in `renderSidebar`). `Enter` does the same. |

Insert mode is also exited on `blur` of the annotation input, and whenever `selectCell` or `deleteCell` is called.

---

## Sidebar Features

Each `.hist-item` in normal mode renders:
- **Badge** (`ok` green / `err` red) — shown only when the cell has at least one output, stderr entry, or traceback. `err` takes precedence over `ok`.
- **Annotation** — shown in blue (`.hist-annotation`, `#a0c4ff`) above the code snippet when `cell.annotation` is non-empty.
- **Code snippet** — first line of `cell.input`, truncated with `text-overflow: ellipsis`.
- **Timestamp** — `cell.ts` formatted as `HH:MM:SS` via `toLocaleTimeString`.
- **Delete button** — `×` button (`.del-btn`) absolutely positioned to the right. Click calls `deleteCell(id)` after `stopPropagation`.

The active item gets `.hist-item.active` (left white border, `#2a2a2a` background).

In insert mode, the annotation input replaces the badge/annotation row, with the code snippet below it and the delete button retained.

---

## Resize Handles

Two `div.resize-handle` elements (`#handle-left`, `#handle-right`) sit between the three panels in the flex row.

The `initResize` IIFE attaches `mousedown` listeners to each handle. On mousedown, `startDrag` captures a `mousemove` listener on `window` and removes it on `mouseup`. The handle gets class `dragging` (highlights the 1 px center line).

**Left handle** (sidebar ↔ output-panel): Tracks the combined width of sidebar + output-panel. As the mouse moves, sidebar width = `clientX - workspace.left`, clamped to `[SIDEBAR_MIN=80, totalWidth - OUTPUT_MIN]`. Output-panel takes the remainder, floored at `OUTPUT_MIN=200`.

**Right handle** (output-panel ↔ right-panel): Same pattern. Output-panel width = `clientX - outputPanel.left`, clamped at `OUTPUT_MIN=200`. Right-panel takes the remainder, floored at `RIGHT_MIN=120`.

Widths are set via `element.style.flexBasis`. The panels use `flex-shrink: 0` so flex does not override the explicit basis.

A second IIFE (`measureConfigBar`) runs on load to measure the real rendered height of `#config` and sets `--config-h` on `:root`. The sticky sidebar and right panel use `top: var(--config-h)` and `height: calc(100vh - var(--config-h))` so they fill the viewport below the config bar without hardcoding a pixel value.

---

## Config Persistence

Two keys are saved to `localStorage` under the prefix `jkv_`:

| Key | Value | Saved when |
|---|---|---|
| `jkv_url` | Raw text of `#url-i` | `saveConfig()`, called at the start of `connect()` |
| `jkv_kid` | Selected kernel ID from `#kid-i` | Same |

On page load, `loadConfig()` (IIFE at line 614) reads `jkv_url` back into the URL field, then immediately calls `fetchKernels()` to repopulate the kernel select. Inside `fetchKernels()`, after the kernel list is loaded, the saved `jkv_kid` is matched against kernel IDs and the matching `<option>` gets `selected` if found.

---

## Kernel Discovery

`fetchKernels()` is called on `blur` of the URL field and on page load (if a saved URL exists).

1. `parseUrl()` parses the raw URL field value. It normalises the string (strips trailing slash, prepends `http://` if no scheme), extracts `?token=` from the query string, and strips everything at or after `/api/` from the path to get the server root. Returns `{ base, token }`.
2. Fetches `${base}/api/kernels` (with `?token=…` appended if present).
3. On success, builds `<option value="<id>">` elements with label `<name> — <id[:8]>`. Re-selects the previously saved kernel ID if it appears in the list.
4. On failure, shows `— error fetching kernels —`.

`connect()` uses the same `parseUrl()` output to build the WebSocket URL by replacing `http`/`https` with `ws`/`wss` and appending `/api/kernels/<kid>/channels`.

---

## Undo System

The undo system is a depth-1 snapshot (one level only).

- **`saveUndo()`** — deep-clones `cells` via `JSON.parse(JSON.stringify(cells))`, shallow-copies `order`, records `selected`. Stores result in `undoSnapshot`. Calls `updateUndoBtn()` to show the undo button.
- **`applyUndo()`** — destructures `undoSnapshot` back into the live `cells`, `order`, `selected`. Clears `undoSnapshot`, exits insert mode, hides undo button, re-renders everything.
- **`updateUndoBtn()`** — sets `#undo-btn` display to `''` when `undoSnapshot` is set, `'none'` otherwise.

`saveUndo()` is called only from `deleteCell()`. Performing a second delete overwrites the previous snapshot (no multi-level undo). The undo button is also wired to keyboard `z`.

---

## Known Limitations and Extension Points

**No persistence across reload.** `cells` and `order` are in-memory only. Refreshing the page clears all history. To add persistence, serialize `cells` and `order` to `localStorage` (or IndexedDB for larger data) and restore them on load.

**CORS.** The browser must be able to reach the Jupyter server directly. This works for local servers. Remote servers require either CORS headers (`c.ServerApp.allow_origin = '*'`) or opening the app from the same origin.

**ANSI codes stripped, not rendered.** The `error` handler removes ANSI escape sequences with a regex. Terminal color in tracebacks is lost. To render colors, replace the strip step with a small ANSI-to-HTML converter (e.g., `ansi_up`) applied before inserting into the DOM.

**No syntax highlighting.** `cell.input` is displayed as plain monospace text. Adding highlight.js or Prism (loaded lazily, as Plotly is) would improve readability. The injection point is `renderRightPanel` in the `input` tab branch, and optionally the sidebar snippet.

**No search or filter.** The sidebar has no search box. A filter input above the sidebar that hides non-matching `.hist-item` elements by comparing against `cell.input` and `cell.annotation` would be a low-effort addition.

**Single undo level.** Only the most recent delete can be undone. A proper undo stack would replace `undoSnapshot` with an array and push/pop as needed.

**iframe height sizing is best-effort.** The `onload` height resize for HTML and Plotly iframes catches errors silently (`try/catch`). Cross-origin restrictions in some browser configurations may prevent reading `contentDocument.body.scrollHeight`, leaving the iframe at its `min-height`.
