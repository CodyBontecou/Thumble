import CoreGraphics
import Foundation

public enum GamepadSharedOperationError: LocalizedError, Equatable, Sendable {
    case unsupportedControl(String)
    case controlNotFound(String)
    case customControlLimitReached
    case specializedControlLimitReached(GamepadCustomControlKind)
    case duplicateElementID(UUID)
    case passiveControlOutput
    case unsupportedInputPart(KeypadElementInputPart, GamepadCustomControlKind)
    case insufficientControls(required: Int)
    case groupNotFound(String)
    case duplicateGroupID(String)
    case emptyGroupName

    public var errorDescription: String? {
        switch self {
        case .unsupportedControl(let id):
            return "Control cannot be used by this operation: \(id)"
        case .controlNotFound(let id):
            return "Control not found: \(id)"
        case .customControlLimitReached:
            return "Maximum custom element count reached"
        case .specializedControlLimitReached(let kind):
            return "Maximum \(kind.rawValue) count reached"
        case .duplicateElementID(let id):
            return "Element ID already exists: \(id.uuidString)"
        case .passiveControlOutput:
            return "Text and decoration elements do not send output"
        case .unsupportedInputPart(let part, let kind):
            return "\(part.rawValue) output is not supported by \(kind.rawValue) elements"
        case .insufficientControls(let required):
            return "Select at least \(required) controls"
        case .groupNotFound(let value):
            return "Group not found: \(value)"
        case .duplicateGroupID(let value):
            return "Group ID already exists: \(value)"
        case .emptyGroupName:
            return "Group name cannot be empty"
        }
    }
}

public extension GamepadControlIdentity {
    /// Parses stable appearance IDs and unprefixed actual control UUIDs.
    /// Named input slots are never accepted.
    init?(stableID value: String) {
        let raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let prefixes: [(String, (String) -> GamepadControlIdentity?)] = [
            ("builtin.", { KeypadElementID(rawValue: $0).map(GamepadControlIdentity.builtin) }),
            ("custom.", { UUID(uuidString: $0).map(GamepadControlIdentity.custom) }),
            ("system.", { GamepadSystemControl(rawValue: $0).map(GamepadControlIdentity.system) }),
            ("control_bar_item.", { GamepadControlBarItem(rawValue: $0).map(GamepadControlIdentity.controlBarItem) })
        ]
        for (prefix, makeIdentity) in prefixes where raw.lowercased().hasPrefix(prefix) {
            let suffix = String(raw.dropFirst(prefix.count))
            if let identity = makeIdentity(suffix) {
                self = identity
                return
            }
        }

        if let element = KeypadElementID(rawValue: raw) {
            self = DefaultKeypadElements.ids.contains(element) ? .builtin(element) : .custom(element.uuid)
        } else if let control = GamepadSystemControl(rawValue: raw) {
            self = .system(control)
        } else if let item = GamepadControlBarItem(rawValue: raw) {
            self = .controlBarItem(item)
        } else {
            return nil
        }
    }
}

public extension GamepadCustomization {
    mutating func upsertReusableStyle(_ token: GamepadStyleToken) {
        guard let token = token.normalized else { return }
        var library = styleLibrary.normalized
        library.styles.removeAll { $0.id == token.id }
        library.styles.append(token)
        styleLibrary = library.normalized
    }

    @discardableResult
    mutating func renameReusableStyle(id: String, name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              let index = styleLibrary.styles.firstIndex(where: { $0.id == id })
        else { return false }
        styleLibrary.styles[index].name = name
        return true
    }

    mutating func deleteReusableStyle(id: String) {
        normalizeInPlace()
        styleLibrary.styles.removeAll { $0.id == id }
        for button in elements.compactMap({ $0.kind == .button ? $0.defaultControlID : nil }) {
            var layout = buttonCustomization(for: button)
            if layout.styleID == id {
                layout.styleID = nil
                setButtonCustomization(layout, for: button)
            }
        }
        for index in customButtons.indices where customButtons[index].layout.styleID == id {
            customButtons[index].layout.styleID = nil
        }
        if topBarActivationRegion.styleID == id {
            topBarActivationRegion.styleID = nil
        }
        for item in controlBarItems {
            var appearance = controlBarItemCustomization(for: item)
            if appearance.styleID == id {
                appearance.styleID = nil
                setControlBarItemCustomization(appearance, for: item)
            }
        }
    }

    @discardableResult
    mutating func setReusableStyleID(
        _ styleID: String?,
        for identity: GamepadControlIdentity
    ) -> Bool {
        switch identity {
        case .builtin(let button):
            guard elements.contains(where: { $0.inputID == button }) else { return false }
            var layout = buttonCustomization(for: button)
            layout.styleID = styleID
            setButtonCustomization(layout, for: button)
            return true
        case .custom(let id):
            guard elements.contains(where: { $0.id == id }) else { return false }
            if !customButtons.contains(where: { $0.id == id }) { normalizeInPlace() }
            guard let index = customButtons.firstIndex(where: { $0.id == id }) else { return false }
            customButtons[index].layout.styleID = styleID
            return true
        case .system(.topBarActivation):
            topBarActivationRegion.styleID = styleID
            return true
        case .controlBarItem:
            return false
        }
    }
}

public struct GamepadElementDuplicationResult: Equatable, Sendable {
    public var identityMap: [GamepadControlIdentity: GamepadControlIdentity]

    public init(identityMap: [GamepadControlIdentity: GamepadControlIdentity]) {
        self.identityMap = identityMap
    }

    public var duplicatedIdentities: [GamepadControlIdentity] {
        identityMap.values.sorted { $0.id < $1.id }
    }
}

public enum GamepadControlAlignment: String, CaseIterable, Sendable {
    case leftEdges = "left"
    case horizontalCenters = "horizontal-centers"
    case rightEdges = "right"
    case topEdges = "top"
    case verticalCenters = "vertical-centers"
    case bottomEdges = "bottom"
}

public enum GamepadControlDistribution: String, CaseIterable, Sendable {
    case horizontalCenters = "horizontal-centers"
    case verticalCenters = "vertical-centers"
    case horizontalSpacing = "horizontal-spacing"
    case verticalSpacing = "vertical-spacing"
}

public enum GamepadProfileLayoutVariant: String, CaseIterable, Sendable {
    case landscape
    case portrait

    var editorOrientation: GamepadEditorDeviceOrientation {
        switch self {
        case .landscape: .landscape
        case .portrait: .portrait
        }
    }
}

public struct GamepadLayerGroupDuplicationResult: Equatable, Sendable {
    public var group: GamepadLayerGroup
    public var elements: GamepadElementDuplicationResult

    public init(group: GamepadLayerGroup, elements: GamepadElementDuplicationResult) {
        self.group = group
        self.elements = elements
    }
}

public extension GamepadCustomControlKind {
    var defaultElementLabel: String {
        switch self {
        case .button: "Shape"
        case .joystick: "Joystick"
        case .trigger: "Trigger"
        case .trackpad: "Trackpad"
        case .text: "Text"
        case .decoration: "Decoration"
        }
    }
}

public extension GamepadCustomization {
    /// Installs one fully-formed custom control using the same capacity and mirror
    /// semantics as the standalone CLI. The caller owns deterministic UUID choice.
    mutating func addStandaloneCustomControl(_ input: GamepadCustomButton) throws {
        let control = input.normalized
        guard !customButtons.contains(where: { $0.id == control.id }),
              !elements.contains(where: { $0.id == control.id })
        else { throw GamepadSharedOperationError.duplicateElementID(control.id) }
        try validateDuplicationCapacity([control.controlKind])
        customButtons.append(control)
        self = normalized
    }

