import AppKit
import Foundation

struct MCPToolFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Translates model-facing tool calls into the same EditorSession operations the interface uses. It stays on the
/// main actor so an MCP edit and a pointer edit can never mutate a document at the same time.
@MainActor
final class MCPToolRouter {
    static let previewPixelLimit = 16_000_000
    static let maximumCoordinate = Double(DocumentLimits.maxSide)
    static let documentVectorNodeLimit = 10_000
    static let documentTextCharacterLimit = 200_000
    static let documentTextStyleRunLimit = 10_000
    let workspace: ProjectWorkspace

    init(workspace: ProjectWorkspace) { self.workspace = workspace }

    static let tools: [[String: Any]] = {
        [
            tool("compositor_get_document", "Inspect the current Compositor canvas and a page of its layers.", schema(
                properties: [
                    "layer_offset": integer("Zero-based first layer in the returned page. Defaults to 0.", minimum: 0, maximum: 10_000),
                    "layer_limit": integer("Maximum layers to return. Defaults to 500.", minimum: 1, maximum: 2_000)
                ]),
                 readOnly: true, destructive: false, idempotent: true),
            tool("compositor_create_document", "Create a new canvas in a new tab without replacing the current document.", schema(
                properties: [
                    "width": integer("Canvas width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "height": integer("Canvas height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "resolution": number("Resolution in pixels per inch. Defaults to 72.", minimum: 1, maximum: 9_600),
                    "background": string("Optional #RRGGBB background color, or transparent.")
                ], required: ["width", "height"]), destructive: false),
            tool("compositor_add_shape", "Use Compositor's Shape tool to add an editable rectangle, ellipse, or line. Coordinates are document pixels.", schema(
                properties: [
                    "kind": enumString("Shape type.", ["rectangle", "ellipse", "line"]),
                    "start_x": number("First corner or line endpoint x."), "start_y": number("First corner or line endpoint y."),
                    "end_x": number("Opposite corner or line endpoint x."), "end_y": number("Opposite corner or line endpoint y."),
                    "color": string("Fill or stroke color as #RRGGBB. Defaults to #000000."),
                    "corner_radius": number("Rectangle corner radius in document pixels.", minimum: 0, maximum: 150_000),
                    "smooth_corners": ["type": "boolean", "description": "Use 60% continuous corner smoothing on a rounded rectangle."],
                    "line_width": number("Line thickness in document pixels.", minimum: 1, maximum: 5_000)
                ], required: ["kind", "start_x", "start_y", "end_x", "end_y"]), destructive: false),
            tool("compositor_add_text", "Use Compositor's Type tool to add an editable text layer. The x and y values are the text box's top-left document coordinates.", schema(
                properties: [
                    "content": string("Text content, including line breaks."),
                    "x": number("Text box x coordinate."), "y": number("Text box y coordinate."),
                    "font_name": string("Installed PostScript font name. Defaults to Helvetica."),
                    "font_size": number("Font size in layer pixels.", minimum: 1, maximum: 2_000),
                    "color": string("Text color as #RRGGBB."),
                    "alignment": enumString("Paragraph alignment.", ["left", "center", "right"]),
                    "tracking": number("Character spacing from -100 through 1000.", minimum: -100, maximum: 1_000),
                    "leading": number("Line height in pixels; 0 uses automatic leading.", minimum: 0, maximum: 5_000),
                    "box_width": number("Optional fixed paragraph-box width.", minimum: 16, maximum: 300_000),
                    "box_height": number("Optional fixed paragraph-box height.", minimum: 16, maximum: 300_000)
                ], required: ["content", "x", "y"]), destructive: false),
            tool("compositor_add_vector_path", "Add an editable Pen shape or line to the current canvas. Coordinates are document pixels.", schema(
                properties: [
                    "mode": enumString("A shape is closed; a line remains open.", ["shape", "line"]),
                    "nodes": ["type": "array", "minItems": 2, "maxItems": 10_000,
                              "description": "Path anchors and optional cubic handles in document pixels.",
                              "items": schema(properties: [
                                "x": number("Anchor x coordinate."), "y": number("Anchor y coordinate."),
                                "in_x": number("Incoming handle x coordinate; defaults to x."),
                                "in_y": number("Incoming handle y coordinate; defaults to y."),
                                "out_x": number("Outgoing handle x coordinate; defaults to x."),
                                "out_y": number("Outgoing handle y coordinate; defaults to y.")
                              ], required: ["x", "y"])],
                    "color": string("Editable path color as #RRGGBB. Defaults to #000000."),
                    "line_width": number("Editable path width in document pixels.", minimum: 1, maximum: 5_000),
                    "closed": ["type": "boolean", "description": "Shapes must be closed and lines must remain open."]
                ], required: ["mode", "nodes"]), destructive: false),
            tool("compositor_update_vector_path", "Replace the anchors or editable appearance of an existing Pen path. Node coordinates are document pixels; replacing nodes supports adding, deleting, moving, and changing handles in one atomic edit.", schema(
                properties: [
                    "layer_id": string("Editable vector-path layer UUID."),
                    "mode": enumString("A shape is closed; a line remains open.", ["shape", "line"]),
                    "nodes": ["type": "array", "minItems": 2, "maxItems": 10_000,
                              "description": "Complete replacement list of anchors and optional cubic handles in document pixels.",
                              "items": schema(properties: [
                                "x": number("Anchor x coordinate."), "y": number("Anchor y coordinate."),
                                "in_x": number("Incoming handle x coordinate; defaults to x."),
                                "in_y": number("Incoming handle y coordinate; defaults to y."),
                                "out_x": number("Outgoing handle x coordinate; defaults to x."),
                                "out_y": number("Outgoing handle y coordinate; defaults to y.")
                              ], required: ["x", "y"])],
                    "subpath_starts": ["type": "array", "maxItems": 9_999,
                                       "description": "Optional node indexes that begin additional disconnected line subpaths.",
                                       "items": ["type": "integer", "minimum": 1, "maximum": 9_999]],
                    "color": string("Editable path color as #RRGGBB."),
                    "line_width": number("Editable path width in document pixels.", minimum: 1, maximum: 5_000)
                ], required: ["layer_id"]), destructive: true),
            tool("compositor_apply_vector_path", "Fill, brush-stroke, clear an appearance from, or load an editable Pen path as a selection.", schema(
                properties: [
                    "layer_id": string("Editable vector-path layer UUID."),
                    "action": enumString("Path operation.", ["fill", "stroke", "clear_fill", "clear_stroke", "clear_erasures", "load_selection"]),
                    "color": string("Fill or stroke color as #RRGGBB. Defaults to #000000."),
                    "size": number("Brush-stroke diameter in document pixels. Defaults to 40.", minimum: 1, maximum: 2_000),
                    "hardness": number("Brush-stroke hardness from 0 through 1. Defaults to 1.", minimum: 0, maximum: 1),
                    "opacity": number("Brush-stroke opacity from 0 through 1. Defaults to 1.", minimum: 0.01, maximum: 1),
                    "mode": enumString("For load_selection, how the path combines with the current selection.", ["replace", "add", "subtract"])
                ], required: ["layer_id", "action"]), destructive: true),
            tool("compositor_update_shape", "Update the editable style of an existing Shape layer without rasterizing it.", schema(
                properties: [
                    "layer_id": string("Editable shape layer UUID."),
                    "kind": enumString("Shape type.", ["rectangle", "ellipse", "line"]),
                    "color": string("Fill or stroke color as #RRGGBB."),
                    "corner_radius": number("Rectangle corner radius in document pixels.", minimum: 0, maximum: 150_000),
                    "smooth_corners": ["type": "boolean", "description": "Use 60% continuous corner smoothing on a rounded rectangle."],
                    "line_width": number("Line thickness in document pixels.", minimum: 1, maximum: 5_000)
                ], required: ["layer_id"]), destructive: true),
            tool("compositor_update_text", "Update the content and whole-text style of an existing editable Type layer.", schema(
                properties: [
                    "layer_id": string("Editable text layer UUID."),
                    "content": string("Replacement text content, including line breaks."),
                    "font_name": string("Installed PostScript font name."),
                    "font_size": number("Font size in layer pixels.", minimum: 1, maximum: 2_000),
                    "color": string("Whole-text color as #RRGGBB."),
                    "alignment": enumString("Paragraph alignment.", ["left", "center", "right"]),
                    "tracking": number("Character spacing from -100 through 1000.", minimum: -100, maximum: 1_000),
                    "leading": number("Line height in pixels; 0 uses automatic leading.", minimum: 0, maximum: 5_000),
                    "box_width": number("Fixed paragraph-box width.", minimum: 16, maximum: 300_000),
                    "box_height": number("Fixed paragraph-box height.", minimum: 16, maximum: 300_000),
                    "clear_box": ["type": "boolean", "description": "When true, turn fixed-box text into point text."]
                ], required: ["layer_id"]), destructive: true),
            tool("compositor_set_selection", "Use Marquee, Lasso, Magic Wand, or Object Selection, or modify the current selection. Coordinates are document pixels.", schema(
                properties: [
                    "action": enumString("Selection operation.", ["rectangle", "ellipse", "polygon", "wand", "object", "all", "none", "invert"]),
                    "mode": enumString("How a new region combines with the current selection.", ["replace", "add", "subtract"]),
                    "x": number("Rectangle origin or Wand/Object sample x."), "y": number("Rectangle origin or Wand/Object sample y."),
                    "width": number("Rectangle or ellipse width.", minimum: 0.5, maximum: 300_000),
                    "height": number("Rectangle or ellipse height.", minimum: 0.5, maximum: 300_000),
                    "points": ["type": "array", "minItems": 3, "maxItems": 10_000,
                               "description": "Polygonal Lasso vertices.",
                               "items": schema(properties: ["x": number("Vertex x."), "y": number("Vertex y.")], required: ["x", "y"])],
                    "tolerance": integer("Magic Wand per-channel tolerance.", minimum: 0, maximum: 255),
                    "contiguous": ["type": "boolean"], "sample_all_layers": ["type": "boolean"],
                    "sample_size": enumString("Magic Wand sample averaging.", ["point", "3x3", "5x5"]),
                    "edge_offset": integer("Object Selection edge contraction (positive) or expansion (negative).", minimum: -10, maximum: 10),
                    "antialiased": ["type": "boolean"],
                    "feather": integer("Optional feather radius applied after selection.", minimum: 0, maximum: 250),
                    "layer_id": string("Optional active layer UUID for Wand/Object sampling.")
                ], required: ["action"]), destructive: true),
            tool("compositor_paint_stroke", "Use Brush, Eraser, Spot Healing, Clone Stamp, Blur, Smudge, or Liquify with a document-space point path.", schema(
                properties: [
                    "mode": enumString("Painting or retouching mode.", ["paint", "erase", "spot_healing", "clone_stamp", "blur", "smudge", "liquify"]),
                    "points": ["type": "array", "minItems": 1, "maxItems": 10_000,
                               "description": "Stroke points in document pixels, in order.",
                               "items": schema(properties: ["x": number("Point x."), "y": number("Point y.")], required: ["x", "y"])],
                    "layer_id": string("Target layer UUID; defaults to the active layer."),
                    "target": enumString("Paint pixels or the layer mask.", ["layer", "mask"]),
                    "color": string("Paint color as #RRGGBB. On masks, light colors reveal and dark colors hide."),
                    "size": number("Brush diameter in document pixels.", minimum: 1, maximum: 2_000),
                    "hardness": number("Brush hardness from 0 through 1.", minimum: 0, maximum: 1),
                    "opacity": number("Stroke opacity or retouching strength from 0 through 1.", minimum: 0.01, maximum: 1),
                    "blur_radius": number("Blur radius in pixels for Blur mode.", minimum: 0.1, maximum: 250),
                    "healing_mode": enumString("Spot Healing method.", ["content_aware", "create_texture", "proximity_match"]),
                    "source_x": number("Clone Stamp source x coordinate."), "source_y": number("Clone Stamp source y coordinate."),
                    "aligned": ["type": "boolean"], "sample_all_layers": ["type": "boolean"]
                ], required: ["mode", "points"]), destructive: true),
            tool("compositor_apply_gradient", "Use Compositor's Gradient tool on a layer or mask between two document-space points.", schema(
                properties: [
                    "start_x": number("Gradient start x."), "start_y": number("Gradient start y."),
                    "end_x": number("Gradient end x."), "end_y": number("Gradient end y."),
                    "shape": enumString("Gradient geometry.", ["linear", "radial"]),
                    "style": enumString("Use two colors or fade the foreground to transparent.", ["color_to_color", "color_to_transparent"]),
                    "foreground": string("Start color as #RRGGBB."), "background": string("End color as #RRGGBB."),
                    "opacity": number("Gradient opacity from 0 through 1.", minimum: 0, maximum: 1),
                    "reversed": ["type": "boolean"], "layer_id": string("Target layer UUID."),
                    "target": enumString("Fill layer pixels or its mask.", ["layer", "mask"])
                ], required: ["start_x", "start_y", "end_x", "end_y"]), destructive: true),
            tool("compositor_manage_mask", "Create and manage raster layer masks or assign another layer as a live mask source.", schema(
                properties: [
                    "action": enumString("Mask operation.", ["add", "remove", "enable", "disable", "invert", "link", "unlink", "copy", "load_selection", "select", "set_live_source", "remove_live_source"]),
                    "layer_id": string("Target layer or folder UUID."),
                    "source_layer_id": string("Source layer UUID for copy or set_live_source."),
                    "reveal": ["type": "boolean", "description": "For add, reveal all when true and hide all when false. An active selection becomes a reveal- or hide-selection mask."],
                    "mode": enumString("For load_selection, how the mask's hidden area combines with the current selection.", ["replace", "add", "subtract"])
                ], required: ["action", "layer_id"]), destructive: true),
            tool("compositor_crop", "Use Compositor's Crop tool to replace the canvas with a document-space rectangle.", schema(
                properties: ["x": number("Crop origin x."), "y": number("Crop origin y."),
                             "width": number("Crop width.", minimum: 1, maximum: 300_000),
                             "height": number("Crop height.", minimum: 1, maximum: 300_000)],
                required: ["x", "y", "width", "height"]), destructive: true),
            tool("compositor_sample_color", "Use Compositor's Eyedropper to sample the visible composite at a document pixel.", schema(
                properties: ["x": number("Sample x."), "y": number("Sample y.")], required: ["x", "y"]),
                readOnly: true, destructive: false, idempotent: true),
            tool("compositor_set_view", "Use the Hand or Zoom behavior to fit, zoom, or pan the current canvas view. Pan values are screen points.", schema(
                properties: ["action": enumString("View operation.", ["fit", "zoom", "pan"]),
                             "zoom": number("Zoom factor; 1 is actual pixels.", minimum: 0.001, maximum: 32),
                             "dx": number("Horizontal pan delta in screen points."), "dy": number("Vertical pan delta in screen points.")],
                required: ["action"]), destructive: false),
            tool("compositor_manage_layer", "Create, duplicate, rename, delete, mask, or place layers and folders.", schema(
                properties: [
                    "action": enumString("Layer operation.", ["add_blank", "add_group", "duplicate", "rename", "delete", "add_mask", "remove_mask", "place"]),
                    "layer_id": string("Layer UUID for operations on an existing layer."),
                    "name": string("Name for a created or renamed layer."),
                    "reveal": ["type": "boolean", "description": "For add_mask, true makes a reveal-all mask and false a hide-all mask."],
                    "parent_id": string("For place, destination folder UUID. Omit to move to the document root."),
                    "above_layer_id": string("For place, sibling layer that the moved layer should sit above.")
                ], required: ["action"]), destructive: true),
            tool("compositor_update_layer", "Update the name, visibility, appearance, or transform of one layer.", schema(
                properties: [
                    "layer_id": string("Layer UUID from compositor_get_document."),
                    "name": string("New layer name."),
                    "visible": ["type": "boolean"],
                    "opacity": number("Opacity from 0 to 1.", minimum: 0, maximum: 1),
                    "blend_mode": enumString("Compositor blend mode.", LayerBlendMode.allCases.map(\.rawValue)),
                    "x": number("Layer origin x in document pixels."), "y": number("Layer origin y in document pixels."),
                    "width": number("Layer width in document pixels.", minimum: 1, maximum: 300_000),
                    "height": number("Layer height in document pixels.", minimum: 1, maximum: 300_000),
                    "rotation": number("Clockwise rotation in degrees."),
                    "flip_x": ["type": "boolean"], "flip_y": ["type": "boolean"]
                ], required: ["layer_id"]), destructive: true),
            tool("compositor_select_layer", "Make one layer the active layer in the current document.", schema(
                properties: ["layer_id": string("Layer UUID from compositor_get_document.")], required: ["layer_id"]),
                 destructive: false, idempotent: true),
            tool("compositor_apply_filter", "Apply a filter to the active raster layer or a specified layer, using Compositor's filter pipeline and one undo step.", schema(
                properties: [
                    "kind": enumString("Filter kind.", ["gaussian_blur", "motion_blur", "progressive_blur", "add_noise", "vignette", "bloom_glow", "dither", "scanlines", "tonal_contrast", "lens_correction", "camera_raw", "remove_background", "content_aware_fill", "curves", "exposure", "gradient_map", "grain", "black_white", "color_balance"]),
                    "layer_id": string("Optional target layer UUID."),
                    "settings": ["type": "object", "description": "Optional FilterSettings fields in camelCase; unspecified fields retain defaults.", "additionalProperties": true],
                    "start_x": number("Progressive Blur start x in document pixels."), "start_y": number("Progressive Blur start y."),
                    "end_x": number("Progressive Blur end x in document pixels."), "end_y": number("Progressive Blur end y.")
                ], required: ["kind"]), destructive: true),
            tool("compositor_get_filter_settings", "Inspect the complete default or most recently used filter settings object, including nested fields accepted by compositor_apply_filter.", schema(
                properties: [
                    "kind": enumString("Filter kind to describe.", ["gaussian_blur", "motion_blur", "progressive_blur", "add_noise", "vignette", "bloom_glow", "dither", "scanlines", "tonal_contrast", "lens_correction", "camera_raw", "remove_background", "content_aware_fill", "curves", "exposure", "gradient_map", "grain", "black_white", "color_balance"]),
                    "source": enumString("Return defaults or the editor's current filter settings; defaults to default.", ["default", "current"])
                ], required: ["kind"]), readOnly: true, destructive: false, idempotent: true),
            tool("compositor_manage_adjustment", "Create or update an editable adjustment layer and its complete settings.", schema(
                properties: [
                    "action": enumString("Add or update an adjustment layer.", ["add", "update"]),
                    "kind": enumString("Required when adding a layer.", ["hue_saturation", "levels", "curves", "exposure", "gradient_map", "grain", "add_noise", "gaussian_blur", "motion_blur", "invert", "black_white", "color_balance"]),
                    "layer_id": string("Adjustment layer UUID required when updating."),
                    "name": string("Optional name for a new adjustment layer."),
                    "settings": ["type": "object", "description": "LayerAdjustment fields in camelCase; unspecified fields retain current values.", "additionalProperties": true]
                ], required: ["action"]), destructive: true),
            tool("compositor_manage_layer_effect", "Set, remove, or clear non-destructive effects on a pixel layer.", schema(
                properties: [
                    "action": enumString("Effect operation.", ["set", "remove", "clear_all"]),
                    "layer_id": string("Target layer UUID."),
                    "kind": enumString("Effect kind for set or remove.", ["stroke", "drop_shadow", "color_overlay", "inner_shadow", "outer_glow", "inner_glow"]),
                    "enabled": ["type": "boolean"], "color": string("Effect color as #RRGGBB."),
                    "opacity": number("Effect opacity from 0 to 1.", minimum: 0, maximum: 1),
                    "size": number("Stroke or glow size in layer pixels.", minimum: 0, maximum: 5_000),
                    "angle": number("Shadow angle in degrees."), "distance": number("Shadow distance in layer pixels.", minimum: 0, maximum: 5_000),
                    "blur": number("Shadow blur in layer pixels.", minimum: 0, maximum: 5_000),
                    "inside": ["type": "boolean", "description": "Place a stroke inside the layer outline."]
                ], required: ["action", "layer_id"]), destructive: true),
            tool("compositor_open_document", "Open an existing local .comp project in Compositor.", schema(
                properties: ["path": string("Absolute local path to a .comp project.")], required: ["path"]), destructive: false),
            tool("compositor_import_files", "Import local images as new layers into the current document.", schema(
                properties: [
                    "paths": ["type": "array", "minItems": 1, "maxItems": 100, "items": ["type": "string"], "description": "Absolute local image paths."],
                    "x": number("Optional document-space placement x."), "y": number("Optional document-space placement y.")
                ], required: ["paths"]), destructive: true),
            tool("compositor_export_document", "Export the current visible canvas to a local image or PDF file; existing files require overwrite true.", schema(
                properties: [
                    "path": string("Absolute output path with an extension matching format."),
                    "format": enumString("Output format.", ["png", "jpeg", "tiff", "pdf", "exr"]),
                    "overwrite": ["type": "boolean", "description": "Replace an existing file when true; defaults to false."],
                    "width": integer("Optional output width in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "height": integer("Optional output height in pixels.", minimum: 1, maximum: DocumentLimits.maxSide),
                    "sixteen_bit": ["type": "boolean", "description": "Use 16-bit PNG or TIFF output."],
                    "quality": number("JPEG quality from 0 to 1.", minimum: 0, maximum: 1),
                    "background": string("JPEG or PDF background color as #RRGGBB.")
                ], required: ["path", "format"]), destructive: true),
            tool("compositor_edit_channel", "Load a color or alpha channel as a selection, or fill one channel of an 8-bit raster layer.", schema(
                properties: [
                    "action": enumString("Channel operation.", ["load_selection", "fill"]),
                    "channel": enumString("Color or alpha component.", ["rgb", "red", "green", "blue", "alpha"]),
                    "layer_id": string("Optional target layer UUID."),
                    "source": enumString("Selection source: active layer or visible composite.", ["active_layer", "composite"]),
                    "threshold": integer("Selection threshold from 0 to 255; defaults to 128.", minimum: 0, maximum: 255),
                    "inverted": ["type": "boolean", "description": "Select values below the threshold."],
                    "mode": enumString("Combine the channel selection with the current selection.", ["replace", "add", "subtract"]),
                    "value": number("Fill value from 0 to 1.", minimum: 0, maximum: 1)
                ], required: ["action", "channel"]), destructive: true),
            tool("compositor_history", "Undo or redo one Compositor document edit.", schema(
                properties: ["action": enumString("History direction.", ["undo", "redo"])], required: ["action"]),
                 destructive: true),
            tool("compositor_save_document", "Save the current document to its existing .comp project. Unsaved documents require the user to choose a location in Compositor first.", schema(),
                 destructive: false, idempotent: true),
            tool("compositor_render_document", "Render the current canvas as a PNG image for visual inspection.", schema(
                properties: ["max_size": integer("Maximum width or height of the returned preview. Defaults to 2048; previews are also capped at 16 megapixels.", minimum: 64, maximum: 8_192)]),
                 readOnly: true, destructive: false, idempotent: true)
        ]
    }()

    func call(name: String, arguments: [String: Any]) async -> [String: Any] {
        do {
            switch name {
            case "compositor_get_document": return try result(documentSummary(arguments))
            case "compositor_create_document": return try createDocument(arguments)
            case "compositor_add_shape": return try addShape(arguments)
            case "compositor_add_text": return try addText(arguments)
            case "compositor_add_vector_path": return try addVectorPath(arguments)
            case "compositor_update_vector_path": return try updateVectorPath(arguments)
            case "compositor_apply_vector_path": return try applyVectorPath(arguments)
            case "compositor_update_shape": return try updateShape(arguments)
            case "compositor_update_text": return try updateText(arguments)
            case "compositor_set_selection": return try await setSelection(arguments)
            case "compositor_paint_stroke": return try paintStroke(arguments)
            case "compositor_apply_gradient": return try await applyGradient(arguments)
            case "compositor_manage_mask": return try await manageMask(arguments)
            case "compositor_crop": return try await crop(arguments)
            case "compositor_sample_color": return try sampleColor(arguments)
            case "compositor_set_view": return try setView(arguments)
            case "compositor_manage_layer": return try manageLayer(arguments)
            case "compositor_update_layer": return try updateLayer(arguments)
            case "compositor_select_layer": return try selectLayer(arguments)
            case "compositor_apply_filter": return try await applyFilter(arguments)
            case "compositor_get_filter_settings": return try filterSettingsDescription(arguments)
            case "compositor_manage_adjustment": return try manageAdjustment(arguments)
            case "compositor_manage_layer_effect": return try manageLayerEffect(arguments)
            case "compositor_open_document": return try await openDocument(arguments)
            case "compositor_import_files": return try await importFiles(arguments)
            case "compositor_export_document": return try await exportDocument(arguments)
            case "compositor_edit_channel": return try await editChannel(arguments)
            case "compositor_history": return try history(arguments)
            case "compositor_save_document": return try await saveDocument()
            case "compositor_render_document": return try await renderDocument(arguments)
            default: throw MCPToolFailure(message: "Unknown tool: \(name)")
            }
        } catch {
            return failure(error.localizedDescription)
        }
    }

    private func createDocument(_ arguments: [String: Any]) throws -> [String: Any] {
        guard workspace.canSwitch else { throw MCPToolFailure(message: "Compositor is busy with another edit or dialog.") }
        let width = try arguments.requiredInteger("width", range: 1...DocumentLimits.maxSide)
        let height = try arguments.requiredInteger("height", range: 1...DocumentLimits.maxSide)
        guard width <= DocumentLimits.maxSurfacePixels / height else {
            throw MCPToolFailure(message: "The canvas can cover at most \(DocumentLimits.maxSurfaceMegapixels) megapixels.")
        }
        let resolution = try arguments.optionalNumber("resolution") ?? 72
        guard (1...9_600).contains(resolution) else { throw MCPToolFailure(message: "resolution must be between 1 and 9600.") }
        let background: CGColor?
        if let value = try arguments.optionalString("background"), value.lowercased() != "transparent" {
            guard let color = PaletteColor(hex: value) else { throw MCPToolFailure(message: "background must be transparent or a color such as #3366FF.") }
            background = CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        } else { background = nil }
        let tab = workspace.addTab(reuseEmpty: true)
        tab.session.createNewProject(width: width, height: height, resolution: resolution, background: background)
        guard tab.session.document != nil else { throw MCPToolFailure(message: "The canvas could not be created.") }
        return try result(documentSummary())
    }

    private func addVectorPath(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = workspace.current.session
        guard session.document != nil else { throw MCPToolFailure(message: "Create or open a document first.") }
        guard session.canEditLayers, session.penDraft == nil else {
            throw MCPToolFailure(message: "Finish the current canvas edit before adding a vector path.")
        }
        guard let modeName = try arguments.optionalString("mode"), let mode = PenMode(rawValue: modeName.capitalized) else {
            throw MCPToolFailure(message: "mode must be shape or line.")
        }
        guard let rawNodes = arguments["nodes"] as? [[String: Any]], rawNodes.count <= 10_000 else {
            throw MCPToolFailure(message: "nodes must be an array containing at most 10000 points.")
        }
        let minimum = mode == .shape ? 3 : 2
        guard rawNodes.count >= minimum else { throw MCPToolFailure(message: "\(modeName) mode needs at least \(minimum) nodes.") }
        let nodes = try rawNodes.map { node -> VectorPathNode in
            let x = try node.requiredNumber("x"), y = try node.requiredNumber("y")
            let inX = try node.optionalNumber("in_x") ?? x, inY = try node.optionalNumber("in_y") ?? y
            let outX = try node.optionalNumber("out_x") ?? x, outY = try node.optionalNumber("out_y") ?? y
            let pathNode = VectorPathNode(anchor: CGPoint(x: x, y: y),
                                          inHandle: CGPoint(x: inX, y: inY),
                                          outHandle: CGPoint(x: outX, y: outY))
            guard pathNode.isFinite else { throw MCPToolFailure(message: "Every node coordinate must be finite.") }
            return pathNode
        }
        let color: PaletteColor
        if let value = try arguments.optionalString("color") {
            guard let parsed = PaletteColor(hex: value) else { throw MCPToolFailure(message: "color must look like #3366FF.") }
            color = parsed
        } else { color = PaletteColor(red: 0, green: 0, blue: 0) }
        let lineWidth = try arguments.optionalNumber("line_width") ?? 4
        guard (1...5_000).contains(lineWidth) else { throw MCPToolFailure(message: "line_width must be between 1 and 5000.") }
        let closed = try arguments.optionalBoolean("closed") ?? (mode == .shape)
        guard closed == (mode == .shape) else {
            throw MCPToolFailure(message: mode == .shape ? "Shape paths must be closed." : "Line paths must remain open.")
        }
        session.penDraft = PenDraft(mode: mode, color: color, lineWidth: lineWidth, nodes: nodes, hoverPoint: nil)
        guard session.finishPen(), let layer = session.activeLayer else {
            session.penDraft = nil
            throw MCPToolFailure(message: session.brushError ?? "The vector path could not be created.")
        }
        return try result(["layer": layerSummary(layer), "document_id": session.document!.id.uuidString])
    }

    private func updateLayer(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = workspace.current.session
        guard session.canEditLayers else { throw MCPToolFailure(message: "Compositor is busy with another edit or dialog.") }
        let id = try arguments.requiredUUID("layer_id")
        guard let index = session.document?.layers.firstIndex(where: { $0.id == id }), var layer = session.document?.layers[index] else {
            throw MCPToolFailure(message: "No layer has id \(id.uuidString).")
        }
        var changed = false
        if arguments.keys.contains("name") {
            let name = try arguments.requiredString("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw MCPToolFailure(message: "name cannot be empty.") }
            layer.name = name; changed = true
        }
        if arguments.keys.contains("visible") { layer.isVisible = try arguments.requiredBoolean("visible"); changed = true }
        if arguments.keys.contains("opacity") {
            let opacity = try arguments.requiredNumber("opacity")
            guard (0...1).contains(opacity) else { throw MCPToolFailure(message: "opacity must be between 0 and 1.") }
            layer.opacity = opacity; changed = true
        }
        if arguments.keys.contains("blend_mode") {
            let name = try arguments.requiredString("blend_mode")
            guard let mode = LayerBlendMode.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw MCPToolFailure(message: "Unknown blend_mode: \(name).")
            }
            layer.blendMode = mode; changed = true
        }
        var transform = layer.transform
        if arguments.keys.contains("x") { transform.origin.x = try arguments.requiredNumber("x"); changed = true }
        if arguments.keys.contains("y") { transform.origin.y = try arguments.requiredNumber("y"); changed = true }
        if arguments.keys.contains("width") { transform.size.width = try arguments.requiredNumber("width"); changed = true }
        if arguments.keys.contains("height") { transform.size.height = try arguments.requiredNumber("height"); changed = true }
        if arguments.keys.contains("rotation") { transform.rotation = try arguments.requiredNumber("rotation"); changed = true }
        if arguments.keys.contains("flip_x") { transform.flipX = try arguments.requiredBoolean("flip_x"); changed = true }
        if arguments.keys.contains("flip_y") { transform.flipY = try arguments.requiredBoolean("flip_y"); changed = true }
        guard transform.isValid else { throw MCPToolFailure(message: "The requested layer transform is outside Compositor's limits.") }
        layer.transform = transform
        guard changed else { throw MCPToolFailure(message: "No layer properties were supplied.") }
        session.finishOpacityEdit()
        session.beginEdit("MCP Update Layer")
        session.document?.layers[index] = layer
        session.activeLayerID = id
        session.endEdit()
        return try result(["layer": layerSummary(layer)])
    }

    private func selectLayer(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = workspace.current.session
        guard session.canEditLayers else { throw MCPToolFailure(message: "Compositor is busy with another edit or dialog.") }
        let id = try arguments.requiredUUID("layer_id")
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else {
            throw MCPToolFailure(message: "No layer has id \(id.uuidString).")
        }
        session.selectLayer(id)
        guard session.activeLayerID == id else { throw MCPToolFailure(message: "The layer could not be selected while another edit is active.") }
        return try result(["layer": layerSummary(layer)])
    }

    private func history(_ arguments: [String: Any]) throws -> [String: Any] {
        let action = try arguments.requiredString("action").lowercased()
        let session = workspace.current.session
        switch action {
        case "undo":
            guard session.canUndo else { throw MCPToolFailure(message: "There is no edit available to undo.") }
            session.undo()
        case "redo":
            guard session.canRedo else { throw MCPToolFailure(message: "There is no edit available to redo.") }
            session.redo()
        default: throw MCPToolFailure(message: "action must be undo or redo.")
        }
        return try result(documentSummary())
    }

    private func saveDocument() async throws -> [String: Any] {
        let tab = workspace.current
        guard let url = tab.session.projectURL else {
            throw MCPToolFailure(message: "This document has no project location yet. Save it once in Compositor, then call this tool again.")
        }
        guard await tab.controller.save() else { throw MCPToolFailure(message: "Compositor could not save the project.") }
        return try result(["saved": true, "project_path": url.path])
    }

    private func renderDocument(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let snapshot = workspace.current.session.projectSnapshot() else {
            throw MCPToolFailure(message: "Create or open a document first.")
        }
        let maxSize = try arguments.optionalInteger("max_size", range: 64...8_192) ?? 2_048
        let preview = try await ImageExporter.shared.pngPreview(snapshot, maximumDimension: maxSize,
                                                                 maximumPixels: Self.previewPixelLimit)
        return [
            "content": [
                ["type": "text", "text": "Rendered \(preview.width) × \(preview.height) PNG preview."],
                ["type": "image", "data": preview.base64, "mimeType": "image/png"]
            ],
            "structuredContent": ["width": preview.width, "height": preview.height, "mime_type": "image/png"],
            "isError": false
        ]
    }

    func documentSummary(_ arguments: [String: Any] = [:]) throws -> [String: Any] {
        let tab = workspace.current
        guard let document = tab.session.document else { throw MCPToolFailure(message: "No document is open.") }
        let offset = try arguments.optionalInteger("layer_offset", range: 0...10_000) ?? 0
        let limit = try arguments.optionalInteger("layer_limit", range: 1...2_000) ?? 500
        let end = min(document.layers.count, offset + limit)
        let page = offset < end ? document.layers[offset..<end] : document.layers[0..<0]
        var remainingNodes = Self.documentVectorNodeLimit
        var remainingText = Self.documentTextCharacterLimit
        var remainingTextRuns = Self.documentTextStyleRunLimit
        let layers = page.map { layer in
            let nodeCount = layer.liveVectorPath?.style.nodes.count ?? 0
            let nodeLimit = min(remainingNodes, nodeCount)
            remainingNodes -= nodeLimit
            let textCount = layer.liveText?.style.content.count ?? 0
            let textLimit = min(remainingText, textCount)
            remainingText -= textLimit
            let runCount = (layer.liveText?.style.colorRuns?.count ?? 0) + (layer.liveText?.style.fontRuns?.count ?? 0)
            let runLimit = min(remainingTextRuns, runCount)
            remainingTextRuns -= runLimit
            return layerSummary(layer, vectorNodeLimit: nodeLimit, textCharacterLimit: textLimit,
                                textStyleRunLimit: runLimit)
        }
        var summary: [String: Any] = [
            "document_id": document.id.uuidString,
            "tab_name": tab.title,
            "width": document.width,
            "height": document.height,
            "resolution": document.resolution,
            "modified": tab.session.isModified,
            "active_tool": tab.session.tool.rawValue,
            "active_layer_id": tab.session.activeLayerID?.uuidString ?? NSNull(),
            "layer_order": "bottom_to_top",
            "layer_count": document.layers.count,
            "layer_offset": offset,
            "layers_truncated": offset > 0 || end < document.layers.count,
            "layers": layers,
            "viewport": [
                "zoom": tab.session.viewport.zoom,
                "pan_x": tab.session.viewport.pan.width,
                "pan_y": tab.session.viewport.pan.height,
                "follows_fit": tab.session.viewport.followsFit
            ]
        ]
        if let selection = document.selection {
            if selection.isEmpty {
                summary["selection"] = ["empty": true, "antialiased": selection.antialiased,
                                        "feather": selection.feather] as [String: Any]
            } else {
                let bounds = selection.path.boundingBoxOfPath
                summary["selection"] = ["empty": false, "x": bounds.minX, "y": bounds.minY,
                                        "width": bounds.width, "height": bounds.height,
                                        "antialiased": selection.antialiased,
                                        "feather": selection.feather] as [String: Any]
            }
        } else { summary["selection"] = NSNull() }
        if let url = tab.session.projectURL { summary["project_path"] = url.path }
        return summary
    }

    func layerSummary(_ layer: ImageLayer, vectorNodeLimit: Int? = nil,
                      textCharacterLimit: Int? = nil, textStyleRunLimit: Int? = nil) -> [String: Any] {
        var summary: [String: Any] = [
            "id": layer.id.uuidString,
            "name": layer.name,
            "kind": layerKind(layer),
            "visible": layer.isVisible,
            "opacity": layer.opacity,
            "blend_mode": layer.blendMode.rawValue,
            "parent_id": layer.parentID?.uuidString ?? NSNull(),
            "has_mask": layer.mask != nil,
            "mask_enabled": layer.mask?.isEnabled ?? NSNull(),
            "mask_source_id": layer.maskSourceID?.uuidString ?? NSNull(),
            "mask": maskSummary(layer),
            "transform": [
                "x": layer.transform.origin.x, "y": layer.transform.origin.y,
                "width": layer.transform.size.width, "height": layer.transform.size.height,
                "rotation": layer.transform.rotation,
                "flip_x": layer.transform.flipX, "flip_y": layer.transform.flipY
            ]
        ]
        if let vector = layer.liveVectorPath?.style {
            let limit = min(vector.nodes.count, max(0, vectorNodeLimit ?? vector.nodes.count))
            let transform = layer.transform.unitToDocument
            var vectorSummary: [String: Any] = [
                "mode": vector.mode.rawValue.lowercased(), "closed": vector.closed,
                "color": "#" + PaletteColor(red: vector.red, green: vector.green, blue: vector.blue).hex,
                "line_width": vector.lineWidth,
                "coordinate_space": "document_pixels",
                "subpath_starts": vector.subpathStarts ?? [],
                "fill": vector.fill.map { [
                    "color": "#" + PaletteColor(red: $0.red, green: $0.green, blue: $0.blue).hex
                ] as [String: Any] as Any } ?? NSNull(),
                "brush_stroke": vector.brushStroke.map { [
                    "color": "#" + PaletteColor(red: $0.red, green: $0.green, blue: $0.blue).hex,
                    "diameter": $0.diameter, "hardness": $0.hardness, "opacity": $0.opacity
                ] as [String: Any] as Any } ?? NSNull(),
                "erase_strokes": (vector.eraseStrokes ?? []).map { [
                    "point_count": $0.points.count,
                    "diameter_x": $0.diameterX * layer.transform.size.width,
                    "diameter_y": $0.diameterY * layer.transform.size.height
                ] },
                "nodes": vector.nodes.prefix(limit).map {
                    let anchor = $0.anchor.applying(transform)
                    let incoming = $0.inHandle.applying(transform)
                    let outgoing = $0.outHandle.applying(transform)
                    return [
                        "x": anchor.x, "y": anchor.y,
                        "in_x": incoming.x, "in_y": incoming.y,
                        "out_x": outgoing.x, "out_y": outgoing.y
                    ]
                }
            ]
            if limit < vector.nodes.count {
                vectorSummary["node_count"] = vector.nodes.count
                vectorSummary["nodes_truncated"] = true
            }
            summary["vector_path"] = vectorSummary
        }
        if let shape = layer.liveShape?.style {
            summary["shape"] = [
                "kind": shape.kind.rawValue.lowercased(), "color": "#" + shape.color.hex,
                "corner_radius": shape.cornerRadius,
                "smooth_corners": shape.smoothing == true,
                "line_width": shape.lineWidth.map { $0 as Any } ?? NSNull(),
                "start": shape.start.map { ["x": $0.x, "y": $0.y] as [String: Any] as Any } ?? NSNull(),
                "end": shape.end.map { ["x": $0.x, "y": $0.y] as [String: Any] as Any } ?? NSNull()
            ]
        }
        if let text = layer.liveText?.style {
            let limit = min(text.content.count, max(0, textCharacterLimit ?? text.content.count))
            let requestedRunLimit = max(0, textStyleRunLimit ?? Int.max)
            let colorRunLimit = min(text.colorRuns?.count ?? 0, requestedRunLimit)
            let fontRunLimit = min(text.fontRuns?.count ?? 0, requestedRunLimit - colorRunLimit)
            var textSummary: [String: Any] = [
                "content": String(text.content.prefix(limit)), "font_name": text.fontName, "font_size": text.fontSize,
                "color": "#" + PaletteColor(red: text.red, green: text.green, blue: text.blue).hex,
                "alignment": text.alignment.rawValue.lowercased(), "tracking": text.tracking,
                "leading": text.leading,
                "box_width": text.boxSize.map { $0.width as Any } ?? NSNull(),
                "box_height": text.boxSize.map { $0.height as Any } ?? NSNull(),
                "color_runs": (text.colorRuns ?? []).prefix(colorRunLimit).map { [
                    "location": $0.location, "length": $0.length,
                    "color": "#" + PaletteColor(red: $0.red, green: $0.green, blue: $0.blue).hex
                ] },
                "font_runs": (text.fontRuns ?? []).prefix(fontRunLimit).map { [
                    "location": $0.location, "length": $0.length, "font_name": $0.fontName
                ] }
            ]
            if limit < text.content.count {
                textSummary["character_count"] = text.content.count
                textSummary["content_truncated"] = true
            }
            if colorRunLimit < (text.colorRuns?.count ?? 0) {
                textSummary["color_run_count"] = text.colorRuns?.count ?? 0
                textSummary["color_runs_truncated"] = true
            }
            if fontRunLimit < (text.fontRuns?.count ?? 0) {
                textSummary["font_run_count"] = text.fontRuns?.count ?? 0
                textSummary["font_runs_truncated"] = true
            }
            summary["text"] = textSummary
        }
        if let adjustment = layer.adjustment { summary["adjustment"] = encodedJSONObject(adjustment) }
        if let effects = layer.effects { summary["effects"] = encodedJSONObject(effects) }
        if let image = layer.asset?.image {
            summary["raster_size"] = ["width": image.width, "height": image.height]
        }
        return summary
    }

    func encodedJSONObject<T: Encodable>(_ value: T) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return object
    }

    private func maskSummary(_ layer: ImageLayer) -> Any {
        guard let mask = layer.mask else { return NSNull() }
        let transform = layer.maskTransform
        return [
            "enabled": mask.isEnabled,
            "linked": mask.isLinked,
            "follows_layer": mask.placement == nil,
            "pixel_width": mask.asset.image.width,
            "pixel_height": mask.asset.image.height,
            "transform": [
                "x": transform.origin.x, "y": transform.origin.y,
                "width": transform.size.width, "height": transform.size.height,
                "rotation": transform.rotation,
                "flip_x": transform.flipX, "flip_y": transform.flipY
            ]
        ] as [String: Any]
    }

    private func layerKind(_ layer: ImageLayer) -> String {
        if layer.isGroup { return "group" }
        if layer.liveVectorPath != nil { return "vector_path" }
        if layer.liveShape != nil { return "shape" }
        if layer.liveText != nil { return "text" }
        if layer.adjustment != nil { return "adjustment" }
        return layer.asset == nil ? "empty" : "raster"
    }

    func result(_ structured: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: structured, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return [
            "content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]],
            "structuredContent": structured,
            "isError": false
        ]
    }

    private func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    private static func tool(_ name: String, _ description: String, _ inputSchema: [String: Any],
                             readOnly: Bool = false, destructive: Bool, idempotent: Bool = false) -> [String: Any] {
        [
            "name": name, "description": description, "inputSchema": inputSchema,
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": destructive,
                            "idempotentHint": idempotent, "openWorldHint": false]
        ]
    }

