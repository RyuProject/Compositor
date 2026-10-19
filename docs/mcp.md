# Using Compositor with Codex and Claude

Compositor exposes the document open in the app as a local Model Context Protocol server. An agent can create editable
layers, paint and retouch, make selections, crop, inspect a rendered preview and save the project without simulating
mouse input.

## Start the in-app server

1. Open **Compositor › MCP Server…**.
2. Turn on **Enabled**.
3. Copy the endpoint and access token, or choose **Copy Connection JSON**.

The default endpoint is `http://127.0.0.1:49678/mcp`. Compositor listens only on this Mac and every request must include
`Authorization: Bearer <access-token>`. Regenerating the token immediately invalidates the old one. Only local Codex or
Claude sessions can reach the loopback endpoint; a cloud-hosted agent cannot connect to it directly.

## Connect Codex

Add this to `~/.codex/config.toml`, replacing `PASTE_TOKEN` with the token shown by Compositor:

```toml
[mcp_servers.compositor]
url = "http://127.0.0.1:49678/mcp"
http_headers = { Authorization = "Bearer PASTE_TOKEN" }
```

Restart Codex after changing the configuration, then verify the connection with `codex mcp list`. Codex can also read
the token from `bearer_token_env_var` so it does not have to be stored in the configuration file.

## Connect Claude Code

Run this from the project where Claude Code should use Compositor, replacing `PASTE_TOKEN`:

```sh
claude mcp add --transport http compositor http://127.0.0.1:49678/mcp \
  --header "Authorization: Bearer PASTE_TOKEN"
```

Alternatively, **Copy Connection JSON** in Compositor produces a complete HTTP server object that can be passed to
`claude mcp add-json compositor '<json>'`. Check the connection with `claude mcp get compositor` or `/mcp`.

## Recommended agent workflow

1. Call `compositor_get_document` to read the canvas, active layer, selection and viewport.
2. Use document coordinates; `(0, 0)` is the top-left of the canvas.
3. Prefer editable Shape, Type and Pen layers when they fit the design. Use paint and retouching tools for raster work.
4. Call `compositor_render_document` after meaningful changes and inspect the returned PNG.
5. Use `compositor_history` to undo or redo. Call `compositor_save_document` only when the user asks to save.

Tool calls affect the open Compositor tab and appear on the canvas immediately.

## Tool coverage

| Compositor tool or operation | MCP tool | Main actions |
| --- | --- | --- |
| Inspect canvas | `compositor_get_document` | Canvas, paginated layers, editable properties, selection and viewport |
| New document | `compositor_create_document` | Size, resolution and background |
| Move / Transform | `compositor_update_layer` | Position, size, rotation, flip, opacity and blend mode |
| Marquee / Lasso | `compositor_set_selection` | Rectangle, ellipse and polygonal paths |
| Magic Wand / Object Selection | `compositor_set_selection` | Color- and object-based selections |
| Selection commands | `compositor_set_selection` | Select all, deselect, invert, add, subtract and feather |
| Crop | `compositor_crop` | Whole-pixel document rectangle |
| Brush / Eraser / Retouch | `compositor_paint_stroke` | Brush, erase, healing, clone, blur, smudge and liquify paths |
| Gradient | `compositor_apply_gradient` | Linear or radial layer or mask gradient |
| Layer and live masks | `compositor_manage_mask` | Add, remove, enable, invert, link, copy and load as a selection |
| Pen | `compositor_add_vector_path`, `compositor_update_vector_path` | Create, move, add or delete anchors and edit cubic handles, path color and width |
| Pen appearance / selection | `compositor_apply_vector_path` | Fill, brush-stroke, clear appearances or load a path directly as a selection |
| Shape | `compositor_add_shape`, `compositor_update_shape` | Create or restyle an editable rectangle, ellipse or line, including smooth corners |
| Type | `compositor_add_text`, `compositor_update_text` | Create or edit content, font, color, alignment and text box |
| Eyedropper | `compositor_sample_color` | Composite color at a document point |
| Hand / Zoom | `compositor_set_view` | Fit, pan and zoom |
| Layers | `compositor_manage_layer` | Add, group, duplicate, rename, delete and place |
| Layer selection | `compositor_select_layer` | Set the active layer |
| Filters | `compositor_get_filter_settings`, `compositor_apply_filter` | Inspect default or current settings and apply any Filter menu effect |
| Adjustment layers | `compositor_manage_adjustment` | Add or update an editable adjustment and its settings |
| Layer effects | `compositor_manage_layer_effect` | Set, remove or clear strokes, shadows, overlays and glows |
| Open / Import | `compositor_open_document`, `compositor_import_files` | Open a `.comp` project or import local images as layers |
| Export | `compositor_export_document` | Export PNG, JPEG, TIFF, PDF or EXR, optionally resized |
| Channels | `compositor_edit_channel` | Load RGB/color/alpha as a selection or fill an 8-bit layer channel |
| History | `compositor_history` | Undo and redo |
| Preview | `compositor_render_document` | Render a bounded PNG preview for visual inspection |
| Save | `compositor_save_document` | Save an existing `.comp` project |

