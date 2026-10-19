import AppKit

/// Color components exposed to MCP channel operations.
nonisolated enum ImageChannel: String, CaseIterable, Sendable {
    case rgb, red, green, blue, alpha
}

nonisolated private enum ChannelEditingError: LocalizedError {
    case tooLarge
    var errorDescription: String? { "Channel selection exceeds the 50-megapixel or one-million-edge limit." }
}

nonisolated private struct ChannelImageBox: @unchecked Sendable {
    let image: CGImage
}

/// Bounded RGBA channel operations. Color bytes are premultiplied, so changing alpha rescales the color bytes to keep
/// the visible straight color stable rather than introducing dark fringes.
nonisolated enum ChannelPixels {
    static func selectionPath(in image: CGImage, channel: ImageChannel, threshold: UInt8,
                              inverted: Bool) throws -> CGPath? {
        let width = image.width, height = image.height
        guard height > 0, width <= 50_000_000 / height else { throw ChannelEditingError.tooLarge }
        let context = try PixelAdjust.bitmap(width: width, height: height, mask: false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ExportError.render }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        var selected = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bytes + y * context.bytesPerRow + x * 4
                let level: UInt8
                switch channel {
                case .rgb:
                    let red = Int(pixel[0]) * 54
                    let green = Int(pixel[1]) * 183
                    let blue = Int(pixel[2]) * 19
                    level = UInt8((red + green + blue) >> 8)
                case .red: level = pixel[0]
                case .green: level = pixel[1]
                case .blue: level = pixel[2]
                case .alpha: level = pixel[3]
                }
                selected[y * width + x] = (inverted ? level < threshold : level >= threshold) ? 1 : 0
            }
        }
        return try tracedPath(width: width, height: height) { x, y in
            selected[y * width + x] != 0
        }
    }

    static func replacing(_ image: CGImage, channel: ImageChannel, with value: CGFloat,
                          selection: SelectionClip?, pixelToDocument: CGAffineTransform) throws -> CGImage {
        let width = image.width, height = image.height
        let context = try PixelAdjust.bitmap(width: width, height: height, mask: false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ExportError.render }
        var coverageContext: CGContext?
        if let selection {
            let coverage = try PixelAdjust.coverage(selection, width: width, height: height,
                                                    pixelToDocument: pixelToDocument)
            let mask = try PixelAdjust.bitmap(width: width, height: height, mask: true)
            mask.draw(coverage, in: CGRect(x: 0, y: 0, width: width, height: height))
            coverageContext = mask
        }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let coverage = coverageContext?.data?.assumingMemoryBound(to: UInt8.self)
        let coverageRowBytes = coverageContext?.bytesPerRow ?? 0
        let target = min(255, max(0, Int((value * 255).rounded())))
        func mix(_ original: Int, _ changed: Int, _ amount: Int) -> UInt8 {
            UInt8(min(255, max(0, original + (changed - original) * amount / 255)))
        }
        for y in 0..<height {
            for x in 0..<width {
                let amount: Int
                if let coverage { amount = Int(coverage[y * coverageRowBytes + x]) }
                else { amount = 255 }
                guard amount > 0 else { continue }
                let pixel = pixels + y * context.bytesPerRow + x * 4
                let alpha = Int(pixel[3])
                switch channel {
                case .rgb:
                    let changed = target * alpha / 255
                    pixel[0] = mix(Int(pixel[0]), changed, amount)
                    pixel[1] = mix(Int(pixel[1]), changed, amount)
                    pixel[2] = mix(Int(pixel[2]), changed, amount)
                case .red, .green, .blue:
                    let index = channel == .red ? 0 : channel == .green ? 1 : 2
                    pixel[index] = mix(Int(pixel[index]), target * alpha / 255, amount)
                case .alpha:
                    let changedAlpha = target
                    for index in 0..<3 {
                        let changed = alpha > 0 ? Int(pixel[index]) * changedAlpha / alpha : 0
                        pixel[index] = mix(Int(pixel[index]), changed, amount)
                    }
                    pixel[3] = mix(alpha, changedAlpha, amount)
                }
            }
        }
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }

    private static func tracedPath(width: Int, height: Int,
                                   selected: (Int, Int) -> Bool) throws -> CGPath? {
        let stride = width + 1
        var outgoing: [Int: [Int]] = [:]
        var edgeCount = 0
        func isSelected(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && selected(x, y)
        }
        func edge(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
            outgoing[y0 * stride + x0, default: []].append(y1 * stride + x1)
            edgeCount += 1
        }
        for y in 0..<height {
            for x in 0..<width where isSelected(x, y) {
                if !isSelected(x, y - 1) { edge(x, y, x + 1, y) }
                if !isSelected(x + 1, y) { edge(x + 1, y, x + 1, y + 1) }
                if !isSelected(x, y + 1) { edge(x + 1, y + 1, x, y + 1) }
                if !isSelected(x - 1, y) { edge(x, y + 1, x, y) }
                if edgeCount > 1_000_000 { throw ChannelEditingError.tooLarge }
            }
        }
        guard !outgoing.isEmpty else { return nil }
        let path = CGMutablePath()
        while let start = outgoing.keys.first {
            var loop: [Int] = []
            var current = start
            repeat {
                guard var ends = outgoing[current], let end = ends.popLast() else { break }
                outgoing[current] = ends.isEmpty ? nil : ends
                loop.append(current)
                current = end
            } while current != start
            guard loop.count >= 3 else { continue }
            var corners: [CGPoint] = []
            for (index, vertex) in loop.enumerated() {
                let previous = loop[(index + loop.count - 1) % loop.count]
                let following = loop[(index + 1) % loop.count]
                let incoming = (vertex % stride - previous % stride, vertex / stride - previous / stride)
                let outgoing = (following % stride - vertex % stride, following / stride - vertex / stride)
                if incoming.0 != outgoing.0 || incoming.1 != outgoing.1 {
                    corners.append(CGPoint(x: vertex % stride, y: vertex / stride))
                }
            }
            guard corners.count >= 3 else { continue }
            path.addLines(between: corners)
            path.closeSubpath()
        }
        return path.isEmpty ? nil : path
    }
}

