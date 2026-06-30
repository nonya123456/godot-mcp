# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Godot MCP is a Model Context Protocol (MCP) server that lets AI agents drive the Godot game engine: launch the editor, run projects, capture debug output, and perform scene/node operations. It is a stdio MCP server written in TypeScript that shells out to the Godot CLI.

## Commands

- `npm run build` — compile TypeScript (`tsc`) then run `scripts/build.js`, which chmods `build/index.js` to `755` and copies `src/scripts/godot_operations.gd` into `build/scripts/`. **The `.gd` script is not compiled — it must be copied, so always rebuild after editing it.**
- `npm run watch` — `tsc --watch` for incremental TypeScript compilation. Note this does NOT re-run `scripts/build.js`, so the `.gd` copy and chmod are skipped; run `npm run build` when the GDScript or executable bit matters.
- `npm run inspector` — launch `@modelcontextprotocol/inspector` against `build/index.js` for interactive tool testing.
- There is no test suite, linter, or formatter configured.

Requires Node `>=18` and a Godot executable. Set `GODOT_PATH` to point at the Godot binary (otherwise it auto-detects common install locations per-platform); set `DEBUG=true` for verbose stderr logging.

## Architecture

The codebase is two files doing two halves of the work:

- **`src/index.ts`** — the entire MCP server, a single `GodotServer` class (~2200 lines). It registers all tools, validates arguments, locates the Godot binary, and spawns Godot processes.
- **`src/scripts/godot_operations.gd`** — a single bundled GDScript run by Godot in `--headless --script` mode. It dispatches on an operation name via the `match` block in `_init()` and implements the complex scene-manipulation operations.

### Two execution paths

1. **Direct CLI commands** for simple operations. `launch_editor` and `run_project` use `spawn()` with Godot flags (`-e` for editor, `-d` for debug run). `get_godot_version`, `get_project_info`, `get_uid`, `update_project_uids` use `--version`. `run_project` keeps a single `activeProcess` handle whose stdout/stderr are buffered into arrays; `get_debug_output` reads those buffers and `stop_project` kills the process.
2. **Bundled GDScript operations** for `create_scene`, `add_node`, `load_sprite`, `export_mesh_library`, `save_scene`, `get_uid`, and `update_project_uids` (which maps to the `resave_resources` GDScript op). These go through `executeOperation(operation, params, projectPath)`, which invokes Godot as:
   `godot --headless --path <projectPath> --script <godot_operations.gd> <operation> <jsonParams> [--debug-godot]`
   The operation name and a JSON params blob are passed as positional CLI args; the `.gd` script parses them back out by index relative to `--script`.

### Parameter naming convention

The server accepts both `snake_case` and `camelCase` tool arguments. Internally everything is normalized to camelCase (`normalizeParameters` + `parameterMappings`), then converted back to snake_case (`convertCamelToSnakeCase`) before being JSON-serialized and handed to the GDScript, which expects snake_case keys. When adding a parameter, update `parameterMappings` so both naming styles are accepted and round-trip correctly.

### Adding a new tool

Three places must stay in sync:
1. Add the tool definition (name + `inputSchema`) to the `tools` array in `setupToolHandlers()`.
2. Add a `case` in the `CallToolRequestSchema` handler's `switch` routing to a new `handle*` method.
3. If it needs a complex Godot operation, add a `match` arm and `func` in `godot_operations.gd` and call it via `executeOperation`.

## Security model (do not regress)

This server runs agent-supplied input against a local engine, so several guards are deliberate:

- **No shell interpolation.** All Godot invocations use `execFile`/`spawn` with argument arrays — never string concatenation into a shell. Keep it that way to prevent command injection.
- **Path traversal.** `validatePath()` rejects any path containing `..`. Every handler validates its path args before use.
- **Arbitrary script instantiation.** `validateClassName()` (TS side) restricts `nodeType`/`rootNodeType` to plain identifiers (`/^[A-Za-z_][A-Za-z0-9_]*$/`) — no `res://`, paths, or extensions. On the GDScript side, `get_script_by_name()` only resolves names through `ProjectSettings.get_global_class_list()` and never `load()`s a raw caller-supplied path. This pair prevents an agent from instantiating an attacker-controlled script. (See commit `d4cc0f9`.)

## Godot version notes

UID operations (`get_uid`, `update_project_uids`) require Godot 4.4+; handlers gate on `isGodot44OrLater()` parsed from `--version`. The GDScript uses Godot 4.x APIs (`JSON.new()`, `SceneTree`, `ClassDB`), so this targets Godot 4.x.
