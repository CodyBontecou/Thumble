#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

public struct ThumbleNativeSkinPreviewItem: Sendable {
    public var title: String
    public var customization: GamepadCustomization
    public var colorScheme: ThumbleSkinColorScheme
    public var state: GamepadControlPresentationState
    public var statesByControlID: [String: GamepadControlPresentationState]
    public var safeAreaInsets: ThumbleNormalizedInsets
    public var showsSafeAreaOverlay: Bool
    public var secondaryBindingTexts: [String: String]
    public var showsTouchTargets: Bool
    public var omitsRevealHandle: Bool

    public init(
        title: String,
        customization: GamepadCustomization,
        colorScheme: ThumbleSkinColorScheme,
        state: GamepadControlPresentationState,
        statesByControlID: [String: GamepadControlPresentationState] = [:],
        safeAreaInsets: ThumbleNormalizedInsets = .init(),
        showsSafeAreaOverlay: Bool = false,
        showsTouchTargets: Bool = false,
        secondaryBindingTexts: [String: String] = [:],
        omitsRevealHandle: Bool = false
    ) {
        self.title = title
        self.customization = customization
        self.colorScheme = colorScheme
        self.state = state
        self.statesByControlID = statesByControlID
        self.safeAreaInsets = safeAreaInsets
        self.showsSafeAreaOverlay = showsSafeAreaOverlay
        self.showsTouchTargets = showsTouchTargets
        self.secondaryBindingTexts = secondaryBindingTexts
        self.omitsRevealHandle = omitsRevealHandle
    }
}

public enum ThumbleNativeSkinPreviewError: LocalizedError {
    case invalidScale
    case renderingFailed(String)
    case pngEncodingFailed
    case unknownStateTarget(String)
    case invalidSafeArea

    public var errorDescription: String? {
        switch self {
        case .invalidScale: "Preview scale must be between 0.5 and 4."
        case .renderingFailed(let title): "The native renderer could not draw \(title)."
        case .pngEncodingFailed: "The native renderer could not encode PNG output."
        case .unknownStateTarget(let id): "Mixed-state review target \(id) does not exist in the exact rendered controller."
        case .invalidSafeArea: "Native review safe areas must be finite normalized insets between 0 and 0.45."
        }
    }
}