    /// Updates the edit/appearance mirror and its declared element record.
    /// Output metadata already stored on the element survives the overlay.
    mutating func mutateStandaloneCustomControl(
        id: UUID,
        mutate: (inout GamepadCustomButton) throws -> Void
    ) throws {
        normalizeInPlace()
        guard let index = customButtons.firstIndex(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.controlNotFound(id.uuidString)
        }
        let oldKind = customButtons[index].normalized.controlKind
        var control = customButtons[index]
        try mutate(&control)
        let nextKind = control.normalized.controlKind
        if nextKind != oldKind {
            var withoutSource = self
            withoutSource.customButtons.remove(at: index)
            try withoutSource.validateDuplicationCapacity([nextKind])
        }
        customButtons[index] = control
        self = normalized
    }

    mutating func setStandaloneElementOutput(
        _ binding: KeypadElementOutputBinding?,
        for identity: GamepadControlIdentity,
        part: KeypadElementInputPart
    ) throws {
        let normalizedCustomization = normalized
        guard let elementID = normalizedCustomization.elementID(for: identity),
              let elementIndex = normalizedCustomization.elements.firstIndex(where: { $0.id == elementID })
        else { throw GamepadSharedOperationError.controlNotFound(identity.id) }
        let kind = normalizedCustomization.elements[elementIndex].kind
        if kind == .text || kind == .decoration {
            throw GamepadSharedOperationError.passiveControlOutput
        }
        let validPart = switch (kind, part) {
        case (_, .primary): true
        case (.joystick, .joystickUp), (.joystick, .joystickDown),
             (.joystick, .joystickLeft), (.joystick, .joystickRight),
             (.trigger, .triggerDigital): true
        default: false
        }
        guard validPart else { throw GamepadSharedOperationError.unsupportedInputPart(part, kind) }
        var next = normalizedCustomization
        next.elements[elementIndex].setOutputBinding(binding, for: part)
        self = next.normalized
    }

    /// Restores one installed control to the same type-specific defaults used by
    /// the standalone CLI while preserving the control's stable identity.
    mutating func resetControl(_ identity: GamepadControlIdentity) throws {
        normalizeInPlace()
        switch identity {
        case .builtin(let button):
            setButtonCustomization(.defaultValue, for: button)
            setLabel("", for: button)
        case .custom(let id):
            guard let index = customButtons.firstIndex(where: { $0.id == id }) else {
                throw GamepadSharedOperationError.controlNotFound(identity.id)
            }
            let kind = customButtons[index].normalized.controlKind
            customButtons[index].label = kind.defaultElementLabel
            switch kind {
            case .joystick:
                customButtons[index].layout = GamepadButtonCustomization(
                    centerX: 0.5,
                    centerY: 0.5,
                    widthScale: 1.35,
                    heightScale: 1.35,
                    shape: .circle
                )
                customButtons[index].joystickOutputSettings = customButtons[index].joystickOutputSettings ?? .defaultValue
                customButtons[index].triggerSettings = nil
                customButtons[index].trackpadSettings = nil
            case .trackpad:
                customButtons[index].layout = GamepadButtonCustomization(
                    centerX: 0.5,
                    centerY: 0.58,
                    widthScale: 1.25,
                    heightScale: 1.0,
                    shape: .roundedRectangle,
                    cornerRadius: 18
                )
                customButtons[index].joystickMapping = nil
                customButtons[index].trackpadSettings = .defaultValue
                customButtons[index].triggerSettings = nil
            case .trigger:
                let target = (customButtons[index].triggerSettings ?? .defaultValue).normalized.target
                customButtons[index].layout = GamepadButtonCustomization(
                    centerX: target == .left ? 0.20 : 0.80,
                    centerY: 0.14,
                    widthScale: 1.08,
                    heightScale: 0.42,
                    shape: .capsule,
                    accentStyle: .monochrome
                )
                customButtons[index].joystickMapping = nil
                customButtons[index].trackpadSettings = nil
                customButtons[index].triggerSettings = GamepadTriggerSettings(
                    target: target,
                    orientation: .horizontal
                )
            case .button:
                customButtons[index].layout = GamepadButtonCustomization(
                    centerX: 0.5,
                    centerY: 0.5,
                    widthScale: 1.0,
                    heightScale: 1.0,
                    shape: .roundedRectangle,
                    showsIntegratedLabel: false
                )
                customButtons[index].joystickMapping = nil
                customButtons[index].trackpadSettings = nil
            case .text:
                customButtons[index].layout = GamepadButtonCustomization(
                    centerX: 0.5,
                    centerY: 0.5,
                    widthScale: 1.4,
                    heightScale: 0.7,
                    shape: .rectangle,
                    shadowStrength: 0,
                    showsIntegratedLabel: false
                )
                customButtons[index].joystickMapping = nil
                customButtons[index].joystickOutputSettings = nil
                customButtons[index].triggerSettings = nil
                customButtons[index].trackpadSettings = nil
            case .decoration:
                customButtons[index].layout = GamepadButtonCustomization(
                    centerX: 0.5,
                    centerY: 0.5,
                    widthScale: 2.2,
                    heightScale: 1.2,
                    shape: .roundedRectangle,
                    fillColor: GamepadRGBAColor(hexString: "#F2EEF5"),
                    visualStyle: .softWhitePlate(),
                    cornerRadius: 28,
                    shadowStrength: 0
                )
                customButtons[index].joystickMapping = nil
                customButtons[index].joystickOutputSettings = nil
                customButtons[index].triggerSettings = nil
                customButtons[index].trackpadSettings = nil
            }
        case .system(.topBarActivation):
            topBarActivationRegion = Self.defaultTopBarActivationRegion
        case .controlBarItem:
            throw GamepadSharedOperationError.unsupportedControl(identity.id)
        }
    }

