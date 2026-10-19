import AppKit
import Foundation

nonisolated private struct MCPChannelPathBox: @unchecked Sendable {
    let path: CGPath?
}

/// Model-facing access to Compositor's non-tool-rail editing commands and local file workflows.
@MainActor
extension MCPToolRouter {
    func filterSettingsDescription(_ arguments: [String: Any]) throws -> [String: Any] {
        let kindName = try arguments.requiredString("kind")
        guard let kind = filterKind(kindName) else {
            throw MCPToolFailure(message: "Unknown filter kind: \(kindName).")
        }
        let source = try arguments.optionalString("source") ?? "default"
        let settings: FilterSettings
        switch source {
        case "default": settings = FilterSettings()
        case "current": settings = workspace.current.session.filterSettings
        default: throw MCPToolFailure(message: "source must be default or current.")
        }
        return try result([
            "kind": filterIdentifier(kind), "source": source,
            "settings": encodedJSONObject(settings),
            "note": "FilterSettings is shared by all filters; compositor_apply_filter reads fields relevant to the selected kind."
        ])
    }

    func applyFilter(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try editableSession()
        if let id = try arguments.optionalUUID("layer_id") { try select(id, in: session) }
        let kindName = try arguments.requiredString("kind")
        guard let kind = filterKind(kindName) else {
            throw MCPToolFailure(message: "Unknown filter kind: \(kindName).")
        }
        var settings = FilterSettings()
        if let patch = try arguments.optionalObject("settings") {
            if patch["progressiveStart"] != nil { settings.progressiveStart = .zero }
            if patch["progressiveEnd"] != nil { settings.progressiveEnd = .zero }
            settings = try patched(settings, with: patch, name: "filter settings")
        }
        let startX = try arguments.optionalNumber("start_x"), startY = try arguments.optionalNumber("start_y")
        let endX = try arguments.optionalNumber("end_x"), endY = try arguments.optionalNumber("end_y")
        guard (startX == nil) == (startY == nil), (endX == nil) == (endY == nil) else {
            throw MCPToolFailure(message: "Progressive Blur start and end coordinates must be supplied as x/y pairs.")
        }
        guard [startX, startY, endX, endY].compactMap({ $0 }).allSatisfy({ abs($0) <= Self.maximumCoordinate }) else {
            throw MCPToolFailure(message: "Progressive Blur coordinates are outside the supported canvas range.")
        }
        if let startX, let startY { settings.progressiveStart = CGPoint(x: startX, y: startY) }
        if let endX, let endY { settings.progressiveEnd = CGPoint(x: endX, y: endY) }
        guard [settings.progressiveStart, settings.progressiveEnd].compactMap({ $0 }).allSatisfy({
            $0.x.isFinite && $0.y.isFinite && abs($0.x) <= CGFloat(Self.maximumCoordinate)
                && abs($0.y) <= CGFloat(Self.maximumCoordinate)
        }) else {
            throw MCPToolFailure(message: "Progressive Blur coordinates are outside the supported canvas range.")
        }
        guard settings == settings.normalized else {
            throw MCPToolFailure(message: "One or more filter settings are outside Compositor's supported range.")
        }
        let revision = session.history.currentRevision
        session.brushError = nil
        let previousSettings = session.filterSettings
        session.filterSettings = settings
        session.beginFilter(kind)
        guard let edit = session.filterEdit, edit.kind == kind else {
            session.filterSettings = previousSettings
            throw MCPToolFailure(message: session.brushError ?? "The active layer cannot run this filter.")
        }
        session.updateFilter(settings, preview: kind.isAutomatic)
        await session.commitFilter()
        if session.filterEdit === edit {
            let message = edit.previewError ?? session.brushError ?? "The filter could not be applied."
            session.cancelFilter()
            throw MCPToolFailure(message: message)
        }
        guard let layer = session.activeLayer else { throw MCPToolFailure(message: "The filtered layer is no longer available.") }
        return try result([
            "filter": filterIdentifier(kind),
            "applied": session.history.currentRevision != revision,
            "layer": layerSummary(layer)
        ])
    }

