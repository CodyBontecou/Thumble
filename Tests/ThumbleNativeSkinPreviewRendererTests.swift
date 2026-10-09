#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import XCTest

@MainActor
final class ThumbleNativeSkinPreviewRendererTests: XCTestCase {
    func testNativeRendererIsDeterministicAndUsesImagePayloads() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbleNativePreviewTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)

        let redImage = try solidPNG(color: .systemRed)
        var customization = GamepadCustomization.blankCanvas
        customization.backgroundFillStyle = .image(GamepadImageFill(
            data: redImage,
            contentMode: .fill,
            resizingMode: .scale
        ))
        let item = ThumbleNativeSkinPreviewItem(
            title: "payload",
            customization: customization,
            colorScheme: .light,
            state: .normal
        )
        let first = temporary.appendingPathComponent("first.png")
        let second = temporary.appendingPathComponent("second.png")
        try ThumbleNativeSkinPreviewRenderer.writePNG(item: item, outputURL: first, scale: 1)
        try ThumbleNativeSkinPreviewRenderer.writePNG(item: item, outputURL: second, scale: 1)

        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(first as CFURL, nil))
        let rendered = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        XCTAssertEqual(rendered.width, Int(size.width))
        XCTAssertEqual(rendered.height, Int(size.height))
        let color = try XCTUnwrap(NSBitmapImageRep(cgImage: rendered).colorAt(x: rendered.width / 2, y: rendered.height / 2))
        XCTAssertGreaterThan(color.redComponent, 0.8)
        XCTAssertLessThan(color.greenComponent, 0.35)
        XCTAssertLessThan(color.blueComponent, 0.35)
    }

    func testContactSheetContainsEveryRequestedState() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThumbleNativeContactSheetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = temporary.appendingPathComponent("contact.png")
        let profile = try XCTUnwrap(ThumbleSkinArtboardCatalog.profile(for: ThumbleSkinArtboardCatalog.defaultID))
        let items = GamepadControlPresentationState.allCases.map { state in
            ThumbleNativeSkinPreviewItem(
                title: "landscape · dark · \(state.rawValue)",
                customization: profile.customization(for: .landscape),
                colorScheme: .dark,
                state: state
            )
        }

        try ThumbleNativeSkinPreviewRenderer.writeContactSheet(
            items: items,
            skinName: "Renderer Test",
            outputURL: output,
            columns: 2
        )
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 1104)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 902)
    }

    func testMixedStateReviewUsesExactTargetsAndRejectsUnknownControls() throws {
        let customization = GamepadControllerTemplate.xbox.makeProfile().customization
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let button = try XCTUnwrap(customization.resolvedControls(in: size).first { $0.controlKind == .button && $0.inputID != nil })
        let normal = ThumbleNativeSkinPreviewItem(title: "normal", customization: customization, colorScheme: .dark, state: .normal)
        var mixed = normal
        mixed.statesByControlID = [button.id.id: .pressed]
        XCTAssertNotEqual(try ThumbleNativeSkinPreviewRenderer.pngData(item: normal, scale: 1),
                          try ThumbleNativeSkinPreviewRenderer.pngData(item: mixed, scale: 1))
        mixed.statesByControlID = ["unknown-control": .active]
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.pngData(item: mixed))
    }

    private func solidPNG(color: NSColor) throws -> Data {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 8, height: 8)).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testDiagnosticOverlaysAreExplicitDeterministicAndPreserveCanvas() throws {
        let customization = GamepadControllerTemplate.xbox.makeProfile().customization
        let original = customization
        let plain = ThumbleNativeSkinPreviewItem(title: "plain", customization: customization,
                                                colorScheme: .dark, state: .normal)
        let plainPixels = try ThumbleNativeSkinPreviewRenderer.pngData(item: plain, scale: 1)
        var safe = plain
        safe.safeAreaInsets = .init(top: 0.05, leading: 0.1, bottom: 0.05, trailing: 0.1)
        // Supplied insets are metadata until the overlay is explicitly requested.
        XCTAssertEqual(plainPixels, try ThumbleNativeSkinPreviewRenderer.pngData(item: safe, scale: 1))
        safe.showsSafeAreaOverlay = true
        let safePixels = try ThumbleNativeSkinPreviewRenderer.pngData(item: safe, scale: 1)
        XCTAssertNotEqual(plainPixels, safePixels)
        var touch = plain
        touch.showsTouchTargets = true
        let touchPixels = try ThumbleNativeSkinPreviewRenderer.pngData(item: touch, scale: 1)
        XCTAssertNotEqual(plainPixels, touchPixels)
        safe.showsTouchTargets = true
        let combined = try ThumbleNativeSkinPreviewRenderer.pngData(item: safe, scale: 1)
        XCTAssertEqual(combined, try ThumbleNativeSkinPreviewRenderer.pngData(item: safe, scale: 1))
        XCTAssertNotEqual(combined, safePixels)
        XCTAssertNotEqual(combined, touchPixels)
        let image = try ThumbleNativeSkinPreviewRenderer.render(item: safe, scale: 1)
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        XCTAssertEqual(image.width, Int(size.width))
        XCTAssertEqual(image.height, Int(size.height))
        XCTAssertEqual(safe.customization, original)
        safe.safeAreaInsets.top = .nan
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.pngData(item: safe, scale: 1))
        safe.safeAreaInsets.top = 0.46
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.pngData(item: safe, scale: 1))
    }

    func testRuntimeRevealUsesTheExactAuthoredNativeFaceAndState() throws {
        var customization = GamepadControllerTemplate.xbox.makeProfile().customization
        customization.topBarActivationRegion.visualStyle = GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(fillStyle: .solid(GamepadRGBAColor(red: 0.8, green: 0.1, blue: 0.2)),
                                            content: GamepadControlContentStyle(icon: .sfSymbol("sun.max.fill"))),
            active: GamepadControlStateStyle(fillStyle: .solid(GamepadRGBAColor(red: 0.1, green: 0.8, blue: 0.4)),
                                            content: GamepadControlContentStyle(icon: .sfSymbol("moon.fill"))))
        customization = customization.resolvingAssetReferences().normalized
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let control = try XCTUnwrap(customization.resolvedControls(in: size).first { $0.id == .system(.topBarActivation) })
        var statePixels: [Data] = []
        for state in [GamepadControlPresentationState.normal, .active] {
            let runtime = GamepadRenderedControlFace.revealHandle(customization: customization, canvasSize: size, state: state)
            let reference = GamepadRenderedControlFace(control: control, customization: customization, state: state)
                .rotationEffect(.degrees(control.rotationDegrees))
            let runtimeRenderer = ImageRenderer(content: runtime.environment(\.colorScheme, .dark)
                .frame(width: control.size.width, height: control.size.height))
            let referenceRenderer = ImageRenderer(content: reference.environment(\.colorScheme, .dark)
                .frame(width: control.size.width, height: control.size.height))
            let runtimeImage = try XCTUnwrap(runtimeRenderer.cgImage)
            let referenceImage = try XCTUnwrap(referenceRenderer.cgImage)
            let runtimePixels = try XCTUnwrap(runtimeImage.dataProvider?.data) as Data
            let referencePixels = try XCTUnwrap(referenceImage.dataProvider?.data) as Data
            XCTAssertEqual(runtimePixels, referencePixels)
            statePixels.append(runtimePixels)
        }
        XCTAssertNotEqual(statePixels[0], statePixels[1])
    }

    func testRuntimeButtonUsesExactOwnedIdentityAndAuthoredNativePresentation() throws {
        var customization = GamepadControllerTemplate.xbox.makeProfile().customization
        let index = try XCTUnwrap(customization.elements.firstIndex { $0.kind == .button })
        let id = customization.elements[index].id
        customization.elements[index].presentation = GamepadControlPresentation(legend: "Q", caption: "Light Binding",
            accessibilityName: "Cast Light Binding")
        customization.elements[index].layout.visualStyle = GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(fillStyle: .solid(GamepadRGBAColor(red: 0.8, green: 0.2, blue: 0.1)),
                content: GamepadControlContentStyle(legend: "Q", fontSize: 18, fontWeight: .bold, labelPlacement: .top)),
            pressed: GamepadControlStateStyle(fillStyle: .solid(GamepadRGBAColor(red: 0.1, green: 0.6, blue: 0.8)),
                content: GamepadControlContentStyle(legend: "R", fontSize: 24, labelPlacement: .bottom)))
        customization = customization.resolvingAssetReferences().normalized
        let canvas = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let control = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.elementID == id })
        let input = try XCTUnwrap(control.inputID)
        var statePixels: [Data] = []
        for state in [GamepadControlPresentationState.normal, .pressed] {
            let runtime = try XCTUnwrap(GamepadRenderedControlFace.runtimeButton(elementID: id, inputID: input,
                customization: customization, state: state, secondaryBindingText: "Ctrl+Q",
                target: GamepadRuntimeControlFaceTarget(control: control)))
            let reference = GamepadRenderedControlFace(control: control, customization: customization,
                state: state, secondaryBindingText: "Ctrl+Q")
            let runtimeRenderer = ImageRenderer(content: runtime.environment(\.colorScheme, .dark))
            let referenceRenderer = ImageRenderer(content: reference.environment(\.colorScheme, .dark))
            let runtimeImage = try XCTUnwrap(runtimeRenderer.cgImage)
            let referenceImage = try XCTUnwrap(referenceRenderer.cgImage)
            let pixels = try XCTUnwrap(runtimeImage.dataProvider?.data) as Data
            XCTAssertEqual(pixels, try XCTUnwrap(referenceImage.dataProvider?.data) as Data)
            statePixels.append(pixels)
        }
        XCTAssertNotEqual(statePixels[0], statePixels[1])
        XCTAssertNil(GamepadRenderedControlFace.runtimeButton(elementID: UUID(), inputID: input,
            customization: customization, state: .normal))
        let builtIn = try XCTUnwrap(GamepadRenderedControlFace.runtimeButton(elementID: nil, inputID: input,
            customization: customization, state: .normal))
        let renderer = ImageRenderer(content: builtIn.environment(\.colorScheme, .dark))
        XCTAssertNotNil(renderer.cgImage)
    }

    func testRuntimePointingUsesExactAuthoredNativeFaceAndMotion() throws {
        let red = GamepadRGBAColor(red: 1, green: 0, blue: 0)
        let green = GamepadRGBAColor(red: 0, green: 1, blue: 0)
        for kind in [GamepadCustomControlKind.joystick, .trackpad] {
            var customization = GamepadCustomization.blankCanvas
            let id = UUID()
            customization.elements = [KeypadElement(id: id, label: "Original", kind: kind,
                layout: GamepadButtonCustomization(visualStyle: GamepadControlVisualStyle(
                    normal: GamepadControlStateStyle(content: GamepadControlContentStyle(
                        legend: "Aim", fontSize: 13, labelPlacement: .bottom,
                        trackpadFrameVisible: false, trackpadCursorVisible: false, trackpadIndicatorsVisible: false,
                        joystickRingVisible: false, joystickKnobRatio: 0.3,
                        pointing: GamepadPointingPaint(joystickKnobFillColor: red))),
                    active: GamepadControlStateStyle(content: GamepadControlContentStyle(
                        fontSize: 17, pointing: GamepadPointingPaint(joystickKnobFillColor: green))))),
                presentation: GamepadControlPresentation(legend: "Aim", caption: "Drag", accessibilityName: "Aim Lux"))]
            customization = customization.resolvingAssetReferences().normalized
            let canvas = customization.deviceCanvas.editorDeviceFrame.screenRect.size
            let control = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.elementID == id })
            let target = GamepadRuntimeControlFaceTarget(control: control)
            func pixels(_ view: AnyView) throws -> Data {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
                return try XCTUnwrap(try XCTUnwrap(renderer.cgImage).dataProvider?.data) as Data
            }
            var statePixels: [Data] = []
            for state in [GamepadControlPresentationState.normal, .active] {
                let runtime = try XCTUnwrap(GamepadRenderedControlFace.runtimePointing(target: target,
                    customization: customization, state: state, secondaryBindingText: "Mouse",
                    interaction: GamepadPointingFaceInteraction()))
                let reference = AnyView(GamepadRenderedControlFace(control: control, customization: customization,
                    state: state, secondaryBindingText: "Mouse"))
                let rendered = try pixels(runtime)
                XCTAssertEqual(rendered, try pixels(reference))
                statePixels.append(rendered)
            }
            XCTAssertNotEqual(statePixels[0], statePixels[1])
            let moving = try XCTUnwrap(GamepadRenderedControlFace.runtimePointing(target: target,
                customization: customization, state: .active, secondaryBindingText: "Mouse",
                interaction: GamepadPointingFaceInteraction(joystickVector: CGSize(width: 1, height: -1),
                    interactionSize: control.size, trackpadTouchCount: 2)))
            if kind == .joystick {
                XCTAssertNotEqual(statePixels[1], try pixels(moving))
            } else {
                // Suppressed cursor/indicators stay suppressed even during two-finger input.
                XCTAssertEqual(statePixels[1], try pixels(moving))
            }
        }
        let bounded = GamepadPointingFaceInteraction(joystickVector: CGSize(width: CGFloat.infinity, height: -3), trackpadTouchCount: 99)
        XCTAssertEqual(bounded.joystickVector, CGSize(width: 0, height: -1))
        XCTAssertEqual(bounded.trackpadTouchCount, 5)
    }

    func testRuntimeTriggerUsesAuthoredFaceAndExactValueFillEvidence() throws {
        for orientation in GamepadTriggerOrientation.allCases {
            var customization = GamepadCustomization.blankCanvas
            let id = UUID()
            customization.elements = [KeypadElement(id: id, label: "RT", kind: .trigger,
                layout: GamepadButtonCustomization(visualStyle: GamepadControlVisualStyle(
                    normal: GamepadControlStateStyle(fillStyle: .solid(GamepadRGBAColor(red: 0, green: 0, blue: 0)),
                        foregroundColor: GamepadRGBAColor(red: 1, green: 1, blue: 1),
                        content: GamepadControlContentStyle(legend: "Lux", fontSize: 14)))),
                triggerSettings: GamepadTriggerSettings(orientation: orientation),
                presentation: GamepadControlPresentation(caption: "Hold", accessibilityName: "Hold trigger"))]
            customization = customization.resolvingAssetReferences().normalized
            let canvas = customization.deviceCanvas.editorDeviceFrame.screenRect.size
            let control = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.elementID == id })
            let target = GamepadRuntimeControlFaceTarget(control: control)
            for scheme in [ColorScheme.light, .dark] {
                func pixels(_ view: AnyView) throws -> Data {
                    let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
                    return try XCTUnwrap(try XCTUnwrap(renderer.cgImage).dataProvider?.data) as Data
                }
                var statePixels: [Data] = []
                for state in [GamepadControlPresentationState.normal, .active] {
                    let value: CGFloat = state == .normal ? 0 : 1
                    let runtime = try XCTUnwrap(GamepadRenderedControlFace.runtimeTrigger(target: target,
                        customization: customization, state: state,
                        interaction: GamepadTriggerFaceInteraction(value: value)))
                    let reference = AnyView(GamepadRenderedControlFace(control: control, customization: customization, state: state))
                    let rendered = try pixels(runtime)
                    XCTAssertEqual(rendered, try pixels(reference))
                    statePixels.append(rendered)
                    let appearance = customization.resolvedPresentation(for: control, state: state, scheme: scheme)
                    let evidence = GamepadNativeContentPresentation(control: control, showsButtonLabels: true,
                        content: appearance.content, icon: appearance.icon, state: state, scheme: scheme)
                    XCTAssertEqual(evidence.triggerValue, value)
                    XCTAssertEqual(evidence.triggerOrientation, orientation)
                    XCTAssertTrue(evidence.visibleSurfaceIDs.contains("trigger-fill"))
                    let frame = try XCTUnwrap(evidence.localSurfaceFrames["trigger-fill"])
                    if orientation == .vertical {
                        XCTAssertEqual(frame.maxY, control.size.height)
                        XCTAssertEqual(frame.height, value == 0 ? min(4, control.size.height) : control.size.height)
                    } else {
                        XCTAssertEqual(frame.minX, 0)
                        XCTAssertEqual(frame.width, value == 0 ? min(4, control.size.width) : control.size.width)
                    }
                    XCTAssertEqual(evidence.fixedProperties["triggerFillOpacity"], scheme == .dark ? 0.24 : 0.18)
                }
                XCTAssertNotEqual(statePixels[0], statePixels[1])
                let half = try XCTUnwrap(GamepadRenderedControlFace.runtimeTrigger(target: target,
                    customization: customization, state: .active, interaction: GamepadTriggerFaceInteraction(value: 0.5)))
                XCTAssertNotEqual(statePixels[0], try pixels(half))
                XCTAssertNotEqual(statePixels[1], try pixels(half))
            }
        }
        XCTAssertEqual(GamepadTriggerFaceInteraction(value: CGFloat.nan).value, 0)
        XCTAssertEqual(GamepadTriggerFaceInteraction(value: 2).value, 1)
        XCTAssertEqual(GamepadTriggerFaceInteraction(value: -2).value, 0)
    }

    func testSettledNativeStateScaleIsDrawnAndReportedWithoutChangingHitGeometry() throws {
        for kind in [GamepadCustomControlKind.button, .trackpad] {
            var customization = GamepadCustomization.blankCanvas
            customization.showsButtonLabels = false
            let id = UUID()
            let style = GamepadControlStateStyle(fillStyle: .solid(GamepadRGBAColor(red: 0, green: 1, blue: 0)),
                strokeWidth: 0, shadowRadius: 0, shadows: [], glowRadius: 0, opacity: 1, scale: 1,
                content: GamepadControlContentStyle(trackpadFrameVisible: false,
                    trackpadCursorVisible: false, trackpadIndicatorsVisible: false))
            customization.elements = [KeypadElement(id: id, kind: kind,
                layout: GamepadButtonCustomization(shape: .rectangle,
                    visualStyle: GamepadControlVisualStyle(normal: style, pressed: style, active: style)))]
            customization = customization.resolvingAssetReferences().normalized
            let canvas = customization.deviceCanvas.editorDeviceFrame.screenRect.size
            let control = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.elementID == id })
            let state: GamepadControlPresentationState = kind == .button ? .pressed : .active
            let appearance = customization.resolvedPresentation(for: control, state: state, scheme: .dark)
            let evidence = GamepadNativeContentPresentation(control: control, showsButtonLabels: false,
                content: appearance.content, icon: appearance.icon, state: state)
            let expected: CGFloat = kind == .button ? 0.94 : 0.97
            XCTAssertEqual(evidence.fixedProperties["nativeStateScaleMultiplier"], expected)
            XCTAssertEqual(evidence.effectiveFaceScale, expected)
            let authored = GamepadNativeContentPresentation(control: control, showsButtonLabels: false,
                content: appearance.content, icon: appearance.icon, state: state, authoredScale: 0.7)
            XCTAssertEqual(try XCTUnwrap(authored.effectiveFaceScale), 0.7 * expected, accuracy: 0.000001)
            XCTAssertEqual(appearance.scale, 1)
            let originalFrame = control.frame
            let originalHitFrame = control.hitFrame
            func image(_ state: GamepadControlPresentationState) throws -> NSBitmapImageRep {
                let renderer = ImageRenderer(content: GamepadRenderedControlFace(control: control,
                    customization: customization, state: state).environment(\.colorScheme, .dark))
                return NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            }
            let normal = try image(.normal)
            let contracted = try image(state)
            XCTAssertEqual(normal.pixelsWide, contracted.pixelsWide)
            XCTAssertEqual(normal.pixelsHigh, contracted.pixelsHigh)
            let normalEdge = try XCTUnwrap(normal.colorAt(x: 0, y: normal.pixelsHigh / 2)).alphaComponent
            let contractedEdge = try XCTUnwrap(contracted.colorAt(x: 0, y: contracted.pixelsHigh / 2)).alphaComponent
            XCTAssertGreaterThan(normalEdge, 0.9)
            XCTAssertLessThan(contractedEdge, normalEdge)
            XCTAssertEqual(control.frame, originalFrame)
            XCTAssertEqual(control.hitFrame, originalHitFrame)
        }
        let customization = GamepadControllerTemplate.xbox.makeProfile().customization
        let canvas = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let reveal = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.id == .system(.topBarActivation) })
        XCTAssertEqual(GamepadNativeContentPresentation.stateScaleMultiplier(control: reveal, state: .pressed), 1)
    }

    func testNativeSurfaceInkMeasuresSeparateGlyphsInCanvasCoordinates() throws {
        var customization = GamepadCustomization.blankCanvas
        let id = UUID()
        customization.elements = [KeypadElement(id: id, label: "Original", kind: .button,
            layout: GamepadButtonCustomization(visualStyle: GamepadControlVisualStyle(normal:
                GamepadControlStateStyle(content: GamepadControlContentStyle(
                    icon: .sfSymbol("sun.max.fill", placement: .bottom), legend: "Q", fontSize: 18, labelPlacement: .top)),
                disabled: GamepadControlStateStyle(opacity: 0))),
            presentation: GamepadControlPresentation(caption: "Hold"))]
        customization = customization.resolvingAssetReferences().normalized
        let canvas = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        func measure(_ scale: CGFloat = 1) throws -> GamepadNativeSurfaceInkEvidence {
            let control = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.elementID == id })
            return try XCTUnwrap(ThumbleNativeSkinPreviewRenderer.surfaceInk(control: control,
                customization: customization, state: .normal, scheme: .dark, canvasSize: canvas, scale: scale,
                surfaces: ["legend", "caption", "icon"]))
        }
        let control = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.elementID == id })
        let first = try measure()
        let repeated = try measure()
        XCTAssertEqual(first.rasterWidth, Int(ceil(canvas.width)))
        XCTAssertEqual(first.rasterHeight, Int(ceil(canvas.height)))
        let legend = try XCTUnwrap(first.samples["legend"]?.canvasPointBounds)
        let caption = try XCTUnwrap(first.samples["caption"]?.canvasPointBounds)
        let icon = try XCTUnwrap(first.samples["icon"]?.canvasPointBounds)
        XCTAssertLessThan(legend.midY, control.center.y)
        XCTAssertGreaterThan(caption.midY, legend.midY)
        XCTAssertGreaterThan(icon.midY, control.center.y)
        XCTAssertLessThan(legend.width, control.size.width)
        XCTAssertLessThan(icon.width, control.size.width)
        XCTAssertGreaterThan(caption.width, caption.height)
        for surface in ["legend", "caption", "icon"] {
            XCTAssertEqual(first.samples[surface]?.rgbaSHA256, repeated.samples[surface]?.rgbaSHA256)
            XCTAssertEqual(first.samples[surface]?.rgbaSHA256.count, 64)
        }
        for surface in ["legend", "caption", "icon"] {
            let layout = try XCTUnwrap(first.samples[surface]?.nativeLayout)
            XCTAssertEqual(layout.canvasBounds, repeated.samples[surface]?.nativeLayout?.canvasBounds)
            XCTAssertTrue([layout.canvasBounds.minX, layout.canvasBounds.minY, layout.canvasBounds.width, layout.canvasBounds.height].allSatisfy(\.isFinite))
            XCTAssertGreaterThan(layout.canvasBounds.width, 0)
            XCTAssertGreaterThan(layout.canvasBounds.height, 0)
            XCTAssertTrue(CGRect(origin: .zero, size: canvas).contains(layout.clippedCanvasBounds))
        }
        let captionLayout = try XCTUnwrap(first.samples["caption"]?.nativeLayout?.canvasBounds)
        XCTAssertGreaterThan(captionLayout.midY, try XCTUnwrap(first.samples["legend"]?.nativeLayout?.canvasBounds.midY))
        let referenceView = ZStack(alignment: .topLeading) {
            GamepadRenderedControlFace(control: control, customization: customization, state: .normal,
                surfaceMask: GamepadControlSurfaceMask(surface: "legend"))
                .rotationEffect(.degrees(control.rotationDegrees)).position(control.center)
        }.environment(\.colorScheme, .dark).frame(width: canvas.width, height: canvas.height).clipped()
        let referenceRenderer = ImageRenderer(content: referenceView)
        referenceRenderer.proposedSize = ProposedViewSize(width: canvas.width, height: canvas.height)
        referenceRenderer.scale = 1; referenceRenderer.isOpaque = false
        let reference = try ThumbleNativeSkinPreviewRenderer.clearedRaster(referenceRenderer, scale: 1, title: "unmeasured reference")
        var rgba = Data(count: reference.width * reference.height * 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: reference.width, height: reference.height,
                bitsPerComponent: 8, bytesPerRow: reference.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(reference, in: CGRect(x: 0, y: 0, width: reference.width, height: reference.height))
        }
        XCTAssertEqual(rgba.thumbleSHA256, first.samples["legend"]?.rgbaSHA256, "Layout probes must preserve native paint.")
        let transparent = try XCTUnwrap(ThumbleNativeSkinPreviewRenderer.surfaceInk(control: control,
            customization: customization, state: .disabled, scheme: .dark, canvasSize: canvas, scale: 1, surfaces: ["legend"]))
        XCTAssertNil(transparent.samples["legend"]?.pixelBounds)
        XCTAssertNotNil(transparent.samples["legend"]?.nativeLayout)
        XCTAssertNotEqual(transparent.samples["legend"]?.rgbaSHA256, first.samples["legend"]?.rgbaSHA256)
        let doubled = try measure(2)
        XCTAssertEqual(doubled.rasterWidth, first.rasterWidth * 2)
        let doubledLegend = try XCTUnwrap(doubled.samples["legend"]?.canvasPointBounds)
        XCTAssertEqual(doubledLegend.midY, legend.midY, accuracy: 1)
        var rotatedLayout = customization.elements[0].layout
        rotatedLayout.rotationDegrees = 90
        // Match the native bridge's geometry edit: keep the owned element and
        // its pre-existing legacy drawing mirror in agreement.
        customization.elements[0].layout = rotatedLayout
        let mirror = try XCTUnwrap(customization.customButtons.firstIndex { $0.id == id })
        customization.customButtons[mirror].layout = rotatedLayout
        let rotatedControl = try XCTUnwrap(customization.resolvedControls(in: canvas).first { $0.elementID == id })
        XCTAssertEqual(rotatedControl.rotationDegrees, 90)
        let rotated = try measure()
        let rotatedCaption = try XCTUnwrap(rotated.samples["caption"]?.canvasPointBounds)
        XCTAssertGreaterThan(rotatedCaption.height, rotatedCaption.width)
        let rotatedLayoutBounds = try XCTUnwrap(rotated.samples["caption"]?.nativeLayout?.canvasBounds)
        XCTAssertEqual(rotatedLayoutBounds.width, captionLayout.height, accuracy: 0.001)
        XCTAssertEqual(rotatedLayoutBounds.height, captionLayout.width, accuracy: 0.001)
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.surfaceInk(control: control,
            customization: customization, state: .normal, scheme: .dark,
            canvasSize: CGSize(width: CGFloat.nan, height: 100), scale: 1, surfaces: ["legend"]))
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.surfaceInk(control: control,
            customization: customization, state: .normal, scheme: .dark, canvasSize: canvas, scale: 1, surfaces: ["unknown"]))
    }

    func testAuthoredShortLegendRemainsVisibleWithCenteredIconAndLongProfileLabel() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.elements = [KeypadElement(id: UUID(), label: "Long name", kind: .button,
            layout: GamepadButtonCustomization(
                visualStyle: GamepadControlVisualStyle(normal: GamepadControlStateStyle(content: GamepadControlContentStyle(legend: "Q"))),
                icon: .sfSymbol("sparkles")))]
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let control = try XCTUnwrap(customization.resolvedControls(in: size).first { $0.elementID != nil })
        let presentation = customization.resolvedPresentation(for: control, scheme: .dark)
        let native = GamepadNativeContentPresentation(control: control, showsButtonLabels: true,
                                                    content: presentation.content, icon: presentation.icon)
        XCTAssertEqual(native.legend, "Q")
        XCTAssertEqual(native.fontSize, 32)
        XCTAssertTrue(native.legendVisible)
        XCTAssertEqual(control.label, "Long name")
        let visible = ThumbleNativeSkinPreviewItem(title: "visible", customization: customization, colorScheme: .dark, state: .normal)
        customization.showsButtonLabels = false
        let hidden = ThumbleNativeSkinPreviewItem(title: "hidden", customization: customization, colorScheme: .dark, state: .normal)
        XCTAssertNotEqual(try ThumbleNativeSkinPreviewRenderer.pngData(item: visible, scale: 1),
                          try ThumbleNativeSkinPreviewRenderer.pngData(item: hidden, scale: 1))
    }

    func testComputedTrackpadSurfacesFollowAuthoredChromeAndRetainNativeFlowLimits() throws {
        var customization = GamepadCustomization.blankCanvas
        let id = UUID()
        customization.elements = [KeypadElement(id: id, label: "Aim", kind: .trackpad, layout: .defaultValue)]
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let control = try XCTUnwrap(customization.resolvedControls(in: size).first { $0.elementID == id })
        let baseline = GamepadNativeContentPresentation(control: control, showsButtonLabels: true, content: nil, icon: nil)
        XCTAssertTrue(baseline.visibleSurfaceIDs.contains("trackpad-frame"))
        XCTAssertTrue(baseline.nativeFlowSurfaceIDs.contains("trackpad-cursor"))
        XCTAssertNil(baseline.localSurfaceFrames["trackpad-cursor"])
        let inset = try XCTUnwrap(baseline.trackpadFrameInset)
        XCTAssertEqual(baseline.localSurfaceFrames["trackpad-frame"], CGRect(origin: .zero, size: control.size).insetBy(dx: inset, dy: inset))
        let authored = GamepadControlContentStyle(fontSize: 15, labelPadding: 7, trackpadFrameVisible: false,
                                                 trackpadCursorVisible: false, trackpadIndicatorsVisible: false)
        let reduced = GamepadNativeContentPresentation(control: control, showsButtonLabels: true, content: authored, icon: nil)
        XCTAssertFalse(reduced.visibleSurfaceIDs.contains("trackpad-frame"))
        XCTAssertFalse(reduced.visibleSurfaceIDs.contains("trackpad-cursor"))
        XCTAssertTrue(reduced.localSurfaceFrames.isEmpty)
        XCTAssertEqual(reduced.minimumScaleFactor, 1)
        XCTAssertEqual(reduced.labelPadding, 7)
        XCTAssertFalse(reduced.fallbacks.contains("native-trackpad-frame"))
        let roundTrip = try JSONDecoder().decode(GamepadNativeContentPresentation.self, from: JSONEncoder().encode(reduced))
        XCTAssertEqual(roundTrip.visibleSurfaceIDs, reduced.visibleSurfaceIDs)
        XCTAssertEqual(roundTrip.labelPadding, reduced.labelPadding)
    }

    func testNativePointingPaintChangesPuckAndFramePixelsPerState() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.showsButtonLabels = false
        let red = GamepadRGBAColor(red: 1, green: 0, blue: 0)
        let green = GamepadRGBAColor(red: 0, green: 1, blue: 0)
        let blue = GamepadRGBAColor(red: 0, green: 0, blue: 1)
        let magenta = GamepadRGBAColor(red: 1, green: 0, blue: 1)
        var stickLayout = GamepadButtonCustomization.defaultValue
        stickLayout.centerX = 0.3; stickLayout.centerY = 0.5
        stickLayout.visualStyle = GamepadControlVisualStyle(
            normal: GamepadControlStateStyle(content: GamepadControlContentStyle(pointing: GamepadPointingPaint(
                joystickRingColor: blue, joystickKnobFillColor: red, joystickRingStrokeWidth: 6))),
            active: GamepadControlStateStyle(content: GamepadControlContentStyle(pointing: GamepadPointingPaint(joystickKnobFillColor: green))))
        var padLayout = GamepadButtonCustomization.defaultValue
        padLayout.centerX = 0.7; padLayout.centerY = 0.5
        padLayout.visualStyle = GamepadControlVisualStyle(normal: GamepadControlStateStyle(content: GamepadControlContentStyle(
            trackpadCursorVisible: false, trackpadIndicatorsVisible: false,
            pointing: GamepadPointingPaint(trackpadFrameColor: magenta, trackpadFrameStrokeWidth: 6))))
        customization.elements = [KeypadElement(id: UUID(), label: "Stick", kind: .joystick, layout: stickLayout),
                                  KeypadElement(id: UUID(), label: "Aim", kind: .trackpad, layout: padLayout)]
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let controls = customization.resolvedControls(in: size)
        let stick = try XCTUnwrap(controls.first { $0.isJoystick })
        let pad = try XCTUnwrap(controls.first { $0.isTrackpad })
        let normal = NSBitmapImageRep(cgImage: try ThumbleNativeSkinPreviewRenderer.render(
            item: .init(title: "normal", customization: customization, colorScheme: .dark, state: .normal), scale: 1))
        let active = NSBitmapImageRep(cgImage: try ThumbleNativeSkinPreviewRenderer.render(
            item: .init(title: "active", customization: customization, colorScheme: .dark, state: .active), scale: 1))
        let normalPuck = try XCTUnwrap(normal.colorAt(x: Int(stick.center.x), y: Int(stick.center.y)))
        let activePuck = try XCTUnwrap(active.colorAt(x: Int(stick.center.x), y: Int(stick.center.y)))
        XCTAssertGreaterThan(normalPuck.redComponent, 0.9)
        XCTAssertLessThan(normalPuck.greenComponent, 0.1)
        XCTAssertGreaterThan(activePuck.greenComponent, 0.9)
        XCTAssertLessThan(activePuck.redComponent, 0.1)
        let ring = try XCTUnwrap(normal.colorAt(x: Int(stick.center.x + min(stick.size.width, stick.size.height) * 0.35), y: Int(stick.center.y)))
        XCTAssertGreaterThan(ring.blueComponent, 0.9)
        let inset = max(5, min(pad.size.width, pad.size.height) * 0.08)
        let frame = try XCTUnwrap(normal.colorAt(x: Int(pad.frame.minX + inset), y: Int(pad.center.y)))
        XCTAssertGreaterThan(frame.redComponent, 0.9)
        XCTAssertGreaterThan(frame.blueComponent, 0.9)
        XCTAssertLessThan(frame.greenComponent, 0.1)
    }

    func testResolvedPointingPaintPreservesDefaultsAndTouchFeedback() throws {
        var customization = GamepadCustomization.blankCanvas
        customization.elements = [
            KeypadElement(id: UUID(), label: "Stick", kind: .joystick, layout: .defaultValue),
            KeypadElement(id: UUID(), label: "Aim", kind: .trackpad, layout: .defaultValue)
        ]
        let controls = customization.resolvedControls(in: customization.deviceCanvas.editorDeviceFrame.screenRect.size)
        let stick = try XCTUnwrap(controls.first { $0.isJoystick })
        let pad = try XCTUnwrap(controls.first { $0.isTrackpad })
        let foreground = GamepadRGBAColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 0.5)
        for scheme in [ColorScheme.light, .dark] {
            for state in GamepadControlPresentationState.allCases {
                let native = GamepadNativeContentPresentation(control: stick, showsButtonLabels: true,
                    content: nil, icon: nil, state: state, scheme: scheme, profileAccentStyle: .purple)
                XCTAssertNil(native.pointingPaint)
                let paint = try XCTUnwrap(native.resolvedPointingPaint)
                XCTAssertEqual(paint.joystickRingColor, GamepadRGBAColor(color: Geist.color(.grayAlpha400, scheme: scheme)).normalized)
                XCTAssertEqual(paint.joystickKnobFillColor, GamepadRGBAColor(color:
                    stick.layoutCustomization.joystickKnobFill(accentStyle: .purple,
                        isPressed: state.usesPressedFallback, scheme: scheme)).normalized)
                XCTAssertEqual(paint.joystickKnobStrokeColor, GamepadRGBAColor(color:
                    stick.layoutCustomization.joystickKnobStroke(accentStyle: .purple,
                        isPressed: state.usesPressedFallback, scheme: scheme)).normalized)
                let idle = GamepadNativeContentPresentation(control: pad, showsButtonLabels: true,
                    content: nil, icon: nil, state: state, scheme: scheme, foregroundColor: foreground)
                let idlePaint = try XCTUnwrap(idle.resolvedPointingPaint)
                XCTAssertNil(idle.pointingPaint)
                XCTAssertEqual(try XCTUnwrap(idlePaint.trackpadFrameColor).alpha, 0.12, accuracy: 0.00001)
                XCTAssertEqual(try XCTUnwrap(idlePaint.trackpadCursorColor).alpha, 0.41, accuracy: 0.00001)
                XCTAssertEqual(try XCTUnwrap(idlePaint.trackpadIndicatorColor).alpha, 0.17, accuracy: 0.00001)
                XCTAssertEqual(try XCTUnwrap(idlePaint.trackpadSecondaryIndicatorColor).alpha, 0.09, accuracy: 0.00001)
                let touched = GamepadNativeContentPresentation(control: pad, showsButtonLabels: true,
                    content: nil, icon: nil, state: state, scheme: scheme, foregroundColor: foreground, trackpadTouchCount: 2)
                XCTAssertEqual(try XCTUnwrap(touched.resolvedPointingPaint?.trackpadSecondaryIndicatorColor).alpha, 0.21, accuracy: 0.00001)
            }
        }
        let override = GamepadRGBAColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 0.7)
        let native = GamepadNativeContentPresentation(control: pad, showsButtonLabels: true,
            content: .init(pointing: .init(trackpadSecondaryIndicatorColor: override, trackpadFrameStrokeWidth: 6)),
            icon: nil, foregroundColor: foreground, trackpadTouchCount: 2)
        XCTAssertEqual(native.resolvedPointingPaint?.trackpadSecondaryIndicatorColor, override)
        XCTAssertEqual(native.resolvedPointingPaint?.trackpadFrameStrokeWidth, 6)
    }

    func testBindingHintReviewMeasuresSeparateNativeInkAndRejectsUnknownTargets() throws {
        var customization = GamepadControllerTemplate.xbox.makeProfile().customization
        let index = try XCTUnwrap(customization.elements.firstIndex { $0.kind == .button })
        let id = customization.elements[index].id
        customization.elements[index].presentation = .init(legend: "Q", caption: "Ability")
        customization = customization.resolvingAssetReferences().normalized
        let size = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        let control = try XCTUnwrap(customization.resolvedControls(in: size).first { $0.elementID == id })
        let hint = "⌘K"
        let plain = ThumbleNativeSkinPreviewItem(title: "plain", customization: customization, colorScheme: .dark, state: .normal)
        var hinted = plain
        hinted.secondaryBindingTexts = [control.id.id: hint]
        XCTAssertNotEqual(try ThumbleNativeSkinPreviewRenderer.pngData(item: plain, scale: 1),
                          try ThumbleNativeSkinPreviewRenderer.pngData(item: hinted, scale: 1))
        let native = GamepadNativeContentPresentation(control: control, showsButtonLabels: true,
            content: nil, icon: nil, secondaryBindingText: hint)
        XCTAssertEqual(native.bindingHint, hint)
        XCTAssertTrue(native.visibleSurfaceIDs.contains("caption"))
        XCTAssertTrue(native.visibleSurfaceIDs.contains("binding-hint"))
        let ink = try XCTUnwrap(ThumbleNativeSkinPreviewRenderer.surfaceInk(control: control,
            customization: customization, state: .normal, scheme: .dark, canvasSize: size, scale: 1,
            surfaces: ["caption", "binding-hint"], secondaryBindingText: hint))
        XCTAssertNotNil(ink.samples["caption"]?.pixelBounds)
        XCTAssertNotNil(ink.samples["binding-hint"]?.pixelBounds)
        XCTAssertNotEqual(ink.samples["caption"]?.rgbaSHA256, ink.samples["binding-hint"]?.rgbaSHA256)
        XCTAssertNil(KeypadBindingPresentationBuilder.visibleHint("  C a F é ", label: "cafe"))
        XCTAssertNil(KeypadBindingPresentationBuilder.visibleHint("⌘K", label: "Q", icon: .text("⌘K")))
        hinted.secondaryBindingTexts = ["missing": hint]
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.pngData(item: hinted, scale: 1))
        hinted.secondaryBindingTexts = [control.id.id: String(repeating: "x", count: 513)]
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.pngData(item: hinted, scale: 1))
    }

    func testNativeControlBarUsesSharedLabelsAndRuntimeContext() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.name = "Lux Setup"
        func pixels(_ value: GamepadConfigurationProfile, connected: Bool = false,
                    editing: Bool = false, orientation: GamepadEditorDeviceOrientation = .landscape,
                    scale: CGFloat = 1) throws -> Data {
            let image = try ThumbleNativeSkinPreviewRenderer.renderControlBar(profile: value,
                orientation: orientation, colorScheme: .dark, isConnected: connected,
                isDefault: false, isEditing: editing, scale: scale)
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        let original = try pixels(profile)
        XCTAssertEqual(original, try pixels(profile))
        XCTAssertNotEqual(original, try pixels(profile, connected: true))
        XCTAssertNotEqual(original, try pixels(profile, editing: true))
        var renamed = profile
        renamed.name = "A different setup"
        XCTAssertNotEqual(original, try pixels(renamed))
        // Compact portrait labels have no profile title, matching the interactive bar.
        XCTAssertEqual(try pixels(profile, orientation: .portrait), try pixels(renamed, orientation: .portrait))
        let one = try ThumbleNativeSkinPreviewRenderer.renderControlBar(profile: profile,
            orientation: .landscape, colorScheme: .light, isConnected: false, isDefault: true)
        let two = try ThumbleNativeSkinPreviewRenderer.renderControlBar(profile: profile,
            orientation: .landscape, colorScheme: .light, isConnected: false, isDefault: true, scale: 2)
        XCTAssertEqual(two.width, one.width * 2)
        XCTAssertEqual(two.height, one.height * 2)
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.renderControlBar(profile: profile,
            orientation: .landscape, colorScheme: .dark, isConnected: false, isDefault: false, scale: 3))
    }

    func testNativeBarAssetIconsUsePayloadRenderingModeTintAndScale() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        var customization = profile.customization
        customization.controlBarItems = [.settings]
        var appearance = GamepadButtonCustomization.defaultValue
        appearance.icon = .init(source: .asset, value: "bar-art", renderingMode: .original)
        customization.setControlBarItemCustomization(appearance, for: .settings)
        func pixels(_ data: Data?, mode: GamepadControlIconRenderingMode = .original,
                    scale: CGFloat = 1, tint: GamepadRGBAColor = .init(red: 0, green: 1, blue: 0, alpha: 1)) throws -> Data {
            var value = customization
            value.assetLibrary.assets = data.map { [.init(id: "bar-art", name: "Bar artwork", contentType: "image/png", data: $0)] } ?? []
            var item = appearance
            item.icon?.renderingMode = mode
            item.icon?.scale = scale
            item.icon?.tintColor = tint
            value.setControlBarItemCustomization(item, for: .settings)
            let snapshot = try ThumbleNativeSkinPreviewRenderer.renderControlBarSnapshot(profile: profile,
                orientation: .landscape, colorScheme: .light, isConnected: false, isDefault: false,
                customizationOverride: value)
            let evidence = try XCTUnwrap(snapshot.layout.paint?.icons["native-control-bar/settings/icon"])
            XCTAssertEqual(evidence.requested?.scale, scale)
            XCTAssertEqual(evidence.fontSize, 13 * scale)
            XCTAssertEqual(evidence.tintColor, tint)
            XCTAssertEqual(evidence.assetSHA256, data?.thumbleSHA256)
            XCTAssertEqual(evidence.resolvedSource, data == nil ? "sf_symbol" : "asset")
            XCTAssertEqual(evidence.resolvedRenderingMode, data == nil ? "monochrome" : mode == .template ? "template" : "original")
            if data == nil { XCTAssertTrue(evidence.fallbacks.contains("asset missing; native missing-image symbol")) }
            return try XCTUnwrap(snapshot.image.dataProvider?.data) as Data
        }
        let red = try solidPNG(color: .red), blue = try solidPNG(color: .blue)
        let original = try pixels(red)
        XCTAssertEqual(original, try pixels(red))
        XCTAssertNotEqual(original, try pixels(blue))
        XCTAssertNotEqual(original, try pixels(nil))
        // Equal opaque silhouettes share template paint even when RGB payload differs.
        XCTAssertEqual(try pixels(red, mode: .template), try pixels(blue, mode: .template))
        let redTint = GamepadRGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertEqual(original, try pixels(red, tint: redTint))
        XCTAssertNotEqual(try pixels(red, mode: .template), try pixels(red, mode: .template, tint: redTint))
        XCTAssertNotEqual(original, try pixels(red, scale: 2))
    }

    func testNativeBarPaintCapturesOverrideAndDisabledFallbackFromActualViews() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        var customization = profile.customization
        customization.controlBarItems = [.profileMenu, .settings]
        var requested = GamepadButtonCustomization.defaultValue
        requested.fillColor = GamepadRGBAColor(red: 0.8, green: 0.2, blue: 0.1)
        requested.widthScale = 1.5; requested.shape = .star
        customization.setControlBarItemCustomization(requested, for: .settings)
        let snapshot = try ThumbleNativeSkinPreviewRenderer.renderControlBarSnapshot(profile: profile,
            orientation: .landscape, colorScheme: .light, isConnected: false, isDefault: false,
            isEditing: true, customizationOverride: customization)
        let paint = try XCTUnwrap(snapshot.layout.paint)
        let settings = try XCTUnwrap(paint.items["native-control-bar/settings"])
        XCTAssertEqual(settings.rendererShape, "star(5)")
        XCTAssertNil(settings.cornerRadii)
        XCTAssertEqual(settings.requested.fillColor, requested.fillColor)
        XCTAssertNotNil(settings.resolvedOverride)
        XCTAssertTrue(settings.fallbacks.isEmpty)
        let disabled = try XCTUnwrap(paint.items["native-control-bar/profile_menu"])
        XCTAssertEqual(disabled.state, .disabled)
        XCTAssertNil(disabled.resolvedOverride)
        XCTAssertEqual(disabled.fallbackForeground, Geist.rgba(.gray700, scheme: .light))
        XCTAssertEqual(disabled.fallbackBackground, Geist.rgba(.gray100, scheme: .light))
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.layout)) as? [String: Any])
        encoded.removeValue(forKey: "paint")
        let legacy = try JSONDecoder().decode(GamepadNativeBarLayoutEvidence.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertNil(legacy.paint)
    }

    func testNativeBarLayoutMeasuresVisibleItemsWithoutChangingPixels() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        var customization = profile.customization
        customization.controlBarItems = [.profileMenu, .settings, .home]
        var hidden = GamepadButtonCustomization.defaultValue
        hidden.isHidden = true
        customization.setControlBarItemCustomization(hidden, for: .home)
        func snapshot(_ value: GamepadCustomization, scale: CGFloat = 1) throws -> ThumbleNativeSkinPreviewRenderer.ControlBarSnapshot {
            try ThumbleNativeSkinPreviewRenderer.renderControlBarSnapshot(profile: profile,
                orientation: .landscape, colorScheme: .dark, isConnected: false, isDefault: false,
                scale: scale, customizationOverride: value)
        }
        let measured = try snapshot(customization)
        let paint = try XCTUnwrap(measured.layout.paint)
        XCTAssertEqual(Set(paint.items.keys), ["native-control-bar/profile_menu", "native-control-bar/settings"])
        XCTAssertEqual(Set(paint.icons.keys), ["native-control-bar/profile_menu/icon", "native-control-bar/settings/icon"])
        let nativeFallback = try XCTUnwrap(paint.items["native-control-bar/settings"])
        XCTAssertNil(nativeFallback.resolvedOverride)
        XCTAssertFalse(nativeFallback.fallbacks.isEmpty)
        XCTAssertEqual(nativeFallback.rendererShape, "roundedRectangle")
        XCTAssertEqual(nativeFallback.fallbackForeground, Geist.rgba(.gray1000, scheme: .dark))
        XCTAssertEqual(paint.foregroundBySurfaceID["native-control-bar/settings/icon"], nativeFallback.fallbackForeground)
        let frames = measured.layout.frames
        XCTAssertEqual(Set(frames.keys), ["native-control-bar", "native-control-bar/profile_menu", "native-control-bar/settings",
            "native-control-bar/profile_menu/legend", "native-control-bar/profile_menu/icon", "native-control-bar/settings/icon"])
        let titleFrame = try XCTUnwrap(frames["native-control-bar/profile_menu/legend"])
        let profileFrame = try XCTUnwrap(frames["native-control-bar/profile_menu"])
        XCTAssertGreaterThan(titleFrame.width, 0)
        XCTAssertTrue(profileFrame.contains(titleFrame))
        XCTAssertTrue(try XCTUnwrap(frames["native-control-bar/settings"]).contains(XCTUnwrap(frames["native-control-bar/settings/icon"])))
        let bar = try XCTUnwrap(frames["native-control-bar"])
        let settings = try XCTUnwrap(frames["native-control-bar/settings"])
        XCTAssertGreaterThan(settings.width, 0)
        XCTAssertTrue(bar.contains(settings))
        XCTAssertTrue(measured.layout.outOfViewportIDs.isEmpty)
        XCTAssertEqual(measured.layout.viewport.width, CGFloat(measured.image.width))
        let twice = try snapshot(customization, scale: 2)
        for id in ["native-control-bar", "native-control-bar/profile_menu", "native-control-bar/settings"] {
            XCTAssertEqual(twice.layout.frames[id], frames[id])
        }
        // Text/symbol leaf fitting may align to different backing pixel scales.
        XCTAssertEqual(Set(twice.layout.frames.keys), Set(frames.keys))
        XCTAssertEqual(twice.layout.viewport, measured.layout.viewport)
        let width = customization.deviceCanvas.editorDeviceFrame.screenRect.width
        let unmeasured = GamepadRenderedControlFace.controlBar(customization: customization, profileName: profile.name,
            isDefault: false, launchTarget: profile.launchTarget, isConnected: false, isLandscape: true)
            .environment(\.colorScheme, .dark).frame(width: width)
        let renderer = ImageRenderer(content: unmeasured)
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.isOpaque = false
        let image = try ThumbleNativeSkinPreviewRenderer.clearedRaster(renderer, scale: 1, title: "unmeasured bar")
        XCTAssertEqual(try XCTUnwrap(measured.image.dataProvider?.data) as Data,
                       try XCTUnwrap(image.dataProvider?.data) as Data)
        var wide = GamepadButtonCustomization.defaultValue
        wide.widthScale = 2
        customization.setControlBarItemCustomization(wide, for: .settings)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot(customization).layout.frames["native-control-bar/settings"]).width, settings.width)
    }

    func testNativeBarLeavesFollowCompactLabelsAndLaunchPayloadBranches() throws {
        var profile = GamepadControllerTemplate.xbox.makeProfile()
        profile.launchTarget = .init(displayName: "Fixture", bundleIdentifier: "com.example.fixture", iconPNGData: try solidPNG(color: .blue))
        var customization = profile.customization
        customization.controlBarItems = [.profileMenu, .connectionAction, .launchTarget]
        var connection = GamepadButtonCustomization.defaultValue
        connection.icon = .sfSymbol("link")
        customization.setControlBarItemCustomization(connection, for: .connectionAction)
        func snapshot(_ orientation: GamepadEditorDeviceOrientation, value: GamepadCustomization? = nil) throws -> ThumbleNativeSkinPreviewRenderer.ControlBarSnapshot {
            try ThumbleNativeSkinPreviewRenderer.renderControlBarSnapshot(profile: profile, orientation: orientation,
                colorScheme: .light, isConnected: true, isDefault: false, customizationOverride: value ?? customization)
        }
        let payload = try XCTUnwrap(snapshot(.landscape).layout.paint?.icons["native-control-bar/launch_target/icon"])
        XCTAssertEqual(payload.resolvedSource, "launch-png")
        XCTAssertEqual(payload.resolvedRenderingMode, "original")
        XCTAssertEqual(payload.assetSHA256, profile.launchTarget?.iconPNGData?.thumbleSHA256)
        let landscape = try snapshot(.landscape).layout.frames
        XCTAssertNotNil(landscape["native-control-bar/profile_menu/legend"])
        XCTAssertNotNil(landscape["native-control-bar/connection/legend"])
        XCTAssertNotNil(landscape["native-control-bar/connection/icon"])
        XCTAssertEqual(try XCTUnwrap(landscape["native-control-bar/launch_target/icon"]).size, CGSize(width: 20, height: 20))
        let portrait = try snapshot(.portrait).layout.frames
        XCTAssertNil(portrait["native-control-bar/profile_menu/legend"])
        XCTAssertNil(portrait["native-control-bar/connection/legend"])
        XCTAssertNotNil(portrait["native-control-bar/connection/icon"])
        XCTAssertEqual(try XCTUnwrap(portrait["native-control-bar/launch_target/icon"]).size, CGSize(width: 18, height: 18))
        profile.launchTarget?.iconPNGData = nil
        let fallback = try XCTUnwrap(snapshot(.landscape).layout.paint?.icons["native-control-bar/launch_target/icon"])
        XCTAssertEqual(fallback.resolvedSource, "sf_symbol")
        XCTAssertFalse(fallback.fallbacks.isEmpty)
        XCTAssertNotNil(try snapshot(.landscape).layout.frames["native-control-bar/launch_target/icon"])
        var authored = customization
        var launch = GamepadButtonCustomization.defaultValue
        launch.icon = .sfSymbol("star.fill")
        authored.setControlBarItemCustomization(launch, for: .launchTarget)
        XCTAssertNotNil(try snapshot(.landscape, value: authored).layout.frames["native-control-bar/launch_target/icon"])
    }

    func testDrawerSurfaceUsesSafeAreasAndPinnedVisibility() throws {
        let profile = GamepadControllerTemplate.xbox.makeProfile()
        let safe = ThumbleNormalizedInsets(top: 0.08, leading: 0.04, bottom: 0, trailing: 0.02)
        func pixels(visible: Bool, connected: Bool, editing: Bool = false, opacity: CGFloat = 1,
                    insets: ThumbleNormalizedInsets = .init(), alphaOnly: Bool = false) throws -> Data {
            let image = try ThumbleNativeSkinPreviewRenderer.renderDrawerSurface(profile: profile,
                orientation: .landscape, colorScheme: .dark, safeAreaInsets: insets,
                requestedVisibility: visible, isConnected: connected, isDefault: false,
                isEditing: editing, collapsedOpacity: opacity)
            if alphaOnly {
                var rgba = Data(count: image.width * image.height * 4)
                try rgba.withUnsafeMutableBytes { bytes in
                    let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return Data(stride(from: 3, to: rgba.count, by: 4).map { rgba[$0] })
            }
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }
        XCTAssertEqual(try pixels(visible: false, connected: false), try pixels(visible: true, connected: false))
        XCTAssertEqual(try pixels(visible: false, connected: true, editing: true),
                       try pixels(visible: true, connected: true, editing: true))
        XCTAssertNotEqual(try pixels(visible: false, connected: true), try pixels(visible: true, connected: true))
        XCTAssertNotEqual(try pixels(visible: true, connected: true), try pixels(visible: true, connected: true, insets: safe))
        let measured = try ThumbleNativeSkinPreviewRenderer.renderDrawerSnapshot(profile: profile,
            orientation: .landscape, colorScheme: .dark, safeAreaInsets: safe, minimumPortraitTopInset: 0,
            requestedVisibility: true, isConnected: true, isDefault: false, isEditing: false,
            collapsedOpacity: 1, scale: 1)
        let barFrame = try XCTUnwrap(measured.layout.frames["native-control-bar"])
        XCTAssertEqual(barFrame.minY, safe.top * measured.layout.viewport.height + Geist.Spacing.s2, accuracy: 0.001)
        let revealFrame = try XCTUnwrap(measured.layout.frames["native-drawer/reveal"])
        XCTAssertGreaterThanOrEqual(revealFrame.width, 44)
        XCTAssertGreaterThanOrEqual(revealFrame.height, 44)
        XCTAssertGreaterThanOrEqual(revealFrame.minY, barFrame.maxY)
        let doubled = try ThumbleNativeSkinPreviewRenderer.renderDrawerSnapshot(profile: profile,
            orientation: .landscape, colorScheme: .dark, safeAreaInsets: safe, minimumPortraitTopInset: 0,
            requestedVisibility: true, isConnected: true, isDefault: false, isEditing: false,
            collapsedOpacity: 1, scale: 2)
        XCTAssertEqual(Set(measured.layout.frames.keys), Set(doubled.layout.frames.keys))
        // Text-sized native item widths can vary with raster pixel snapping. Container
        // and reveal placement remain in canvas points at both scales.
        for id in ["native-drawer", "native-drawer/reveal", "native-control-bar"] {
            XCTAssertEqual(measured.layout.frames[id], doubled.layout.frames[id])
        }
        XCTAssertEqual(doubled.image.width, measured.image.width * 2)
        let faded = try pixels(visible: false, connected: true, opacity: 0, alphaOnly: true)
        XCTAssertTrue(faded.allSatisfy { $0 == 0 }, "Faded alpha max \(faded.max() ?? 0), painted samples \(faded.filter { $0 != 0 }.count)")
        XCTAssertThrowsError(try ThumbleNativeSkinPreviewRenderer.renderDrawerSurface(profile: profile,
            orientation: .portrait, colorScheme: .light, safeAreaInsets: safe, minimumPortraitTopInset: 129,
            requestedVisibility: true, isConnected: true, isDefault: false))
        let portrait = GamepadTopBarDrawerLayout(safeAreaInsets: .init(top: 10, leading: 30, bottom: 4, trailing: 40),
            isLandscape: false, minimumPortraitTopInset: 54)
        XCTAssertEqual(portrait.topPadding, 54)
        XCTAssertEqual(portrait.leadingPadding, 30 + Geist.Spacing.s3)
        XCTAssertEqual(portrait.trailingPadding, 40 + Geist.Spacing.s3)
        let landscape = GamepadTopBarDrawerLayout(safeAreaInsets: .init(top: 30, leading: 0, bottom: 0, trailing: 0),
            isLandscape: true, minimumPortraitTopInset: 54)
        XCTAssertEqual(landscape.topPadding, 30 + Geist.Spacing.s2)
        XCTAssertEqual(landscape.minimumPortraitTopInset, 0)
    }
}
#endif