    /// Duplicates built-in or custom controls as new custom controls. Element-level
    /// output and part-output bindings are cloned with the visual/control settings.
    @discardableResult
    mutating func duplicateControls(
        _ identities: [GamepadControlIdentity],
        normalizedOffset: CGSize = CGSize(width: 0.025, height: 0.025),
        canvasSize: CGSize? = nil,
        newElementIDs: [UUID]? = nil
    ) throws -> GamepadElementDuplicationResult {
        let source = normalized
        var seen = Set<GamepadControlIdentity>()
        let requested = identities.filter { seen.insert($0).inserted }
        guard !requested.isEmpty else {
            throw GamepadSharedOperationError.insufficientControls(required: 1)
        }
        if let newElementIDs {
            let existingIDs = Set(source.elements.map(\.id)).union(source.customButtons.map(\.id))
            guard newElementIDs.count == requested.count,
                  Set(newElementIDs).count == newElementIDs.count,
                  existingIDs.isDisjoint(with: newElementIDs)
            else {
                throw GamepadSharedOperationError.controlNotFound("invalid duplicate element IDs")
            }
        }

        var sourceButtons: [(GamepadControlIdentity, GamepadCustomButton, KeypadElement?)] = []
        for identity in requested {
            switch identity {
            case .builtin(let button):
                guard DefaultKeypadElements.ids.contains(button),
                      source.elements.contains(where: { $0.inputID == button && $0.kind == .button })
                else {
                    throw GamepadSharedOperationError.controlNotFound(identity.id)
                }
                var layout = source.buttonCustomization(for: button)
                let effectiveCanvas = canvasSize ?? source.deviceCanvas.editorDeviceFrame.screenRect.size
                if let control = source.resolvedControls(in: effectiveCanvas).first(where: { $0.id == identity }) {
                    layout.centerX = control.normalizedCenter.x
                    layout.centerY = control.normalizedCenter.y
                } else {
                    layout.centerX = layout.centerX ?? 0.5
                    layout.centerY = layout.centerY ?? 0.5
                }
                sourceButtons.append((
                    identity,
                    GamepadCustomButton(
                        label: source.visualLabel(for: button),
                        layout: layout,
                        controlKind: .button
                    ),
                    source.element(for: identity)
                ))
            case .custom(let id):
                guard let button = source.customButtons.first(where: { $0.id == id })?.normalized else {
                    throw GamepadSharedOperationError.controlNotFound(identity.id)
                }
                sourceButtons.append((identity, button, source.element(for: identity)))
            case .system, .controlBarItem:
                throw GamepadSharedOperationError.unsupportedControl(identity.id)
            }
        }

        try validateDuplicationCapacity(sourceButtons.map { $0.1.controlKind })

        var next = source
        var identityMap: [GamepadControlIdentity: GamepadControlIdentity] = [:]
        for (index, sourceTuple) in sourceButtons.enumerated() {
            let (sourceIdentity, sourceButton, sourceElement) = sourceTuple
            let newID = newElementIDs?[index] ?? UUID()
            let newIdentity = GamepadControlIdentity.custom(newID)
            var duplicate = sourceButton
            duplicate.id = newID
            duplicate.visualRole = sourceElement?.visualRole ?? duplicate.visualRole
            duplicate.layout.centerX = Self.offsetCoordinate(duplicate.layout.centerX ?? 0.5, by: normalizedOffset.width)
            duplicate.layout.centerY = Self.offsetCoordinate(duplicate.layout.centerY ?? 0.5, by: normalizedOffset.height)
            next.customButtons.append(duplicate)
            var duplicatedElement = sourceElement ?? KeypadElement()
            duplicatedElement.id = newID
            duplicatedElement.label = duplicate.label
            duplicatedElement.kind = duplicate.controlKind
            duplicatedElement.layout = duplicate.layout
            duplicatedElement.visualRole = duplicate.visualRole
            duplicatedElement.joystickMapping = duplicate.joystickMapping
            duplicatedElement.joystickOutputSettings = duplicate.joystickOutputSettings
            duplicatedElement.triggerSettings = duplicate.triggerSettings
            duplicatedElement.trackpadSettings = duplicate.trackpadSettings
            next.elements.append(duplicatedElement)
            identityMap[sourceIdentity] = newIdentity
        }

        var metadata = next.designMetadata ?? .empty
        var order = source.orderedControlIdentitiesForDesign
        for sourceIdentity in requested {
            guard let duplicateIdentity = identityMap[sourceIdentity] else { continue }
            let insertionIndex = (order.firstIndex(of: sourceIdentity) ?? (order.count - 1)) + 1
            order.insert(duplicateIdentity, at: min(max(0, insertionIndex), order.count))
            for index in metadata.groups.indices {
                guard let childIndex = metadata.groups[index].children.firstIndex(of: sourceIdentity) else { continue }
                metadata.groups[index].children.insert(duplicateIdentity, at: childIndex + 1)
            }
        }
        metadata.layerOrder = order
        next.designMetadata = metadata.normalized(availableControls: next.allControlIdentitiesForDesign)
        self = next.normalized
        return GamepadElementDuplicationResult(identityMap: identityMap)
    }

    @discardableResult
    mutating func alignControls(
        _ identities: Set<GamepadControlIdentity>,
        alignment: GamepadControlAlignment,
        in canvasSize: CGSize
    ) throws -> Bool {
        let controls = resolvedControls(in: canvasSize).filter {
            identities.contains($0.id) && !$0.isLocationLocked && Self.supportsPositionOperations($0.id)
        }
        guard controls.count >= 2 else {
            throw GamepadSharedOperationError.insufficientControls(required: 2)
        }

        let target: CGFloat
        switch alignment {
        case .leftEdges: target = controls.map(\.frame.minX).min() ?? 0
        case .horizontalCenters: target = (controls.map(\.frame.minX).min()! + controls.map(\.frame.maxX).max()!) / 2
        case .rightEdges: target = controls.map(\.frame.maxX).max() ?? canvasSize.width
        case .topEdges: target = controls.map(\.frame.minY).min() ?? 0
        case .verticalCenters: target = (controls.map(\.frame.minY).min()! + controls.map(\.frame.maxY).max()!) / 2
        case .bottomEdges: target = controls.map(\.frame.maxY).max() ?? canvasSize.height
        }

        var changed = false
        for control in controls {
            var center = control.center
            switch alignment {
            case .leftEdges: center.x += target - control.frame.minX
            case .horizontalCenters: center.x = target
            case .rightEdges: center.x += target - control.frame.maxX
            case .topEdges: center.y += target - control.frame.minY
            case .verticalCenters: center.y = target
            case .bottomEdges: center.y += target - control.frame.maxY
            }
            let position = GamepadLayoutResolver.normalizedPosition(for: center, visualSize: control.size, in: canvasSize)
            setPosition(position, for: control.id)
            changed = changed || abs(center.x - control.center.x) > 0.001 || abs(center.y - control.center.y) > 0.001
        }
        self = normalized
        return changed
    }

    @discardableResult
    mutating func distributeControls(
        _ identities: Set<GamepadControlIdentity>,
        distribution: GamepadControlDistribution,
        in canvasSize: CGSize
    ) throws -> Bool {
        var controls = resolvedControls(in: canvasSize).filter {
            identities.contains($0.id) && !$0.isLocationLocked && Self.supportsPositionOperations($0.id)
        }
        guard controls.count >= 3 else {
            throw GamepadSharedOperationError.insufficientControls(required: 3)
        }

        let horizontal = distribution == .horizontalCenters || distribution == .horizontalSpacing
        controls.sort {
            horizontal ? ($0.center.x < $1.center.x) : ($0.center.y < $1.center.y)
        }
        let first = controls[0]
        let last = controls[controls.count - 1]
        var changed = false

        if distribution == .horizontalCenters || distribution == .verticalCenters {
            let start = horizontal ? first.center.x : first.center.y
            let end = horizontal ? last.center.x : last.center.y
            let step = (end - start) / CGFloat(controls.count - 1)
            for (index, control) in controls.enumerated().dropFirst().dropLast() {
                var center = control.center
                if horizontal { center.x = start + CGFloat(index) * step }
                else { center.y = start + CGFloat(index) * step }
                let position = GamepadLayoutResolver.normalizedPosition(for: center, visualSize: control.size, in: canvasSize)
                setPosition(position, for: control.id)
                changed = changed || abs(center.x - control.center.x) > 0.001 || abs(center.y - control.center.y) > 0.001
            }
        } else {
            let totalDimension = controls.reduce(CGFloat.zero) { partial, control in
                partial + (horizontal ? control.frame.width : control.frame.height)
            }
            let span = horizontal ? (last.frame.maxX - first.frame.minX) : (last.frame.maxY - first.frame.minY)
            let spacing = (span - totalDimension) / CGFloat(controls.count - 1)
            var trailingEdge = horizontal ? first.frame.maxX : first.frame.maxY
            for control in controls.dropFirst().dropLast() {
                var center = control.center
                let dimension = horizontal ? control.frame.width : control.frame.height
                let coordinate = trailingEdge + spacing + dimension / 2
                if horizontal { center.x = coordinate }
                else { center.y = coordinate }
                trailingEdge = coordinate + dimension / 2
                let position = GamepadLayoutResolver.normalizedPosition(for: center, visualSize: control.size, in: canvasSize)
                setPosition(position, for: control.id)
                changed = changed || abs(center.x - control.center.x) > 0.001 || abs(center.y - control.center.y) > 0.001
            }
        }
        self = normalized
        return changed
    }