/// Offscreen SwiftUI renderer shared by the CLI and app previews. Control faces, image fills,
/// artwork layers, typography, effects, and state resolution use the same views as the app.
@MainActor
public enum ThumbleNativeSkinPreviewRenderer {
    public static func writePNG(
        item: ThumbleNativeSkinPreviewItem,
        outputURL: URL,
        scale: CGFloat = 2
    ) throws {
        let data = try pngData(item: item, scale: scale)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: outputURL, options: .atomic)
    }

    public static func pngData(
        item: ThumbleNativeSkinPreviewItem,
        scale: CGFloat = 2
    ) throws -> Data {
        try pngData(render(item: item, scale: scale))
    }

    public static func writeContactSheet(
        items: [ThumbleNativeSkinPreviewItem],
        skinName: String,
        outputURL: URL,
        columns: Int = 4,
        scale: CGFloat = 1
    ) throws {
        guard scale.isFinite, (0.5...4).contains(scale) else {
            throw ThumbleNativeSkinPreviewError.invalidScale
        }
        let snapshots = try items.map { item in
            ThumbleRenderedPreview(title: item.title, image: try render(item: item, scale: 2))
        }
        try writeRasterContactSheet(snapshots: snapshots.map { ($0.title, $0.image) }, skinName: skinName,
            outputURL: outputURL, columns: columns, scale: scale)
    }

    static func writeRasterContactSheet(snapshots input: [(String, CGImage)], skinName: String,
                                       outputURL: URL, columns: Int = 4, scale: CGFloat = 1,
                                       cellSize: CGSize = CGSize(width: 520, height: 390)) throws {
        let snapshots = input.map { ThumbleRenderedPreview(title: $0.0, image: $0.1) }
        let columnCount = max(1, min(columns, max(snapshots.count, 1)))
        let rows = snapshots.chunked(into: columnCount)
        let spacing: CGFloat = 16
        let outer: CGFloat = 24
        let header: CGFloat = 58
        let width = outer * 2 + CGFloat(columnCount) * cellSize.width + CGFloat(max(0, columnCount - 1)) * spacing
        let height = outer * 2 + header + CGFloat(rows.count) * cellSize.height + CGFloat(max(0, rows.count - 1)) * spacing
        let view = ThumbleContactSheetView(
            skinName: skinName,
            rows: rows,
            cellSize: cellSize,
            spacing: spacing
        )
        .frame(width: width, height: height)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("contact sheet")
        }
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData(image).write(to: outputURL, options: .atomic)
    }

    /// Expanded native bar drawing, shared with interactive iOS labels and surface styles.
    /// Drawer position, menus, animation and device accessibility adaptations are separate inputs.
    public static func renderControlBar(profile: GamepadConfigurationProfile,
                                        orientation: GamepadEditorDeviceOrientation, colorScheme: ThumbleSkinColorScheme,
                                        isConnected: Bool, isDefault: Bool, isEditing: Bool = false,
                                        scale: CGFloat = 1, customizationOverride: GamepadCustomization? = nil) throws -> CGImage {
        try renderControlBarSnapshot(profile: profile, orientation: orientation, colorScheme: colorScheme,
            isConnected: isConnected, isDefault: isDefault, isEditing: isEditing, scale: scale,
            customizationOverride: customizationOverride).image
    }

    struct ControlBarSnapshot {
        let image: CGImage
        let layout: GamepadNativeBarLayoutEvidence
    }

    static func renderControlBarSnapshot(profile: GamepadConfigurationProfile,
                                        orientation: GamepadEditorDeviceOrientation, colorScheme: ThumbleSkinColorScheme,
                                        isConnected: Bool, isDefault: Bool, isEditing: Bool = false,
                                        scale: CGFloat = 1, customizationOverride: GamepadCustomization? = nil) throws -> ControlBarSnapshot {
        guard scale == 1 || scale == 2 else { throw ThumbleNativeSkinPreviewError.invalidScale }
        let customization = customizationOverride ?? profile.customization(for: orientation)
        let width = customization.deviceCanvas.editorDeviceFrame.screenRect.width
        guard width.isFinite, width > 0, width * scale <= 8192 else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("control bar viewport exceeds budget")
        }
        let collector = GamepadNativeBarLayoutCollector()
        let view = GamepadRenderedControlFace.controlBar(customization: customization, profileName: profile.name,
            isDefault: isDefault, launchTarget: profile.launchTarget, isConnected: isConnected,
            isLandscape: orientation == .landscape, isEditing: isEditing, layoutCollector: collector)
            .environment(\.colorScheme, colorScheme == .dark ? .dark : .light)
            .frame(width: width)
            .coordinateSpace(name: GamepadNativeBarLayoutCollector.coordinateSpace)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = scale
        renderer.isOpaque = false
        let image = try clearedRaster(renderer, scale: scale, title: "control bar")
        guard image.width <= 8192, image.height <= 8192,
              image.width * image.height <= 16 * 1024 * 1024 else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("control bar raster exceeds budget")
        }
        let normalized = customization.normalized
        let visible = GamepadControllerPresentationRouting.visibleControlBarItems(normalized.controlBarItems,
            hiddenItems: Set(normalized.controlBarItems.filter { normalized.controlBarItemCustomization(for: $0).isHidden }),
            hasProfiles: true, hasLaunchTarget: profile.launchTarget != nil)
        let expected = Set(["native-control-bar"] + visible.map { "native-control-bar/" + $0.rawValue }
            + GamepadControllerPresentationRouting.barLeafSurfaceIDs(items: visible, isLandscape: orientation == .landscape,
                customization: normalized))
        guard Set(collector.frames.keys) == expected, collector.frames.values.allSatisfy({ frame in
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                && frame.width >= 0 && frame.height >= 0
        }) else { throw ThumbleNativeSkinPreviewError.renderingFailed("native bar layout measurement incomplete") }
        guard Set(collector.paintItems.keys) == Set(visible.filter { $0 != .spacer }.map { "native-control-bar/" + $0.rawValue }),
              Set(collector.paintIcons.keys) == Set(expected.filter { $0.hasSuffix("/icon") }) else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("native bar paint measurement incomplete")
        }
        return ControlBarSnapshot(image: image, layout: .init(frames: collector.frames,
            viewport: CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale), paint: collector.paint))
    }

    /// Transparent full-canvas settled drawer surface using the live composition.
    /// Caller supplies explicit safe areas and device padding; no window state is queried.
    public static func renderDrawerSurface(profile: GamepadConfigurationProfile,
                                          orientation: GamepadEditorDeviceOrientation, colorScheme: ThumbleSkinColorScheme,
                                          safeAreaInsets: ThumbleNormalizedInsets, minimumPortraitTopInset: CGFloat = 0,
                                          requestedVisibility: Bool, isConnected: Bool, isDefault: Bool,
                                          isEditing: Bool = false, collapsedOpacity: CGFloat = 1,
                                          scale: CGFloat = 1) throws -> CGImage {
        try renderDrawerSnapshot(profile: profile, orientation: orientation, colorScheme: colorScheme,
            safeAreaInsets: safeAreaInsets, minimumPortraitTopInset: minimumPortraitTopInset,
            requestedVisibility: requestedVisibility, isConnected: isConnected, isDefault: isDefault,
            isEditing: isEditing, collapsedOpacity: collapsedOpacity, scale: scale).image
    }

    struct DrawerSnapshot {
        let image: CGImage
        let layout: GamepadNativeBarLayoutEvidence
        let inputs: GamepadTopBarDrawerLayout
        let isVisible: Bool
    }

    static func renderDrawerSnapshot(profile: GamepadConfigurationProfile,
                                    orientation: GamepadEditorDeviceOrientation, colorScheme: ThumbleSkinColorScheme,
                                    safeAreaInsets: ThumbleNormalizedInsets, minimumPortraitTopInset: CGFloat,
                                    requestedVisibility: Bool, isConnected: Bool, isDefault: Bool,
                                    isEditing: Bool, collapsedOpacity: CGFloat, scale: CGFloat,
                                    customizationOverride: GamepadCustomization? = nil) throws -> DrawerSnapshot {
        guard scale == 1 || scale == 2 else { throw ThumbleNativeSkinPreviewError.invalidScale }
        guard minimumPortraitTopInset.isFinite, (0...128).contains(minimumPortraitTopInset),
              collapsedOpacity.isFinite, (0...1).contains(collapsedOpacity) else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("drawer sampling inputs exceed bounds")
        }
        guard [safeAreaInsets.top, safeAreaInsets.leading, safeAreaInsets.bottom, safeAreaInsets.trailing]
            .allSatisfy({ $0.isFinite && (0...0.45).contains($0) }) else { throw ThumbleNativeSkinPreviewError.invalidSafeArea }
        let customization = (customizationOverride ?? profile.customization(for: orientation)).resolvingAssetReferences().normalized
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite,
              size.width * scale <= 8192, size.height * scale <= 8192,
              size.width * size.height * scale * scale <= 16 * 1024 * 1024 else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("drawer canvas exceeds budget")
        }
        let visible = ControllerRuntimeChromePolicy.resolvedTopBarVisibility(requestedVisibility: requestedVisibility,
            isConnected: isConnected, isEditingLayout: isEditing)
        let layout = GamepadTopBarDrawerLayout(safeAreaInsets: EdgeInsets(top: safeAreaInsets.top * size.height,
            leading: safeAreaInsets.leading * size.width, bottom: safeAreaInsets.bottom * size.height,
            trailing: safeAreaInsets.trailing * size.width), isLandscape: orientation == .landscape,
            minimumPortraitTopInset: minimumPortraitTopInset)
        let collector = GamepadNativeBarLayoutCollector()
        let bar = GamepadRenderedControlFace.controlBar(customization: customization, profileName: profile.name,
            isDefault: isDefault, launchTarget: profile.launchTarget, isConnected: isConnected,
            isLandscape: orientation == .landscape, isEditing: isEditing, layoutCollector: collector, showsBarShadow: false)
        let reveal = Button(action: {}) {
            GamepadRenderedControlFace.revealHandle(customization: customization, canvasSize: size,
                state: visible ? .active : .normal).frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).opacity(visible ? 1 : collapsedOpacity)
        let view = GamepadTopBarDrawerSurface(layout: layout, isVisible: visible, content: bar, reveal: AnyView(reveal), layoutCollector: collector)
            .environment(\.colorScheme, colorScheme == .dark ? .dark : .light)
            .frame(width: size.width, height: size.height, alignment: .top).clipped()
            .coordinateSpace(name: GamepadNativeBarLayoutCollector.coordinateSpace)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = scale; renderer.isOpaque = false
        let image = try clearedRaster(renderer, scale: scale, title: "drawer surface")
        let items = GamepadControllerPresentationRouting.visibleControlBarItems(customization.controlBarItems,
            hiddenItems: Set(customization.controlBarItems.filter { customization.controlBarItemCustomization(for: $0).isHidden }),
            hasProfiles: true, hasLaunchTarget: profile.launchTarget != nil)
        let expected = Set(["native-drawer", "native-drawer/reveal"] + (visible
            ? ["native-control-bar"] + items.map { "native-control-bar/" + $0.rawValue }
                + GamepadControllerPresentationRouting.barLeafSurfaceIDs(items: items, isLandscape: orientation == .landscape,
                    customization: customization) : []))
        guard Set(collector.frames.keys) == expected, collector.frames.values.allSatisfy({ frame in
            [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
                && frame.width >= 0 && frame.height >= 0
        }) else { throw ThumbleNativeSkinPreviewError.renderingFailed("native drawer layout measurement incomplete") }
        let expectedPaint = visible ? Set(items.filter { $0 != .spacer }.map { "native-control-bar/" + $0.rawValue }) : Set<String>()
        guard Set(collector.paintItems.keys) == expectedPaint,
              Set(collector.paintIcons.keys) == Set(expected.filter { $0.hasSuffix("/icon") }) else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("native drawer paint measurement incomplete")
        }
        return DrawerSnapshot(image: image, layout: .init(frames: collector.frames,
            viewport: CGRect(origin: .zero, size: size), coordinateDescription: "drawer-scene image", paint: collector.paint),
            inputs: layout, isVisible: visible)
    }

    /// Own and clear the destination so a wholly transparent sample cannot retain
    /// pixels from an earlier SwiftUI render.
    static func clearedRaster<Content: View>(_ renderer: ImageRenderer<Content>, scale: CGFloat,
                                                     title: String) throws -> CGImage {
        var raster: CGImage?
        renderer.render(rasterizationScale: scale) { points, draw in
            guard points.width.isFinite, points.height.isFinite, points.width > 0, points.height > 0,
                  points.width * scale <= 8192, points.height * scale <= 8192 else { return }
            let width = Int(ceil(points.width * scale)), height = Int(ceil(points.height * scale))
            guard width > 0, height > 0, width <= 8192, height <= 8192,
                  width * height <= 16 * 1024 * 1024,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return }
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            draw(context)
            raster = context.makeImage()
        }
        guard let image = raster else { throw ThumbleNativeSkinPreviewError.renderingFailed(title) }
        return image
    }

    static func composite(controller: CGImage, drawer: CGImage) throws -> CGImage {
        guard controller.width == drawer.width, controller.height == drawer.height,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: controller.width, height: controller.height,
                bitsPerComponent: 8, bytesPerRow: controller.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ThumbleNativeSkinPreviewError.renderingFailed("drawer scene raster") }
        let rect = CGRect(x: 0, y: 0, width: controller.width, height: controller.height)
        context.clear(rect); context.draw(controller, in: rect); context.draw(drawer, in: rect)
        guard let image = context.makeImage() else { throw ThumbleNativeSkinPreviewError.renderingFailed("drawer scene") }
        return image
    }

    public static func render(
        item: ThumbleNativeSkinPreviewItem,
        scale: CGFloat = 2
    ) throws -> CGImage {
        guard scale.isFinite, (0.5...4).contains(scale) else {
            throw ThumbleNativeSkinPreviewError.invalidScale
        }
        let customization = item.customization.resolvingAssetReferences().normalized
        let insets = item.safeAreaInsets
        guard [insets.top, insets.leading, insets.bottom, insets.trailing].allSatisfy({ $0.isFinite && (0...0.45).contains($0) }) else {
            throw ThumbleNativeSkinPreviewError.invalidSafeArea
        }
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let controls = customization.resolvedControls(in: size)
        let identities = Set(controls.map { $0.id.id })
        if let unknown = item.statesByControlID.keys.sorted().first(where: { !identities.contains($0) }) {
            throw ThumbleNativeSkinPreviewError.unknownStateTarget(unknown)
        }
        if let unknown = item.secondaryBindingTexts.keys.sorted().first(where: { !identities.contains($0) }) {
            throw ThumbleNativeSkinPreviewError.unknownStateTarget(unknown)
        }
        guard item.secondaryBindingTexts.values.allSatisfy({ $0.unicodeScalars.count <= 512 }) else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("binding hint exceeds text budget")
        }
        let scheme: ColorScheme = item.colorScheme == .dark ? .dark : .light
        let view = ThumbleNativeSkinCanvas(
            customization: customization,
            state: item.state,
            statesByControlID: item.statesByControlID,
            safeAreaInsets: insets,
            showsSafeAreaOverlay: item.showsSafeAreaOverlay,
            showsTouchTargets: item.showsTouchTargets,
            secondaryBindingTexts: item.secondaryBindingTexts,
            omitsRevealHandle: item.omitsRevealHandle
        )
        .environment(\.colorScheme, scheme)
        .frame(width: size.width, height: size.height)
        .clipped()

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.cgImage else {
            throw ThumbleNativeSkinPreviewError.renderingFailed(item.title)
        }
        return image
    }

    /// Renders one surface at a time with sibling paint transparent, retaining
    /// native layout/fitting. Work is bounded to the five native flow surfaces.
    static func surfaceInk(control: GamepadResolvedControl, customization: GamepadCustomization,
                           state: GamepadControlPresentationState, scheme: ColorScheme,
                           canvasSize: CGSize, scale: CGFloat, surfaces: [String], secondaryBindingText: String? = nil) throws -> GamepadNativeSurfaceInkEvidence? {
        guard !surfaces.isEmpty else { return nil }
        let supported: Set<String> = ["legend", "caption", "binding-hint", "icon", "trackpad-cursor"]
        guard surfaces.count <= 5, Set(surfaces).isSubset(of: supported), scale == 1 || scale == 2 else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("surface mask request")
        }
        guard canvasSize.width.isFinite, canvasSize.height.isFinite,
              canvasSize.width > 0, canvasSize.height > 0, canvasSize.width * scale <= 8192, canvasSize.height * scale <= 8192 else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("surface canvas exceeds budget")
        }
        let width = Int(ceil(canvasSize.width * scale)), height = Int(ceil(canvasSize.height * scale))
        guard width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 16 * 1024 * 1024 else {
            throw ThumbleNativeSkinPreviewError.renderingFailed("surface raster exceeds budget")
        }
        var samples: [String: GamepadNativeSurfaceInkEvidence.Sample] = [:]
        for surface in surfaces {
            let collector = GamepadNativeBarLayoutCollector()
            let view = ZStack(alignment: .topLeading) {
                GamepadRenderedControlFace(control: control, customization: customization, state: state,
                    secondaryBindingText: secondaryBindingText, surfaceMask: GamepadControlSurfaceMask(surface: surface, layoutCollector: collector))
                    .rotationEffect(.degrees(control.rotationDegrees))
                    .position(control.center)
            }
            .environment(\.colorScheme, scheme)
            .frame(width: canvasSize.width, height: canvasSize.height)
            .clipped()
            .coordinateSpace(name: GamepadNativeBarLayoutCollector.coordinateSpace)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: canvasSize.width, height: canvasSize.height)
            renderer.scale = scale; renderer.isOpaque = false
            let image = try clearedRaster(renderer, scale: scale, title: surface)
            guard image.width == width, image.height == height else {
                throw ThumbleNativeSkinPreviewError.renderingFailed(surface)
            }
            var bytes = Data(count: width * height * 4)
            let bounds: CGRect? = try bytes.withUnsafeMutableBytes { buffer in
                guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                    throw ThumbleNativeSkinPreviewError.renderingFailed("surface RGBA buffer")
                }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                var minX = width, minY = height, maxX = -1, maxY = -1
                let pixels = buffer.baseAddress!.assumingMemoryBound(to: UInt32.self)
                for y in 0..<height {
                    let row = y * width
                    for x in 0..<width where pixels[row + x].littleEndian & 0xff000000 > 0x01000000 {
                        minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
                return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            }
            guard Set(collector.frames.keys) == [surface], let layout = collector.frames[surface],
                  [layout.minX, layout.minY, layout.width, layout.height].allSatisfy(\.isFinite),
                  layout.width >= 0, layout.height >= 0 else {
                throw ThumbleNativeSkinPreviewError.renderingFailed("native flow layout measurement incomplete: " + surface)
            }
            samples[surface] = .init(pixelBounds: bounds,
                canvasPointBounds: bounds.map { CGRect(x: $0.minX / scale, y: $0.minY / scale,
                    width: $0.width / scale, height: $0.height / scale) }, rgbaSHA256: bytes.thumbleSHA256, nativeLayout: .init(canvasBounds: layout, viewport: CGRect(origin: .zero, size: canvasSize)))
        }
        return GamepadNativeSurfaceInkEvidence(samples: samples, width: width, height: height, scale: scale)
    }

    static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw ThumbleNativeSkinPreviewError.pngEncodingFailed }
        let properties: [CFString: Any] = [
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGInterlaceType: 0
            ]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ThumbleNativeSkinPreviewError.pngEncodingFailed
        }
        return data as Data
    }
}

