import Foundation

/// A verified binary schema switch. enabledLabel describes the *engine's true value*.
public struct EngineOptionDescriptor: Identifiable, Equatable, Sendable {
    public let resourceID: String
    public let schemaID: String
    public let name: String
    public let title: String
    public let disabledLabel: String
    public let enabledLabel: String
    public var id: String { name }

    public init(
        resourceID: String, schemaID: String, name: String, title: String,
        disabledLabel: String, enabledLabel: String
    ) {
        self.resourceID = resourceID
        self.schemaID = schemaID
        self.name = name
        self.title = title
        self.disabledLabel = disabledLabel
        self.enabledLabel = enabledLabel
    }
}

public struct EngineOptionState: Identifiable, Equatable, Sendable {
    public let descriptor: EngineOptionDescriptor
    public let value: Bool
    public var id: String { descriptor.id }
    public init(descriptor: EngineOptionDescriptor, value: Bool) {
        self.descriptor = descriptor
        self.value = value
    }
}