    private static func schema(properties: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        var value: [String: Any] = ["type": "object", "properties": properties, "additionalProperties": false]
        if !required.isEmpty { value["required"] = required }
        return value
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }
    private static func enumString(_ description: String, _ values: [String]) -> [String: Any] {
        ["type": "string", "description": description, "enum": values]
    }
    private static func number(_ description: String, minimum: Double? = nil, maximum: Double? = nil) -> [String: Any] {
        var value: [String: Any] = ["type": "number", "description": description]
        if let minimum { value["minimum"] = minimum }
        if let maximum { value["maximum"] = maximum }
        return value
    }
    private static func integer(_ description: String, minimum: Int, maximum: Int) -> [String: Any] {
        ["type": "integer", "description": description, "minimum": minimum, "maximum": maximum]
    }
}

extension Dictionary where Key == String, Value == Any {
    func requiredString(_ key: String) throws -> String {
        guard let value = self[key] as? String else { throw MCPToolFailure(message: "\(key) must be a string.") }
        return value
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = self[key] else { return nil }
        guard let string = value as? String else { throw MCPToolFailure(message: "\(key) must be a string.") }
        return string
    }

    func requiredBoolean(_ key: String) throws -> Bool {
        guard let value = self[key] as? Bool else { throw MCPToolFailure(message: "\(key) must be true or false.") }
        return value
    }