private struct ThumbleNativeSkinCanvas: View {
    let customization: GamepadCustomization
    let state: GamepadControlPresentationState
    let statesByControlID: [String: GamepadControlPresentationState]
    let safeAreaInsets: ThumbleNormalizedInsets
    let showsSafeAreaOverlay: Bool
    let showsTouchTargets: Bool
    let secondaryBindingTexts: [String: String]
    let omitsRevealHandle: Bool

    var body: some View {
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let controls = customization.resolvedControls(in: size)
        ZStack(alignment: .topLeading) {
            GamepadFillShapeLayer(
                shape: Rectangle(),
                fillStyle: customization.keypadBackgroundFillStyle(scheme: resolvedScheme)
            )
            GamepadArtworkLayersView(layers: customization.artworkLayers, plane: .underlay)
            ForEach(controls.filter { !omitsRevealHandle || $0.id != .system(.topBarActivation) }) { control in
                GamepadRenderedControlFace(
                    control: control,
                    customization: customization,
                    state: statesByControlID[control.id.id] ?? state,
                    secondaryBindingText: secondaryBindingTexts[control.id.id]
                )
                .rotationEffect(.degrees(control.rotationDegrees))
                .position(control.center)
            }
            GamepadArtworkLayersView(layers: customization.artworkLayers, plane: .overlay)
            if showsTouchTargets {
                ForEach(controls.filter { !$0.layoutCustomization.isHidden && !$0.isText && !$0.isDecoration
                    && (!omitsRevealHandle || $0.id != .system(.topBarActivation)) }) { control in
                    Rectangle()
                        .fill(Color(red: 1, green: 0, blue: 1).opacity(0.07))
                        .overlay(Rectangle().stroke(Color(red: 1, green: 0, blue: 1), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                        .frame(width: control.hitFrame.width, height: control.hitFrame.height)
                        .position(x: control.hitFrame.midX, y: control.hitFrame.midY)
                }
            }
            if showsSafeAreaOverlay {
                let safeFrame = CGRect(x: size.width * safeAreaInsets.leading, y: size.height * safeAreaInsets.top,
                                       width: size.width * (1 - safeAreaInsets.leading - safeAreaInsets.trailing),
                                       height: size.height * (1 - safeAreaInsets.top - safeAreaInsets.bottom))
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(safeFrame)
                }
                .fill(Color.orange.opacity(0.18), style: FillStyle(eoFill: true))
                Rectangle().stroke(Color.orange, style: StrokeStyle(lineWidth: 1, dash: [6, 3]))
                    .frame(width: safeFrame.width, height: safeFrame.height)
                    .position(x: safeFrame.midX, y: safeFrame.midY)
            }
        }
        .frame(width: size.width, height: size.height)
        .background(resolvedScheme == .dark ? Color.black : Color.white)
        .accessibilityHidden(true)
    }

    @Environment(\.colorScheme) private var resolvedScheme
}

private struct ThumbleRenderedPreview {
    var title: String
    var image: CGImage
}

private struct ThumbleContactSheetView: View {
    let skinName: String
    let rows: [[ThumbleRenderedPreview]]
    let cellSize: CGSize
    let spacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            VStack(alignment: .leading, spacing: 3) {
                Text(skinName)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                Text("THUMBLE NATIVE RENDERER · VARIANT & STATE REVIEW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            .frame(height: 42, alignment: .leading)

            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: spacing) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, preview in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(preview.title.uppercased())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .lineLimit(1)
                            Image(decorative: preview.image, scale: 1)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .padding(14)
                        .frame(width: cellSize.width, height: cellSize.height, alignment: .topLeading)
                        .background(Color(red: 0.075, green: 0.08, blue: 0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                    }
                    if row.count < (rows.first?.count ?? row.count) {
                        ForEach(row.count..<(rows.first?.count ?? row.count), id: \.self) { _ in
                            Color.clear.frame(width: cellSize.width, height: cellSize.height)
                        }
                    }
                }
            }
        }
        .padding(24)
        .background(Color(red: 0.035, green: 0.04, blue: 0.055))
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}
#endif