extension ThumbleNativeSkinPreviewRendererTests {
    @MainActor
    func testNativeCaptionChangesPixelsWhileAccessibilityNameDoesNot() throws {
        var customization = GamepadCustomization.defaultValue
        let id = UUID()
        try customization.addStandaloneCustomControl(GamepadCustomButton(id: id, label: "Title", controlKind: .text))
        let index = try XCTUnwrap(customization.elements.firstIndex { $0.id == id })
        customization.elements[index].presentation = .init(legend: "Aim", accessibilityName: "Aim surface")
        func pixels(_ value: GamepadCustomization) throws -> Data {
            try ThumbleNativeSkinPreviewRenderer.pngData(item: .init(title: "native-text", customization: value,
                colorScheme: .light, state: .normal), scale: 1)
        }
        let plain = try pixels(customization)
        customization.elements[index].presentation = .init(legend: "Aim", accessibilityName: "Drag to aim")
        XCTAssertEqual(plain, try pixels(customization))
        customization.elements[index].presentation = .init(legend: "Aim", caption: "Drag", accessibilityName: "Drag to aim")
        XCTAssertNotEqual(plain, try pixels(customization))
        let control = try XCTUnwrap(customization.resolvedControls(in: customization.deviceCanvas.editorDeviceFrame.screenRect.size)
            .first { $0.elementID == id })
        let content = GamepadNativeContentPresentation(control: control, showsButtonLabels: true, content: nil, icon: nil)
        XCTAssertTrue(content.visibleSurfaceIDs.contains("caption"))
        XCTAssertEqual(content.caption, "Drag")
    }
}