Several related interface modes share one API intentionally. For example, Brush, Eraser and retouching modes all take
a document-space point path through `compositor_paint_stroke`; this gives an agent the same creative operation without
fragile pointer automation. Pen `shape` paths are closed and Pen `line` paths are open. Creating a Pen path preserves
its vector geometry without automatically painting or filling it. Path nodes returned by `compositor_get_document`
and accepted by the Pen APIs are always document pixels, including for rotated, scaled or flipped layers.

Omitted creative settings have stable defaults rather than inheriting whichever controls a person used last. Shapes,
text, Pen paths, paint strokes and gradients can therefore be reproduced across fresh Compositor sessions.

Call `compositor_get_filter_settings` to inspect all supported filter fields and nested defaults. Filter `settings` use
the camelCase names in that result (for example `{"radius": 12}` for Gaussian Blur).
Adjustment `settings` use the names in `LayerAdjustment` (for example `{"blurRadius": 12}` for a Gaussian Blur
adjustment). Nested settings can be supplied as JSON objects; an update keeps omitted values. Compositor validates
settings before applying them. Every filter, adjustment, effect and channel fill is one undoable document edit.

`compositor_edit_channel` can load channels from the active layer or visible composite. Its `fill` action uses a value
from 0 to 1 and respects the current selection. It converts editable Shape, Pen or Type content on that layer to pixels.
It does not fill 16-bit or HDR channels, to preserve their precision. Opening and importing require absolute local file
paths. Export requires a matching extension and refuses to replace an existing file unless `overwrite` is true.

## Safety and limits

- The HTTP listener binds to `127.0.0.1` only, validates `Host` and `Origin`, and requires a random Bearer token.
- Requests are limited to 4 MiB, headers to 64 KiB, active connections and sessions to 32, and incomplete requests to
  a 15-second deadline.
- Only one MCP editing call runs at a time, preventing asynchronous tools from interleaving document mutations.
- Coordinates, canvas sizes, path-node counts, text summaries and layer pages are bounded before allocation.
- Preview images are composited directly at the requested size and capped at 16 megapixels instead of first rendering
  an oversized full-resolution canvas.
- Channel tracing is bounded and exports validate output dimensions and file destinations before writing.

## Optional Pen-only file server

`Tools/CompositorMCP` remains available as a separate stdio server for agents that need to edit Pen paths in a saved
`.comp` package without launching Compositor. Build it with `./scripts/build-mcp.sh`, then register the printed absolute
executable path as a stdio MCP server. Its tools list, create, update, delete and inspect saved Pen paths. Unlike the
in-app server, it edits only the project path supplied in each call and cannot operate the live canvas tools.