    @discardableResult
    mutating func createLayerGroup(
        id: UUID,
        name: String,
        children: [GamepadControlIdentity]
    ) throws -> GamepadLayerGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GamepadSharedOperationError.emptyGroupName }
        var seen = Set<GamepadControlIdentity>()
        let available = Set(allControlIdentitiesForDesign)
        let normalizedChildren = children.filter {
            available.contains($0) && seen.insert($0).inserted
        }
        guard !normalizedChildren.isEmpty else {
            throw GamepadSharedOperationError.insufficientControls(required: 1)
        }
        var metadata = designMetadata ?? .empty
        guard !metadata.groups.contains(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.duplicateGroupID(id.uuidString)
        }
        let childSet = Set(normalizedChildren)
        for index in metadata.groups.indices {
            metadata.groups[index].children.removeAll { childSet.contains($0) }
        }
        metadata.groups.removeAll { $0.children.isEmpty }
        metadata.groups.append(GamepadLayerGroup(
            id: id,
            name: String(trimmed.prefix(48)),
            children: normalizedChildren
        ))
        let order = orderedControlIdentitiesForDesign
        let insertionIndex = order.indices.first(where: { childSet.contains(order[$0]) }) ?? order.count
        moveLayers(childSet, to: insertionIndex)
        metadata.layerOrder = orderedControlIdentitiesForDesign
        designMetadata = metadata.normalized(availableControls: allControlIdentitiesForDesign)
        guard let group = designMetadata?.groups.first(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        return group
    }

    @discardableResult
    mutating func removeLayerGroup(id: UUID) throws -> GamepadLayerGroup {
        var metadata = designMetadata ?? .empty
        guard let index = metadata.groups.firstIndex(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        let removed = metadata.groups.remove(at: index)
        designMetadata = metadata.normalized(availableControls: allControlIdentitiesForDesign)
        return removed
    }

    @discardableResult
    mutating func setLayerGroupHidden(id: UUID, isHidden: Bool) throws -> GamepadLayerGroup {
        var metadata = designMetadata ?? .empty
        guard let index = metadata.groups.firstIndex(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        let children = metadata.groups[index].children
        metadata.groups[index].isHidden = isHidden
        designMetadata = metadata.normalized(availableControls: allControlIdentitiesForDesign)
        for child in children {
            switch child {
            case .builtin(let button):
                var layout = buttonCustomization(for: button)
                layout.isHidden = isHidden
                setButtonCustomization(layout, for: button)
            case .custom(let id):
                guard let index = customButtons.firstIndex(where: { $0.id == id }) else { continue }
                customButtons[index].layout.isHidden = isHidden
                if let elementIndex = elements.firstIndex(where: { $0.id == id }) {
                    elements[elementIndex].layout.isHidden = isHidden
                }
            case .system(.topBarActivation):
                topBarActivationRegion.isHidden = isHidden
            case .controlBarItem:
                continue
            }
        }
        self = normalized
        guard let group = designMetadata?.groups.first(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        return group
    }

    @discardableResult
    mutating func setLayerGroupLocked(id: UUID, isLocked: Bool) throws -> GamepadLayerGroup {
        var metadata = designMetadata ?? .empty
        guard let index = metadata.groups.firstIndex(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        let children = metadata.groups[index].children
        metadata.groups[index].isLocked = isLocked
        designMetadata = metadata.normalized(availableControls: allControlIdentitiesForDesign)
        for child in children {
            switch child {
            case .builtin(let button):
                var layout = buttonCustomization(for: button)
                layout.isLocationLocked = isLocked
                setButtonCustomization(layout, for: button)
            case .custom(let id):
                guard let index = customButtons.firstIndex(where: { $0.id == id }) else { continue }
                customButtons[index].layout.isLocationLocked = isLocked
                if let elementIndex = elements.firstIndex(where: { $0.id == id }) {
                    elements[elementIndex].layout.isLocationLocked = isLocked
                }
            case .system(.topBarActivation):
                topBarActivationRegion.isLocationLocked = isLocked
            case .controlBarItem:
                continue
            }
        }
        self = normalized
        guard let group = designMetadata?.groups.first(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        return group
    }

    @discardableResult
    mutating func renameLayerGroup(id: UUID, to name: String) throws -> GamepadLayerGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GamepadSharedOperationError.emptyGroupName }
        var metadata = designMetadata ?? .empty
        guard let index = metadata.groups.firstIndex(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        metadata.groups[index].name = String(trimmed.prefix(48))
        designMetadata = metadata.normalized(availableControls: allControlIdentitiesForDesign)
        guard let group = designMetadata?.groups.first(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        return group
    }

    @discardableResult
    mutating func duplicateLayerGroup(
        id: UUID,
        name: String? = nil,
        normalizedOffset: CGSize = CGSize(width: 0.025, height: 0.025),
        canvasSize: CGSize? = nil,
        newGroupID: UUID? = nil,
        newElementIDs: [UUID]? = nil
    ) throws -> GamepadLayerGroupDuplicationResult {
        guard let sourceGroup = designMetadata?.normalized(availableControls: allControlIdentitiesForDesign)?.groups.first(where: { $0.id == id }) else {
            throw GamepadSharedOperationError.groupNotFound(id.uuidString)
        }
        let requestedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requestedName, requestedName.isEmpty { throw GamepadSharedOperationError.emptyGroupName }
        if let newGroupID,
           designMetadata?.groups.contains(where: { $0.id == newGroupID }) == true {
            throw GamepadSharedOperationError.duplicateGroupID(newGroupID.uuidString)
        }
        let elements = try duplicateControls(
            sourceGroup.children,
            normalizedOffset: normalizedOffset,
            canvasSize: canvasSize,
            newElementIDs: newElementIDs
        )
        let duplicatedChildren = sourceGroup.children.compactMap { elements.identityMap[$0] }
        let duplicate = GamepadLayerGroup(
            id: newGroupID ?? UUID(),
            name: requestedName ?? "\(sourceGroup.name) Copy",
            children: duplicatedChildren,
            isLocked: sourceGroup.isLocked,
            isHidden: sourceGroup.isHidden
        )
        var metadata = designMetadata ?? .empty
        let duplicatedSet = Set(duplicatedChildren)
        for index in metadata.groups.indices {
            metadata.groups[index].children.removeAll { duplicatedSet.contains($0) }
        }
        metadata.groups.removeAll { $0.children.isEmpty }
        metadata.groups.append(duplicate)
        designMetadata = metadata.normalized(availableControls: allControlIdentitiesForDesign)
        guard let normalizedGroup = designMetadata?.groups.first(where: { $0.id == duplicate.id }) else {
            throw GamepadSharedOperationError.groupNotFound(duplicate.id.uuidString)
        }
        return GamepadLayerGroupDuplicationResult(group: normalizedGroup, elements: elements)
    }

    /// Packs selected movable controls without changing size or layer order. Every
    /// non-selected control remains a fixed obstacle. Empty `controlIDs` means all.
    @discardableResult
    mutating func separateExpandedHitTargets(
        in canvasSize: CGSize,
        controlIDs: Set<GamepadControlIdentity> = [],
        respectingLocks: Bool = true
    ) -> Bool {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return false }
        let controls = resolvedControls(in: canvasSize).filter { !$0.isDecoration }
        let movable = controls.filter { control in
            (controlIDs.isEmpty || controlIDs.contains(control.id))
                && (!respectingLocks || !control.isLocationLocked)
        }.sorted { $0.id.id < $1.id.id }
        guard !movable.isEmpty else { return false }

        let movableIDs = Set(movable.map(\.id))
        var occupiedHitFrames = controls
            .filter { !movableIDs.contains($0.id) }
            .sorted { $0.id.id < $1.id.id }
            .map(GamepadLayoutQualityReport.runtimeHitFrame(for:))
        var next = self
        var changed = false

        for control in movable {
            let candidate = Self.nearestSeparatedFrame(
                for: control,
                avoidingHitFrames: occupiedHitFrames,
                in: canvasSize
            )
            let originalHitFrame = GamepadLayoutQualityReport.runtimeHitFrame(for: control)
            occupiedHitFrames.append(
                originalHitFrame.offsetBy(
                    dx: candidate.midX - control.frame.midX,
                    dy: candidate.midY - control.frame.midY
                )
            )
            guard hypot(candidate.midX - control.center.x, candidate.midY - control.center.y) > 0.01 else { continue }
            let position = GamepadLayoutResolver.normalizedPosition(
                for: CGPoint(x: candidate.midX, y: candidate.midY),
                visualSize: control.size,
                in: canvasSize
            )
            next.setPosition(position, for: control.id)
            changed = true
        }

        guard changed else { return false }
        self = next.normalized
        return true
    }

    /// Places selected primary movement/actions in lower thumb arcs for the current
    /// orientation, leaving utilities and specialized controls untouched.
    @discardableResult
    mutating func ergonomicallyAutoArrange(
        in canvasSize: CGSize,
        controlIDs: Set<GamepadControlIdentity> = [],
        respectingLocks: Bool = true
    ) -> Bool {
        guard canvasSize.width > 1, canvasSize.height > 1 else { return false }
        let portrait = canvasSize.height > canvasSize.width
        let controls = resolvedControls(in: canvasSize).filter { control in
            !control.isDecoration
                && (controlIDs.isEmpty || controlIDs.contains(control.id))
                && (!respectingLocks || !control.isLocationLocked)
        }
        let movement = controls.filter { GamepadLayoutErgonomicRole.role(for: $0) == .movement }.sorted(by: Self.ergonomicControlSort)
        let actions = controls.filter { GamepadLayoutErgonomicRole.role(for: $0) == .action }.sorted(by: Self.ergonomicControlSort)
        guard !movement.isEmpty || !actions.isEmpty else { return false }

        var next = self
        let reachMode = layoutReachMode
        let changed: Bool
        switch reachMode {
        case .twoHanded:
            let movementAnchor = CGPoint(x: canvasSize.width * (portrait ? 0.27 : 0.18), y: canvasSize.height * (portrait ? 0.76 : 0.68))
            let actionAnchor = CGPoint(x: canvasSize.width * (portrait ? 0.73 : 0.82), y: canvasSize.height * (portrait ? 0.76 : 0.68))
            let movedMovement = Self.placeErgonomicCluster(
                movement,
                anchor: movementAnchor,
                movementCluster: true,
                canvasSize: canvasSize,
                customization: &next
            )
            let movedActions = Self.placeErgonomicCluster(
                actions,
                anchor: actionAnchor,
                movementCluster: false,
                canvasSize: canvasSize,
                customization: &next
            )
            changed = movedMovement || movedActions
        case .oneHandedLeft, .oneHandedRight:
            let anchorX: CGFloat = reachMode == .oneHandedLeft
                ? (portrait ? 0.27 : 0.25)
                : (portrait ? 0.73 : 0.75)
            changed = Self.placeOneHandedErgonomicCluster(
                (movement + actions).sorted(by: Self.ergonomicControlSort),
                anchor: CGPoint(x: canvasSize.width * anchorX, y: canvasSize.height * (portrait ? 0.86 : 0.82)),
                canvasSize: canvasSize,
                customization: &next
            )
        }
        if changed { self = next.normalized }
        let affectedIDs = Set(movement.map(\.id) + actions.map(\.id))
        let separated = separateExpandedHitTargets(
            in: canvasSize,
            controlIDs: affectedIDs,
            respectingLocks: respectingLocks
        )
        return changed || separated
    }

    private static func nearestSeparatedFrame(
        for control: GamepadResolvedControl,
        avoidingHitFrames obstacles: [CGRect],
        in canvasSize: CGSize
    ) -> CGRect {
        let original = control.frame
        let originalHitFrame = GamepadLayoutQualityReport.runtimeHitFrame(for: control)
        let hitLeadingOutset = original.minX - originalHitFrame.minX
        let hitTopOutset = original.minY - originalHitFrame.minY
        let canvas = CGRect(origin: .zero, size: canvasSize)

        func hitFrame(for frame: CGRect) -> CGRect {
            originalHitFrame.offsetBy(
                dx: frame.midX - original.midX,
                dy: frame.midY - original.midY
            )
        }

        func fits(_ frame: CGRect) -> Bool {
            guard canvas.contains(frame) else { return false }
            let candidateHitFrame = hitFrame(for: frame)
            return obstacles.allSatisfy { obstacle in
                let intersection = candidateHitFrame.intersection(obstacle)
                return intersection.isNull || intersection.width <= 0.5 || intersection.height <= 0.5
            }
        }
        guard !fits(original) else { return original }

        var xValues: [CGFloat] = [original.minX, 0, canvasSize.width - original.width]
        var yValues: [CGFloat] = [original.minY, 0, canvasSize.height - original.height]
        for obstacle in obstacles {
            xValues.append(obstacle.minX - originalHitFrame.width + hitLeadingOutset)
            xValues.append(obstacle.maxX + hitLeadingOutset)
            yValues.append(obstacle.minY - originalHitFrame.height + hitTopOutset)
            yValues.append(obstacle.maxY + hitTopOutset)
        }
        xValues = Array(Set(xValues.filter { $0 >= 0 && $0 + original.width <= canvasSize.width }))
        yValues = Array(Set(yValues.filter { $0 >= 0 && $0 + original.height <= canvasSize.height }))

        let candidates = xValues.flatMap { x in
            yValues.map { y in CGRect(x: x, y: y, width: original.width, height: original.height) }
        }
        .filter(fits)
        .sorted { lhs, rhs in
            let lhsDistance = hypot(lhs.midX - original.midX, lhs.midY - original.midY)
            let rhsDistance = hypot(rhs.midX - original.midX, rhs.midY - original.midY)
            if abs(lhsDistance - rhsDistance) > 0.001 { return lhsDistance < rhsDistance }
            if abs(lhs.minY - rhs.minY) > 0.001 { return lhs.minY < rhs.minY }
            return lhs.minX < rhs.minX
        }
        return candidates.first ?? original
    }

    private static func ergonomicControlSort(_ lhs: GamepadResolvedControl, _ rhs: GamepadResolvedControl) -> Bool {
        let order: [KeypadElementID: Int] = [
            .preset(1): 0, .preset(3): 1, .preset(4): 2, .preset(2): 3,
            .preset(5): 4, .preset(6): 5, .preset(7): 6, .preset(8): 7
        ]
        let lhsOrder = lhs.inputID.flatMap { order[$0] } ?? 100
        let rhsOrder = rhs.inputID.flatMap { order[$0] } ?? 100
        return lhsOrder == rhsOrder ? lhs.id.id < rhs.id.id : lhsOrder < rhsOrder
    }

    private static func placeOneHandedErgonomicCluster(
        _ controls: [GamepadResolvedControl],
        anchor: CGPoint,
        canvasSize: CGSize,
        customization: inout GamepadCustomization
    ) -> Bool {
        guard !controls.isEmpty else { return false }
        let maxDimension = controls.map { max($0.size.width, $0.size.height) }.max() ?? 44
        let step = maxDimension + GamepadLayoutQualityReport.runtimeHitOutset * 2 + 2
        var changed = false
        for (index, control) in controls.enumerated() {
            let column = CGFloat((index % 3) - 1)
            let row = CGFloat(index / 3)
            let proposed = CGPoint(
                x: anchor.x + column * step,
                y: anchor.y - row * step
            )
            let position = GamepadLayoutResolver.normalizedPosition(
                for: proposed,
                visualSize: control.size,
                in: canvasSize
            )
            let resolvedCenter = CGPoint(x: position.x * canvasSize.width, y: position.y * canvasSize.height)
            if hypot(resolvedCenter.x - control.center.x, resolvedCenter.y - control.center.y) > 0.01 {
                customization.setPosition(position, for: control.id)
                changed = true
            }
        }
        return changed
    }

    private static func placeErgonomicCluster(
        _ controls: [GamepadResolvedControl],
        anchor: CGPoint,
        movementCluster: Bool,
        canvasSize: CGSize,
        customization: inout GamepadCustomization
    ) -> Bool {
        guard !controls.isEmpty else { return false }
        let maxDimension = controls.map { max($0.size.width, $0.size.height) }.max() ?? 44
        let step = maxDimension + GamepadLayoutQualityReport.runtimeHitOutset * 2 + 2
        let pattern: [CGPoint] = movementCluster
            ? [CGPoint(x: 0, y: -1), CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]
            : [CGPoint(x: 0, y: 1), CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1)]
        var changed = false
        for (index, control) in controls.enumerated() {
            let ring = index / pattern.count
            let base = pattern[index % pattern.count]
            let multiplier = CGFloat(ring + 1)
            let proposed = CGPoint(x: anchor.x + base.x * step * multiplier, y: anchor.y + base.y * step * multiplier)
            let position = GamepadLayoutResolver.normalizedPosition(for: proposed, visualSize: control.size, in: canvasSize)
            let resolvedCenter = CGPoint(x: position.x * canvasSize.width, y: position.y * canvasSize.height)
            if hypot(resolvedCenter.x - control.center.x, resolvedCenter.y - control.center.y) > 0.01 {
                customization.setPosition(position, for: control.id)
                changed = true
            }
        }
        return changed
    }

    private func validateDuplicationCapacity(_ kinds: [GamepadCustomControlKind]) throws {
        let controlKinds = controlKindsByID
        guard controlKinds.count + kinds.count <= Self.maximumCustomButtons else {
            throw GamepadSharedOperationError.customControlLimitReached
        }
        let existingKinds = Dictionary(grouping: Array(controlKinds.values), by: { $0 }).mapValues(\.count)
        let addedKinds = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
        let limits: [(GamepadCustomControlKind, Int)] = [
            (.joystick, Self.maximumJoysticks),
            (.trigger, Self.maximumTriggers),
            (.trackpad, Self.maximumTrackpads)
        ]
        for (kind, limit) in limits where (existingKinds[kind] ?? 0) + (addedKinds[kind] ?? 0) > limit {
            throw GamepadSharedOperationError.specializedControlLimitReached(kind)
        }
    }

    private static func offsetCoordinate(_ value: CGFloat, by offset: CGFloat) -> CGFloat {
        guard value.isFinite, offset.isFinite else { return value }
        return min(max(value + offset, 0), 1)
    }

    private static func supportsPositionOperations(_ identity: GamepadControlIdentity) -> Bool {
        switch identity {
        case .builtin, .custom, .system: true
        case .controlBarItem: false
        }
    }
}

struct GamepadLayoutRepairResult: Codable, Equatable {
    var repair: GamepadLayoutRepairKind
    var changedControlIDs: [String]
    var skippedLockedControlIDs: [String]
    var issueCountBefore: Int
    var issueCountAfter: Int

    var didChange: Bool { !changedControlIDs.isEmpty }
}

enum GamepadLayoutRepairTarget: Equatable, Sendable {
    case all
    case repair(GamepadLayoutRepairKind)
}

/// Heap-backed orchestration state keeps the three-pass quality workspace off
/// constrained callers' stacks while preserving the standalone CLI's ordering.
private final class GamepadLayoutRepairWorkspace {
    var results: [GamepadLayoutRepairResult] = []
}

extension GamepadCustomization {
    /// Canonical deterministic repair entry point shared by the standalone CLI
    /// and constrained configuration bridge. Issue-specific CLI aliases remain
    /// a CLI-only convenience and are intentionally not part of this contract.
    @discardableResult
    mutating func applyLayoutRepairs(
        target: GamepadLayoutRepairTarget,
        canvasSize: CGSize? = nil,
        respectingLocks: Bool = true
    ) -> [GamepadLayoutRepairResult] {
        let effectiveCanvasSize = canvasSize ?? deviceCanvas.editorDeviceFrame.screenRect.size
        let workspace = GamepadLayoutRepairWorkspace()
        switch target {
        case .repair(let repair):
            workspace.results.append(applyLayoutRepair(
                repair,
                issue: nil,
                canvasSize: effectiveCanvasSize,
                respectingLocks: respectingLocks
            ))
        case .all:
            for _ in 0..<3 {
                let currentReport = layoutQualityReport(canvasSize: effectiveCanvasSize)
                let orderedIssues = currentReport.issues.enumerated().sorted { lhs, rhs in
                    let lhsPriority = Self.layoutRepairPriority(for: lhs.element.code)
                    let rhsPriority = Self.layoutRepairPriority(for: rhs.element.code)
                    return lhsPriority == rhsPriority ? lhs.offset < rhs.offset : lhsPriority < rhsPriority
                }.map(\.element)
                var changedThisPass = false
                var appliedAutoArrange = false
                for issue in orderedIssues {
                    guard let repair = issue.suggestedRepairs.first else { continue }
                    if repair == .autoArrange {
                        guard !appliedAutoArrange else { continue }
                        appliedAutoArrange = true
                    }
                    let result = applyLayoutRepair(
                        repair,
                        issue: repair == .autoArrange ? nil : issue,
                        canvasSize: effectiveCanvasSize,
                        respectingLocks: respectingLocks
                    )
                    workspace.results.append(result)
                    changedThisPass = changedThisPass || result.didChange
                }
                if !changedThisPass { break }
            }
        }
        return workspace.results
    }

    private static func layoutRepairPriority(for issueCode: String) -> Int {
        switch issueCode {
        case "no-visible-controls": 0
        case "small-control": 1
        case "layout-displacement", "edge-hugging-control": 2
        case "control-overlap", "expanded-hit-overlap", "hit-region-z-order-ambiguous", "hit-region-z-order-mismatch": 3
        case "primary-control-too-high", "primary-control-too-central", "primary-control-out-of-reach", "portrait-primary-action-distribution", "portrait-dead-space": 4
        case "underused-bottom-space", "low-vertical-coverage", "low-horizontal-coverage": 5
        default: 6
        }
    }

    @discardableResult
    mutating func applyLayoutRepair(
        _ repair: GamepadLayoutRepairKind,
        issue: GamepadLayoutIssue? = nil,
        canvasSize: CGSize? = nil,
        respectingLocks: Bool = true
    ) -> GamepadLayoutRepairResult {
        let effectiveCanvasSize = canvasSize ?? deviceCanvas.editorDeviceFrame.screenRect.size
        let beforeReport = layoutQualityReport(canvasSize: effectiveCanvasSize)
        let requestedIDs = Set((issue?.controls ?? []).compactMap(GamepadControlIdentity.init(stableID:)))
        var changedIDs = Set<GamepadControlIdentity>()
        var skippedLockedIDs = Set<GamepadControlIdentity>()

        switch repair {
        case .showDefaultControls:
            let existingIDs = Set(elements.map(\.inputID))
            installDefaultControls()
            for button in DefaultKeypadElements.ids {
                guard elements.contains(where: { $0.inputID == button && $0.kind == .button }) else { continue }
                var layout = buttonCustomization(for: button)
                guard layout.isHidden || !existingIDs.contains(button) else { continue }
                layout.isHidden = false
                setButtonCustomization(layout, for: button)
                changedIDs.insert(.builtin(button))
            }

        case .minimumTouchTarget:
            let controls = repairControls(in: effectiveCanvasSize, requestedIDs: requestedIDs)
            for control in controls where !control.isDecoration {
                if respectingLocks && control.isLocationLocked {
                    skippedLockedIDs.insert(control.id)
                    continue
                }
                let targetWidth = min(effectiveCanvasSize.width, max(44, control.size.width))
                let targetHeight = min(effectiveCanvasSize.height, max(44, control.size.height))
                guard targetWidth > control.size.width + 0.001 || targetHeight > control.size.height + 0.001 else { continue }
                updateRepairLayout(for: control.id) { layout in
                    layout.widthScale *= targetWidth / max(control.size.width, 0.001)
                    layout.heightScale *= targetHeight / max(control.size.height, 0.001)
                }
                let center = GamepadLayoutResolver.normalizedPosition(
                    for: control.center,
                    visualSize: CGSize(width: targetWidth, height: targetHeight),
                    in: effectiveCanvasSize
                )
                setPosition(center, for: control.id)
                changedIDs.insert(control.id)
            }

        case .moveInsideSafeArea:
            let controls = repairControls(in: effectiveCanvasSize, requestedIDs: requestedIDs)
            let inset = min(12, max(2, min(effectiveCanvasSize.width, effectiveCanvasSize.height) * 0.03))
            for control in controls where !control.isDecoration {
                if respectingLocks && control.isLocationLocked {
                    skippedLockedIDs.insert(control.id)
                    continue
                }
                let center = CGPoint(
                    x: Self.safeCenterCoordinate(
                        control.center.x,
                        itemLength: control.size.width,
                        canvasLength: effectiveCanvasSize.width,
                        inset: inset
                    ),
                    y: Self.safeCenterCoordinate(
                        control.center.y,
                        itemLength: control.size.height,
                        canvasLength: effectiveCanvasSize.height,
                        inset: inset
                    )
                )
                guard hypot(center.x - control.center.x, center.y - control.center.y) > 0.001 else { continue }
                setPosition(
                    CGPoint(
                        x: center.x / max(effectiveCanvasSize.width, 1),
                        y: center.y / max(effectiveCanvasSize.height, 1)
                    ),
                    for: control.id
                )
                changedIDs.insert(control.id)
            }

        case .resolveOverlap:
            let allControls = resolvedControls(in: effectiveCanvasSize).filter { !$0.isDecoration }
            let candidates = repairControls(in: effectiveCanvasSize, requestedIDs: requestedIDs).filter { !$0.isDecoration }
            let hasLockedCandidate = respectingLocks && candidates.contains(where: \.isLocationLocked)
            var stationaryFrames = allControls.filter { control in
                !candidates.contains(where: { $0.id == control.id })
                    || (respectingLocks && control.isLocationLocked)
            }.map(\.frame)

            for (index, control) in candidates.enumerated() {
                if respectingLocks && control.isLocationLocked {
                    skippedLockedIDs.insert(control.id)
                    continue
                }
                // With two movable controls, preserve the first. If one issue control
                // is locked, move every unlocked candidate around the locked obstacle.
                if index == 0, requestedIDs.count > 1, !hasLockedCandidate {
                    stationaryFrames.append(control.frame)
                    continue
                }
                guard let frame = GamepadLayoutResolver.nonOverlappingFrame(
                    for: control.frame,
                    avoiding: stationaryFrames,
                    in: effectiveCanvasSize
                ) else {
                    stationaryFrames.append(control.frame)
                    continue
                }
                stationaryFrames.append(frame)
                guard hypot(frame.midX - control.frame.midX, frame.midY - control.frame.midY) > 0.001 else { continue }
                setPosition(
                    CGPoint(
                        x: frame.midX / max(effectiveCanvasSize.width, 1),
                        y: frame.midY / max(effectiveCanvasSize.height, 1)
                    ),
                    for: control.id
                )
                changedIDs.insert(control.id)
            }

        case .autoArrange:
            let allControls = resolvedControls(in: effectiveCanvasSize).filter { !$0.isDecoration }
            let candidates = allControls.filter { requestedIDs.isEmpty || requestedIDs.contains($0.id) }
            let unlocked = candidates.filter { control in
                if respectingLocks && control.isLocationLocked {
                    skippedLockedIDs.insert(control.id)
                    return false
                }
                return true
            }
            guard let sourceBounds = Self.unionFrame(unlocked.map(\.frame)), !unlocked.isEmpty else { break }
            let padding = min(24, max(10, min(effectiveCanvasSize.width, effectiveCanvasSize.height) * 0.06))
            var placedFrames = allControls.filter { control in
                !unlocked.contains(where: { $0.id == control.id })
            }.map(\.frame)

            for (index, control) in unlocked.enumerated() {
                let xProgress = sourceBounds.width > 1
                    ? (control.center.x - sourceBounds.minX) / sourceBounds.width
                    : CGFloat(index + 1) / CGFloat(unlocked.count + 1)
                let yProgress = sourceBounds.height > 1
                    ? (control.center.y - sourceBounds.minY) / sourceBounds.height
                    : CGFloat((index % 2) + 1) / 3
                let minCenterX = padding + control.size.width / 2
                let maxCenterX = max(minCenterX, effectiveCanvasSize.width - padding - control.size.width / 2)
                let minCenterY = padding + control.size.height / 2
                let maxCenterY = max(minCenterY, effectiveCanvasSize.height - padding - control.size.height / 2)
                let proposedCenter = CGPoint(
                    x: minCenterX + min(max(xProgress, 0), 1) * (maxCenterX - minCenterX),
                    y: minCenterY + min(max(yProgress, 0), 1) * (maxCenterY - minCenterY)
                )
                let proposedFrame = CGRect(
                    x: proposedCenter.x - control.size.width / 2,
                    y: proposedCenter.y - control.size.height / 2,
                    width: control.size.width,
                    height: control.size.height
                )
                let arrangedFrame = GamepadLayoutResolver.nonOverlappingFrame(
                    for: proposedFrame,
                    avoiding: placedFrames,
                    in: effectiveCanvasSize
                ) ?? proposedFrame
                placedFrames.append(arrangedFrame)
                guard hypot(arrangedFrame.midX - control.center.x, arrangedFrame.midY - control.center.y) > 0.001 else { continue }
                setPosition(
                    CGPoint(
                        x: arrangedFrame.midX / max(effectiveCanvasSize.width, 1),
                        y: arrangedFrame.midY / max(effectiveCanvasSize.height, 1)
                    ),
                    for: control.id
                )
                changedIDs.insert(control.id)
            }

        case .separateExpandedHitTargets:
            let candidates = repairControls(in: effectiveCanvasSize, requestedIDs: requestedIDs)
                .filter { !$0.isDecoration }
            for control in candidates where respectingLocks && control.isLocationLocked {
                skippedLockedIDs.insert(control.id)
            }
            let candidateIDs = Set(candidates.map(\.id))
            let beforeCenters = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.center) })
            if separateExpandedHitTargets(
                in: effectiveCanvasSize,
                controlIDs: candidateIDs,
                respectingLocks: respectingLocks
            ) {
                for control in resolvedControls(in: effectiveCanvasSize) {
                    guard let before = beforeCenters[control.id],
                          hypot(control.center.x - before.x, control.center.y - before.y) > 0.001
                    else { continue }
                    changedIDs.insert(control.id)
                }
            }

        case .ergonomicAutoArrange:
            let candidates = repairControls(in: effectiveCanvasSize, requestedIDs: requestedIDs)
                .filter {
                    let role = GamepadLayoutErgonomicRole.role(for: $0)
                    return role == .movement || role == .action
                }
            for control in candidates where respectingLocks && control.isLocationLocked {
                skippedLockedIDs.insert(control.id)
            }
            let candidateIDs = Set(candidates.map(\.id))
            let beforeCenters = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0.center) })
            if ergonomicallyAutoArrange(
                in: effectiveCanvasSize,
                controlIDs: candidateIDs,
                respectingLocks: respectingLocks
            ) {
                for control in resolvedControls(in: effectiveCanvasSize) {
                    guard let before = beforeCenters[control.id],
                          hypot(control.center.x - before.x, control.center.y - before.y) > 0.001
                    else { continue }
                    changedIDs.insert(control.id)
                }
            }
        }

        self = normalized
        let afterReport = layoutQualityReport(canvasSize: effectiveCanvasSize)
        return GamepadLayoutRepairResult(
            repair: repair,
            changedControlIDs: changedIDs.map(\.id).sorted(),
            skippedLockedControlIDs: skippedLockedIDs.map(\.id).sorted(),
            issueCountBefore: beforeReport.issues.count,
            issueCountAfter: afterReport.issues.count
        )
    }

    private func repairControls(
        in canvasSize: CGSize,
        requestedIDs: Set<GamepadControlIdentity>
    ) -> [GamepadResolvedControl] {
        resolvedControls(in: canvasSize).filter { requestedIDs.isEmpty || requestedIDs.contains($0.id) }
    }

    private mutating func updateRepairLayout(
        for identity: GamepadControlIdentity,
        mutate: (inout GamepadButtonCustomization) -> Void
    ) {
        switch identity {
        case .builtin(let button):
            var layout = buttonCustomization(for: button)
            mutate(&layout)
            setButtonCustomization(layout.normalized, for: button)
        case .custom(let id):
            guard let index = customButtons.firstIndex(where: { $0.id == id }) else { return }
            mutate(&customButtons[index].layout)
            customButtons[index].layout = customButtons[index].layout.normalized
        case .system(.topBarActivation):
            mutate(&topBarActivationRegion)
            topBarActivationRegion = topBarActivationRegion.normalized
        case .controlBarItem:
            break
        }
    }

    private static func safeCenterCoordinate(
        _ value: CGFloat,
        itemLength: CGFloat,
        canvasLength: CGFloat,
        inset: CGFloat
    ) -> CGFloat {
        let lower = inset + itemLength / 2
        let upper = canvasLength - inset - itemLength / 2
        guard lower <= upper else { return canvasLength / 2 }
        return min(max(value, lower), upper)
    }

    private static func unionFrame(_ frames: [CGRect]) -> CGRect? {
        guard let first = frames.first else { return nil }
        return frames.dropFirst().reduce(first) { $0.union($1) }
    }
}