    func optionalBoolean(_ key: String) throws -> Bool? {
        guard let value = self[key] else { return nil }
        guard let boolean = value as? Bool else { throw MCPToolFailure(message: "\(key) must be true or false.") }
        return boolean
    }

    func requiredNumber(_ key: String) throws -> Double {
        guard let value = number(key) else { throw MCPToolFailure(message: "\(key) must be a finite number.") }
        return value
    }

    func optionalNumber(_ key: String) throws -> Double? {
        guard self[key] != nil else { return nil }
        guard let value = number(key) else { throw MCPToolFailure(message: "\(key) must be a finite number.") }
        return value
    }

    func requiredInteger(_ key: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = integer(key), range.contains(value) else {
            throw MCPToolFailure(message: "\(key) must be an integer from \(range.lowerBound) through \(range.upperBound).")
        }
        return value
    }

    func optionalInteger(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard self[key] != nil else { return nil }
        guard let value = integer(key), range.contains(value) else {
            throw MCPToolFailure(message: "\(key) must be an integer from \(range.lowerBound) through \(range.upperBound).")
        }
        return value
    }

    func requiredUUID(_ key: String) throws -> UUID {
        let value = try requiredString(key)
        guard let uuid = UUID(uuidString: value) else { throw MCPToolFailure(message: "\(key) must be a UUID.") }
        return uuid
    }

    private func number(_ key: String) -> Double? {
        guard let number = self[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }

    private func integer(_ key: String) -> Int? {
        guard let value = number(key), value.rounded() == value,
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return Int(value)
    }
}