    func manageAdjustment(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try editableSession()
        let action = try arguments.requiredString("action").lowercased()
        let patch = try arguments.optionalObject("settings") ?? [:]
        switch action {
        case "add":
            let name = try arguments.requiredString("kind")
            guard let kind = adjustmentKind(name) else { throw MCPToolFailure(message: "Unknown adjustment kind: \(name).") }
            guard patch["kind"] == nil else { throw MCPToolFailure(message: "settings cannot change an adjustment's kind.") }
            let defaults = adjustmentDefaults(LayerAdjustment(kind: kind), for: patch)
            let value = try patched(defaults, with: patch, name: "adjustment settings")
            guard value.kind == kind, value.isValid else {
                throw MCPToolFailure(message: "The adjustment settings are invalid for \(name).")
            }
            let layerName = try arguments.optionalString("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let layerName, layerName.isEmpty { throw MCPToolFailure(message: "name cannot be empty.") }
            guard let id = session.addAdjustment(value, name: layerName),
                  let layer = session.document?.layers.first(where: { $0.id == id }) else {
                throw MCPToolFailure(message: "The adjustment layer could not be created.")
            }
            return try result(["layer": layerSummary(layer)])
        case "update":
            let id = try arguments.requiredUUID("layer_id")
            try select(id, in: session)
            guard let current = session.activeLayer?.adjustment else {
                throw MCPToolFailure(message: "The target is not an adjustment layer.")
            }
            guard !patch.isEmpty else { throw MCPToolFailure(message: "settings must contain at least one property.") }
            guard patch["kind"] == nil else { throw MCPToolFailure(message: "An adjustment layer's kind cannot be changed.") }
            let defaults = adjustmentDefaults(current, for: patch)
            let value = try patched(defaults, with: patch, name: "adjustment settings")
            guard value.kind == current.kind, value.isValid, session.setAdjustment(id, value: value),
                  let layer = session.document?.layers.first(where: { $0.id == id }) else {
                throw MCPToolFailure(message: "The adjustment settings could not be updated.")
            }
            return try result(["layer": layerSummary(layer)])
        default:
            throw MCPToolFailure(message: "action must be add or update.")
        }
    }

    func manageLayerEffect(_ arguments: [String: Any]) throws -> [String: Any] {
        let session = try editableSession()
        let id = try arguments.requiredUUID("layer_id")
        try select(id, in: session)
        guard let target = session.activeLayer, !target.isGroup, target.asset != nil else {
            throw MCPToolFailure(message: "Layer effects require a non-group pixel layer.")
        }
        let action = try arguments.requiredString("action").lowercased()
        var effects = target.effects ?? LayerEffects()
        if action == "clear_all" {
            session.setEffects(LayerEffects(), on: id, name: "Clear Layer Effects")
        } else {
            let kindName = try arguments.requiredString("kind")
            guard let kind = effectKind(kindName) else { throw MCPToolFailure(message: "Unknown effect kind: \(kindName).") }
            switch action {
            case "remove": effects.remove(kind)
            case "set": try updateEffect(kind, effects: &effects, arguments: arguments)
            default: throw MCPToolFailure(message: "action must be set, remove, or clear_all.")
            }
            guard effects.isValid else { throw MCPToolFailure(message: "One or more layer-effect settings are outside Compositor's limits.") }
            session.setEffects(effects, on: id, name: action == "remove" ? "Remove \(kind.rawValue)" : "Edit \(kind.rawValue)")
        }
        guard let layer = session.document?.layers.first(where: { $0.id == id }) else {
            throw MCPToolFailure(message: "The layer is no longer available.")
        }
        return try result(["layer": layerSummary(layer)])
    }

    func openDocument(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard workspace.canSwitch else { throw MCPToolFailure(message: "Compositor is busy with another edit or dialog.") }
        let url = try fileURL(try arguments.requiredString("path"), key: "path")
        guard url.pathExtension.lowercased() == "comp" else {
            throw MCPToolFailure(message: "compositor_open_document opens .comp projects. Use compositor_import_files for images.")
        }
        try requireReadableFile(url, allowPackage: true)
        guard await workspace.open(url) else { throw MCPToolFailure(message: "Compositor could not open the project.") }
        return try result(documentSummary())
    }

    func importFiles(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = workspace.current.session
        guard session.canStartProjectOperation, !session.isImporting else {
            throw MCPToolFailure(message: "Compositor is busy with another edit or file operation.")
        }
        guard let paths = arguments["paths"] as? [String], (1...100).contains(paths.count) else {
            throw MCPToolFailure(message: "paths must contain between 1 and 100 file paths.")
        }
        let urls = try paths.map { path -> URL in
            let url = try fileURL(path, key: "paths")
            guard url.pathExtension.lowercased() != "comp" else {
                throw MCPToolFailure(message: "Use compositor_open_document to open .comp projects.")
            }
            try requireReadableFile(url)
            return url
        }
        let point: CGPoint?
        let x = try arguments.optionalNumber("x"), y = try arguments.optionalNumber("y")
        guard (x == nil) == (y == nil) else { throw MCPToolFailure(message: "x and y must be supplied together.") }
        guard [x, y].compactMap({ $0 }).allSatisfy({ abs($0) <= Self.maximumCoordinate }) else {
            throw MCPToolFailure(message: "Import placement is outside the supported canvas range.")
        }
        point = x.map { CGPoint(x: $0, y: y!) }
        let before = Set(session.document?.layers.map(\.id) ?? [])
        session.importError = nil
        await session.importImages(urls, at: point)
        let warning = session.importError
        session.importError = nil
        guard let document = session.document else {
            throw MCPToolFailure(message: warning ?? "No file could be imported.")
        }
        let added = document.layers.filter { !before.contains($0.id) }
        guard !added.isEmpty else { throw MCPToolFailure(message: warning ?? "No file could be imported.") }
        var response: [String: Any] = [
            "imported_count": added.count,
            "layers": added.map { layerSummary($0) },
            "document_id": document.id.uuidString
        ]
        if let warning { response["warning"] = warning }
        return try result(response)
    }

    func exportDocument(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let snapshot = workspace.current.session.projectSnapshot() else {
            throw MCPToolFailure(message: "Create or open a document first.")
        }
        let formatName = try arguments.requiredString("format").lowercased()
        guard let format = exportFormat(formatName) else {
            throw MCPToolFailure(message: "format must be png, jpeg, tiff, pdf, or exr.")
        }
        let url = try fileURL(try arguments.requiredString("path"), key: "path")
        try validateExportExtension(url, format: format)
        let overwrite = try arguments.optionalBoolean("overwrite") ?? false
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else { throw MCPToolFailure(message: "The export path is a directory.") }
            guard overwrite else { throw MCPToolFailure(message: "The export file already exists. Pass overwrite: true to replace it.") }
        }
        var parentIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &parentIsDirectory),
              parentIsDirectory.boolValue else { throw MCPToolFailure(message: "The export folder does not exist.") }
        let sixteenBit = try arguments.optionalBoolean("sixteen_bit") ?? false
        guard !sixteenBit || format == .png || format == .tiff else {
            throw MCPToolFailure(message: "sixteen_bit is supported only for PNG and TIFF.")
        }
        if format == .exr, !snapshot.images.values.contains(where: \.isHDR) {
            throw MCPToolFailure(message: "EXR export requires at least one HDR layer.")
        }
        var raster = try await ImageExporter.shared.render(snapshot, sixteenBit: sixteenBit || format == .exr,
                                                            hdr: format == .exr)
        let width = try arguments.optionalInteger("width", range: 1...DocumentLimits.maxSide)
        let height = try arguments.optionalInteger("height", range: 1...DocumentLimits.maxSide)
        if width != nil || height != nil {
            let ratio = Double(raster.image.width) / Double(raster.image.height)
            let outputWidth = width ?? max(1, Int((Double(height!) * ratio).rounded()))
            let outputHeight = height ?? max(1, Int((Double(width!) / ratio).rounded()))
            guard outputWidth <= DocumentLimits.maxSide, outputHeight <= DocumentLimits.maxSide,
                  outputWidth <= DocumentLimits.maxSurfacePixels / outputHeight else {
                throw MCPToolFailure(message: "The requested export size is too large.")
            }
            raster = try await ImageExporter.shared.resized(raster, width: outputWidth, height: outputHeight)
        }
        let data: Data
        switch format {
        case .png: data = try await ImageExporter.shared.pngData(raster)
        case .jpeg:
            let quality = try arguments.optionalNumber("quality") ?? 0.85
            guard (0...1).contains(quality) else { throw MCPToolFailure(message: "quality must be between 0 and 1.") }
            let background = try arguments.optionalString("background").map { try parseColor($0, key: "background") }
                ?? PaletteColor(red: 1, green: 1, blue: 1)
            data = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(
                quality: quality, red: background.red, green: background.green, blue: background.blue)).data
        case .tiff: data = try await ImageExporter.shared.tiffData(raster).data
        case .pdf:
            let background = try arguments.optionalString("background").map { try parseColor($0, key: "background") }
            let color = background.map { CGColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) }
            data = try await ImageExporter.shared.pdfData(raster, background: color)
        case .exr: data = try await ImageExporter.shared.exrData(raster)
        }
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw MCPToolFailure(message: "The export file appeared while rendering and was not overwritten.")
        }
        try await ImageExporter.shared.write(data, to: url)
        return try result([
            "exported": true, "path": url.path, "format": format.rawValue.lowercased(),
            "width": raster.image.width, "height": raster.image.height, "bytes": data.count,
            "sixteen_bit": sixteenBit || format == .exr
        ])
    }

    func editChannel(_ arguments: [String: Any]) async throws -> [String: Any] {
        let session = try editableSession()
        let name = try arguments.requiredString("channel").lowercased()
        guard let channel = ImageChannel(rawValue: name) else {
            throw MCPToolFailure(message: "channel must be rgb, red, green, blue, or alpha.")
        }
        let action = try arguments.requiredString("action").lowercased()
        switch action {
        case "load_selection":
            guard let documentID = session.document?.id else { throw MCPToolFailure(message: "No document is open.") }
            let revision = session.history.currentRevision
            let source = try arguments.optionalString("source")?.lowercased() ?? "active_layer"
            let image: CGImage
            let transform: CGAffineTransform
            var sourceLayerID: UUID?
            if source == "composite" {
                guard arguments["layer_id"] == nil else {
                    throw MCPToolFailure(message: "layer_id cannot be combined with source: composite.")
                }
                guard let snapshot = session.projectSnapshot() else { throw MCPToolFailure(message: "No document is open.") }
                guard snapshot.manifest.width <= 50_000_000 / snapshot.manifest.height else {
                    throw MCPToolFailure(message: "Composite channel selection is limited to 50 megapixels; use active_layer on this canvas.")
                }
                image = try await ImageExporter.shared.render(snapshot).image
                transform = .identity
            } else if source == "active_layer" {
                if let id = try arguments.optionalUUID("layer_id") { try select(id, in: session) }
                guard let layer = session.activeLayer, let asset = layer.asset, !layer.isGroup else {
                    throw MCPToolFailure(message: "The target layer has no raster channels.")
                }
                sourceLayerID = layer.id
                image = asset.image
                transform = BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height)
            } else { throw MCPToolFailure(message: "source must be active_layer or composite.") }
            let threshold = try arguments.optionalInteger("threshold", range: 0...255) ?? 128
            let inverted = try arguments.optionalBoolean("inverted") ?? false
            let path = try await Task.detached(priority: .userInitiated) {
                MCPChannelPathBox(path: try ChannelPixels.selectionPath(in: image, channel: channel,
                                                                        threshold: UInt8(threshold), inverted: inverted))
            }.value.path
            let local = path ?? CGMutablePath()
            var mapping = transform
            guard let documentPath = local.copy(using: &mapping) else {
                throw MCPToolFailure(message: "The channel selection could not be transformed into document coordinates.")
            }
            guard workspace.current.session === session, session.document?.id == documentID,
                  session.history.currentRevision == revision, session.canEditSelection,
                  sourceLayerID == nil || session.activeLayerID == sourceLayerID else {
                throw MCPToolFailure(message: "The document changed while the channel selection was being prepared. Try again.")
            }
            session.applySelection(documentPath, mode: try selectionMode(arguments), name: "Load \(name.uppercased()) Channel Selection")
            return try result(["selection": selectionSummary(session.selection), "channel": name])
        case "fill":
            guard arguments["source"] == nil else {
                throw MCPToolFailure(message: "source applies only to load_selection; fill always edits one layer.")
            }
            if let id = try arguments.optionalUUID("layer_id") { try select(id, in: session) }
            guard let layer = session.activeLayer, let asset = layer.asset, !layer.isGroup else {
                throw MCPToolFailure(message: "The target layer has no editable raster channels.")
            }
            let id = layer.id
            guard asset.deep == nil else {
                throw MCPToolFailure(message: "Direct channel filling is not available on 16-bit or HDR layers because it would discard precision.")
            }
            guard asset.image.height > 0, asset.image.width <= 50_000_000 / asset.image.height else {
                throw MCPToolFailure(message: "Direct channel filling is limited to 50 megapixels.")
            }
            let value = try arguments.requiredNumber("value")
            guard (0...1).contains(value) else { throw MCPToolFailure(message: "value must be between 0 and 1.") }
            session.brushError = nil
            guard await session.replaceChannel(channel, with: value, on: id),
                  let layer = session.document?.layers.first(where: { $0.id == id }) else {
                throw MCPToolFailure(message: session.brushError ?? "The channel could not be edited.")
            }
            return try result(["channel": name, "layer": layerSummary(layer)])
        default:
            throw MCPToolFailure(message: "action must be load_selection or fill.")
        }
    }

    private func updateEffect(_ kind: LayerEffectKind, effects: inout LayerEffects,
                              arguments: [String: Any]) throws {
        let enabled = try arguments.optionalBoolean("enabled")
        let opacity = try arguments.optionalNumber("opacity")
        let color = try arguments.optionalString("color").map { try parseColor($0, key: "color") }
        let size = try arguments.optionalNumber("size")
        let angle = try arguments.optionalNumber("angle")
        let distance = try arguments.optionalNumber("distance")
        let blur = try arguments.optionalNumber("blur")
        let inside = try arguments.optionalBoolean("inside")
        switch kind {
        case .stroke:
            guard angle == nil, distance == nil, blur == nil else { throw MCPToolFailure(message: "Stroke does not use angle, distance, or blur.") }
            var value = effects.stroke ?? StrokeEffect()
            if let enabled { value.enabled = enabled }; if let opacity { value.opacity = opacity }
            if let size { value.size = size }; if let inside { value.inside = inside }
            if let color { value.red = color.red; value.green = color.green; value.blue = color.blue }
            effects.stroke = value
        case .shadow:
            guard size == nil, inside == nil else { throw MCPToolFailure(message: "Drop Shadow does not use size or inside.") }
            var value = effects.shadow ?? ShadowEffect()
            if let enabled { value.enabled = enabled }; if let opacity { value.opacity = opacity }
            if let angle { value.angle = angle }; if let distance { value.distance = distance }; if let blur { value.blur = blur }
            if let color { value.red = color.red; value.green = color.green; value.blue = color.blue }
            effects.shadow = value
        case .colorOverlay:
            guard size == nil, angle == nil, distance == nil, blur == nil, inside == nil else {
                throw MCPToolFailure(message: "Color Overlay uses only color, opacity, and enabled.")
            }
            var value = effects.colorOverlay ?? ColorOverlayEffect()
            if let enabled { value.enabled = enabled }; if let opacity { value.opacity = opacity }
            if let color { value.red = color.red; value.green = color.green; value.blue = color.blue }
            effects.colorOverlay = value
        case .innerShadow:
            guard size == nil, inside == nil else { throw MCPToolFailure(message: "Inner Shadow does not use size or inside.") }
            var value = effects.innerShadow ?? InnerShadowEffect()
            if let enabled { value.enabled = enabled }; if let opacity { value.opacity = opacity }
            if let angle { value.angle = angle }; if let distance { value.distance = distance }; if let blur { value.blur = blur }
            if let color { value.red = color.red; value.green = color.green; value.blue = color.blue }
            effects.innerShadow = value
        case .outerGlow:
            guard angle == nil, distance == nil, blur == nil, inside == nil else { throw MCPToolFailure(message: "Outer Glow uses size instead of angle, distance, or blur.") }
            var value = effects.outerGlow ?? OuterGlowEffect()
            if let enabled { value.enabled = enabled }; if let opacity { value.opacity = opacity }; if let size { value.size = size }
            if let color { value.red = color.red; value.green = color.green; value.blue = color.blue }
            effects.outerGlow = value
        case .innerGlow:
            guard angle == nil, distance == nil, blur == nil, inside == nil else { throw MCPToolFailure(message: "Inner Glow uses size instead of angle, distance, or blur.") }
            var value = effects.innerGlow ?? InnerGlowEffect()
            if let enabled { value.enabled = enabled }; if let opacity { value.opacity = opacity }; if let size { value.size = size }
            if let color { value.red = color.red; value.green = color.green; value.blue = color.blue }
            effects.innerGlow = value
        }
    }

    private func patched<T: Codable>(_ value: T, with patch: [String: Any], name: String) throws -> T {
        guard JSONSerialization.isValidJSONObject(patch) else { throw MCPToolFailure(message: "\(name) must be valid JSON.") }
        let patchData = try JSONSerialization.data(withJSONObject: patch)
        guard patchData.count <= 1_048_576 else { throw MCPToolFailure(message: "\(name) is too large.") }
        let names = Set(Mirror(reflecting: value).children.compactMap(\.label))
        if let unknown = patch.keys.first(where: { !names.contains($0) }) {
            throw MCPToolFailure(message: "Unknown \(name) field: \(unknown).")
        }
        let baseData = try JSONEncoder().encode(value)
        guard var base = try JSONSerialization.jsonObject(with: baseData) as? [String: Any] else {
            throw MCPToolFailure(message: "Compositor could not encode the current \(name).")
        }
        try merge(patch, into: &base, name: name, allowNewKeys: true)
        do { return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: base)) }
        catch { throw MCPToolFailure(message: "Invalid \(name): \(error.localizedDescription)") }
    }

    private func adjustmentDefaults(_ value: LayerAdjustment, for patch: [String: Any]) -> LayerAdjustment {
        var value = value
        if patch["hsvSettings"] != nil, value.hsvSettings == nil { value.hsvSettings = value.resolvedHSV }
        if patch["exposureSettings"] != nil, value.exposureSettings == nil { value.exposure = ExposureSettings() }
        if patch["gradientMapSettings"] != nil, value.gradientMapSettings == nil { value.gradientMap = GradientMapSettings() }
        if patch["grainSettings"] != nil, value.grainSettings == nil { value.grain = GrainSettings() }
        if patch["blackWhiteSettings"] != nil, value.blackWhiteSettings == nil { value.blackWhite = BlackWhiteSettings() }
        if patch["colorBalanceSettings"] != nil, value.colorBalanceSettings == nil { value.colorBalance = ColorBalanceSettings() }
        return value
    }

    private func merge(_ patch: [String: Any], into base: inout [String: Any], name: String,
                       allowNewKeys: Bool = false) throws {
        for (key, value) in patch {
            guard allowNewKeys || base.keys.contains(key) else {
                throw MCPToolFailure(message: "Unknown \(name) field: \(key).")
            }
            if let nested = value as? [String: Any], var current = base[key] as? [String: Any] {
                try merge(nested, into: &current, name: "\(name).\(key)")
                base[key] = current
            } else {
                if base[key] == nil, value is [String: Any] {
                    throw MCPToolFailure(message: "Unknown \(name) field: \(key).")
                }
                base[key] = value
            }
        }
    }

    private func fileURL(_ path: String, key: String) throws -> URL {
        guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else {
            throw MCPToolFailure(message: "\(key) must be an absolute local file path no longer than 4096 bytes.")
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func requireReadableFile(_ url: URL, allowPackage: Bool = false) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              (!isDirectory.boolValue || allowPackage && url.pathExtension.lowercased() == "comp"),
              FileManager.default.isReadableFile(atPath: url.path) else {
            throw MCPToolFailure(message: "The file does not exist or cannot be read: \(url.path)")
        }
    }

    private func filterKind(_ name: String) -> FilterKind? {
        let identifiers: [String: FilterKind] = Dictionary(uniqueKeysWithValues: FilterKind.allCases.map { (filterIdentifier($0), $0) })
        let normalized = identifier(name).replacingOccurrences(of: "_filter", with: "")
        return identifiers[normalized]
    }

    private func filterIdentifier(_ kind: FilterKind) -> String {
        identifier(kind.rawValue).replacingOccurrences(of: "_filter", with: "")
    }

    private func adjustmentKind(_ name: String) -> AdjustmentKind? {
        Dictionary(uniqueKeysWithValues: AdjustmentKind.allCases.map { (identifier($0.rawValue), $0) })[identifier(name)]
    }

    private func effectKind(_ name: String) -> LayerEffectKind? {
        Dictionary(uniqueKeysWithValues: LayerEffectKind.allCases.map { (identifier($0.rawValue), $0) })[identifier(name)]
    }

    private func identifier(_ value: String) -> String {
        value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
    }

    private func exportFormat(_ name: String) -> ExportFormat? {
        switch name { case "png": .png; case "jpg", "jpeg": .jpeg; case "tif", "tiff": .tiff; case "pdf": .pdf; case "exr": .exr; default: nil }
    }

    private func validateExportExtension(_ url: URL, format: ExportFormat) throws {
        let ext = url.pathExtension.lowercased()
        let accepted: Set<String> = switch format {
        case .png: ["png"]
        case .jpeg: ["jpg", "jpeg"]
        case .tiff: ["tif", "tiff"]
        case .pdf: ["pdf"]
        case .exr: ["exr"]
        }
        guard accepted.contains(ext) else {
            throw MCPToolFailure(message: "The export path extension does not match \(format.rawValue).")
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func optionalObject(_ key: String) throws -> [String: Any]? {
        guard let value = self[key] else { return nil }
        guard let object = value as? [String: Any] else { throw MCPToolFailure(message: "\(key) must be an object.") }
        return object
    }
}