public extension GamepadConfigurationProfile {
    /// Copies a complete orientation variant and rotates its control positions into
    /// the destination canvas. Source and destination variants remain independently saved.
    mutating func copyLayoutVariant(
        from sourceVariant: GamepadProfileLayoutVariant,
        to destinationVariant: GamepadProfileLayoutVariant,
        automaticallyArrange: Bool = true
    ) {
        let sourceOrientation = sourceVariant.editorOrientation
        let destinationOrientation = destinationVariant.editorOrientation
        let sourceExists = hasCustomizationVariant(for: sourceOrientation)
            || customization.deviceCanvas.editorDeviceFrame.orientation == sourceOrientation
        guard sourceExists else { return }
        let source = customization(for: sourceOrientation)
        var destination = source

        let sourceFrame = source.deviceCanvas.editorDeviceFrame
        let destinationFrame = GamepadEditorDeviceFrame(spec: sourceFrame.spec, orientation: destinationOrientation)
        destination.deviceCanvas = GamepadDeviceCanvas(frameID: destinationFrame.id)

        if automaticallyArrange, sourceOrientation != destinationOrientation {
            let controls = source.resolvedControls(in: sourceFrame.screenRect.size)
            for control in controls {
                let transformed = Self.transformedPosition(
                    control.normalizedCenter,
                    from: sourceVariant,
                    to: destinationVariant
                )
                destination.setPosition(transformed, for: control.id)
            }
            if var metadata = destination.designMetadata {
                metadata.guides = metadata.guides.map { guide in
                    var transformed = guide
                    transformed.orientation = guide.orientation == .horizontal ? .vertical : .horizontal
                    if sourceVariant == .landscape && destinationVariant == .portrait {
                        transformed.position = guide.orientation == .vertical ? guide.position : 1 - guide.position
                    } else {
                        transformed.position = guide.orientation == .horizontal ? guide.position : 1 - guide.position
                    }
                    return transformed
                }
                destination.designMetadata = metadata.normalized(availableControls: destination.allControlIdentitiesForDesign)
            }
            // Prefer the source top inset, but move the passive control-bar toggle into the
            // nearest quiet center lane when a portrait face cluster would overlap it.
            destination.topBarActivationRegion.centerX = 0.5
            destination.topBarActivationRegion.centerY = source.topBarActivationRegion.centerY
            if destinationOrientation == .portrait {
                Self.resolvePortraitSystemControlCollision(in: &destination)
            }
        }

        destination = destination.normalized
        switch sourceVariant {
        case .landscape:
            if landscapeCustomization == nil { landscapeCustomization = source }
        case .portrait:
            if portraitCustomization == nil { portraitCustomization = source }
        }
        switch destinationVariant {
        case .landscape: landscapeCustomization = destination
        case .portrait: portraitCustomization = destination
        }
        customization = destination
        updatedAt = Date.currentMilliseconds
    }

    private static func resolvePortraitSystemControlCollision(in customization: inout GamepadCustomization) {
        let canvasSize = customization.deviceCanvas.editorDeviceFrame.screenRect.size
        func hasCollision() -> Bool {
            let controls = customization.resolvedControls(in: canvasSize)
            guard let system = controls.first(where: { $0.id == .system(.topBarActivation) }) else { return false }
            return controls.contains { control in
                control.id != system.id
                    && !control.isDecoration
                    && system.frame.insetBy(dx: -6, dy: -6).intersects(control.frame)
            }
        }
        guard hasCollision() else { return }
        for candidateY in [CGFloat(0.32), 0.50, 0.68] {
            customization.topBarActivationRegion.centerY = candidateY
            if !hasCollision() { return }
        }
    }

    private static func transformedPosition(
        _ position: CGPoint,
        from source: GamepadProfileLayoutVariant,
        to destination: GamepadProfileLayoutVariant
    ) -> CGPoint {
        guard source != destination else { return position }
        switch (source, destination) {
        case (.landscape, .portrait):
            return CGPoint(x: position.y, y: 1 - position.x)
        case (.portrait, .landscape):
            return CGPoint(x: 1 - position.y, y: position.x)
        default:
            return position
        }
    }
}
