# Computer-use MCP (Cursor)

Canonical guide for a **Cursor agent** driving the Vocello **Debug build** via the **`user-computer-use`** MCP server. Pair with [`ui-test-surface.md`](ui-test-surface.md) for AX identifiers, smoke/bench skeletons, and verification commands.

## MCP invocation

Use `CallMcpTool`:

| Field | Value |
|---|---|
| `server` | `user-computer-use` |
| `toolName` | `computer` |

The tool accepts a single `action` plus optional `coordinate` and `text`. Coordinates are **(x, y) pixels from the top-left of the screenshot image** returned by `get_screenshot` — use the `image_width` and `image_height` from the JSON text part of that response as `$IW` / `$IH`.

The MCP scales agent-supplied coordinates from image space to logical screen space internally. Always pass coords in **screenshot image space**, not macOS logical points.

## Tool mapping

| Intent | `computer` call |
|---|---|
| Capture screen | `action: "get_screenshot"` → parse `image_width`, `image_height` from JSON text part |
| Click | `action: "left_click"`, `coordinate: [cx, cy]` |
| Type into focused field | `action: "type"`, `text: "..."` (click the field first) |
| Key / chord | `action: "key"`, `text: "super+Return"` (`super` = Command on macOS) |
| Move cursor | `action: "mouse_move"`, `coordinate: [x, y]` |
| Scroll | `action: "scroll"`, `coordinate: [x, y]`, `text: "down"` or `"down:500"` |

Common key chords: `super+Return` (Generate), `super+a` (select all), `BackSpace`, `Down`, `Up`, `Return`.

Screenshots include a **red crosshair** at the current cursor position. After a click, take another screenshot to verify the crosshair landed on the target; adjust proportionally if it missed.

## Per-turn ritual

Every interaction turn:

1. `scripts/uitest.sh activate` — bring Vocello to the front.
2. `get_screenshot` — record `$IW` / `$IH` from the response metadata.
3. `scripts/uitest.sh screen-locate <ax-id> $IW $IH` — map AX identifier to screenshot coords.
4. `left_click` / `type` / `key` as needed.
5. Optional: second `get_screenshot` to confirm focus and crosshair placement.

**Window focus:** On macOS, clicking a window that is not focused may only raise it without triggering the element. If an action had no effect, click the same target again — the window should now be focused and the second click registers.

## Coordinate recipe

```sh
# After get_screenshot returns image_width=1512, image_height=982 (example):
IW=1512
IH=982
read -r CX CY _ _ <<< "$(scripts/uitest.sh screen-locate textInput_textEditor "$IW" "$IH")"
# Pass [CX, CY] to left_click via CallMcpTool
```

Without image dimensions, `screen-locate` prints logical-point coords (`cx cy w h`). Always pass `$IW` / `$IH` when driving clicks through the MCP.

## Standard generate sequence

For any mode that uses `textInput_textEditor`:

1. `screen-locate textInput_textEditor $IW $IH` → `left_click` at `[CX, CY]`.
2. Optional: `key` with `super+a`, then `BackSpace`, to clear existing text.
3. `type` with the fixed prompt script.
4. Capture `T0` **immediately before** Generate:
   ```sh
   T0="$(/usr/bin/python3 -c 'import datetime; print(datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S.%f")[:-3])')"
   ```
5. `key` with `super+Return`.
6. Verify: `scripts/uitest.sh verify-generation <mode> --artifacts-dir "$ART" --since "$T0" --text "..."`.

## Driving SwiftUI Picker menus

SwiftUI `Picker` menus anchor to the **currently-selected item**, not a fixed position. Fixed menu-item click coordinates fail after the first selection in a session.

**Preferred pattern:**

1. `left_click` the picker to open the menu.
2. `key` with `Down` or `Up` N times from the current selection to the target.
3. `key` with `Return` to commit.
4. Track the current selection in agent state to compute N.

Affected pickers: delivery tone, delivery intensity, saved-voice picker, model-variant pickers. See [`ui-test-surface.md`](ui-test-surface.md) for AX ids.

## Harness commands (shell)

Agents run these in the terminal; the MCP handles mouse/keyboard only.

| Command | Purpose |
|---|---|
| `scripts/uitest.sh prep` | Build launch + fresh window |
| `scripts/uitest.sh reset` | Clear generations + outputs |
| `scripts/uitest.sh activate` | Front Vocello before MCP actions |
| `scripts/uitest.sh screen-locate <ax-id> [IW IH]` | Screenshot-space coords |
| `scripts/uitest.sh locate <ax-id>` | Logical-point coords (debug) |
| `scripts/uitest.sh smoke-check <mode>` | Precondition gate |
| `scripts/uitest.sh verify-generation` | Post-generate WAV + DB check |
| `scripts/uitest.sh bench-step` | One bench sample (wait + record) |
| `scripts/uitest.sh bench-compare` | Diff against baselines |

Full command list: `scripts/uitest.sh help`.

## Forbidden paths

Do **not** use these for Vocello UI driving:

- **`user-automation-mcp`** — global screen coords hit whatever window has focus (e.g. a browser tab).
- **osascript `keystroke` / `click at`** — same focus risk; removed from repo gate scripts.
- **Fixed Picker menu-item coordinates** after the first open in a session.

Deprecated coordinate helpers (old Codex key-window API only):

- `window-locate` — key-window-relative scaling for `mcp__computer_use__.get_app_state`.
- `scaled-locate` — legacy alias; use `screen-locate` instead.

## macOS permissions

- **Accessibility** — required for `scripts/uitest.sh locate` / `screen-locate` (System Events AppleScript). Grant to Terminal/Cursor in *System Settings → Privacy & Security → Accessibility*.
- **Screen Recording** — may be required if `get_screenshot` fails (nut-js / `screencapture` fallback).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Text typed into wrong app | `scripts/uitest.sh activate`, refocus editor with `left_click`, retry `type` |
| Click had no effect | Window was unfocused — click same target again |
| Crosshair far from target | Adjust coords proportionally; take fresh screenshot after each attempt |
| `screen-locate` not found | Vocello not running — run `prep` first |
| Readiness line unchanged after type | Editor not focused — click `textInput_textEditor` before `type` |

## Agent bench gate (6-cell review)

For targeted backend reviews (e.g. streaming regression), see [`bench-agent-gate.md`](bench-agent-gate.md).