extension EditorSession {
    /// Replaces one raster component, optionally through the current selection, without changing placement, masks, or
    /// effects. Editable text, shapes, and paths become ordinary pixels because their raster content was changed.
    @discardableResult
    func replaceChannel(_ channel: ImageChannel, with value: CGFloat, on layerID: UUID) async -> Bool {
        guard canEditLayers, value.isFinite, (0...1).contains(value), let document,
              let index = document.layers.firstIndex(where: { $0.id == layerID }) else { return false }
        let layer = document.layers[index]
        guard let asset = layer.asset, !layer.isGroup, asset.deep == nil else { return false }
        let source = asset.image
        let documentID = document.id
        let revision = history.currentRevision
        let clip: SelectionClip?
        do { clip = try selection?.clip(canvas: document.size) }
        catch { brushError = error.localizedDescription; return false }
        let mapping = BrushRaster.pixelToDocument(layer.transform, width: source.width, height: source.height)
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                ChannelImageBox(image: try ChannelPixels.replacing(source, channel: channel, with: value,
                                                                    selection: clip, pixelToDocument: mapping))
            }.value.image
            let replacement = ImportedImage(image: result, thumbnail: try PixelAdjust.thumbnail(of: result), name: asset.name)
            guard self.document?.id == documentID, history.currentRevision == revision,
                  let layers = self.document?.layers, layers.indices.contains(index) else { return false }
            let current = layers[index]
            guard current.id == layerID,
                  current.asset?.image === source else { return false }
            var updated = current
            updated.asset = replacement
            updated.shape = nil
            updated.vectorPath = nil
            updated.text = nil
            finishOpacityEdit()
            beginEdit("Edit \(channel.rawValue.uppercased()) Channel")
            self.document?.layers[index] = updated
            activeLayerID = layerID
            endEdit()
            brushRevision += 1
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }
}
