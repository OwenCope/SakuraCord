import AppIntents
import CoreSpotlight
import Foundation
import SakuraCordModels
import UniformTypeIdentifiers

nonisolated struct ConversationEntity: AppEntity, IndexedEntity, Equatable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Conversation")
    static let defaultQuery = ConversationQuery()

    var id: ChannelID
    var title: String
    var subtitle: String?

    var displayString: String {
        title
    }

    var displayRepresentation: DisplayRepresentation {
        if let subtitle {
            DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
        } else {
            DisplayRepresentation(title: "\(title)")
        }
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.displayName = title
        if let subtitle {
            attributes.contentDescription = subtitle
        }
        return attributes
    }
}

nonisolated struct ConversationQuery: EntityQuery, EntityStringQuery, Sendable {
    func entities(for identifiers: [ChannelID]) async throws -> [ConversationEntity] {
        await Self.resolve(identifiers)
    }

    /// Saved shortcuts resolve their conversation on a cold launch, so wait for
    /// the restored workspace before looking it up.
    @MainActor
    private static func resolve(_ identifiers: [ChannelID]) async -> [ConversationEntity] {
        _ = await IntentModelAccess.workspaceModel()
        let requested = Set(identifiers)
        return IntentConversationCatalog.current().filter { requested.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        await MainActor.run {
            IntentConversationCatalog.recent(limit: 20)
        }
    }

    func entities(matching string: String) async throws -> [ConversationEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return await MainActor.run {
            guard !query.isEmpty else {
                return IntentConversationCatalog.recent(limit: 20)
            }
            return IntentConversationCatalog.current().filter {
                $0.title.localizedCaseInsensitiveContains(query)
            }.prefix(20).map { $0 }
        }
    }
}

// Lets ChannelID be an AppEntity identifier; App Intents persists it as the
// snowflake's decimal string.
extension Snowflake: @retroactive EntityIdentifierConvertible where Kind == ChannelKind {
    public var entityIdentifierString: String {
        description
    }

    public static func entityIdentifier(for entityIdentifierString: String) -> Snowflake<ChannelKind>? {
        Snowflake(entityIdentifierString)
    }
}

@MainActor
enum IntentConversationCatalog {
    private static var spotlightIndexTask: Task<Void, Never>?
    private static var pendingSignature: [ConversationEntity]?
    /// What Spotlight currently holds, and for which account session.
    private static var indexedEntities: [ChannelID: ConversationEntity] = [:]
    private static var indexedSessionGeneration: UInt64?

    /// Mirrors the conversation catalog into Spotlight. Coalesced because
    /// snapshots change in bursts during bootstrap, and only the difference
    /// from what is already indexed is written.
    static func scheduleSpotlightIndex(for model: AppModel) {
        guard SakuraCordRuntimeModelHolder.shared.model === model,
              model.launchMode == .normal,
              ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1"
        else { return }
        guard model.sessionState == .workspace, model.snapshot != nil else {
            clearSpotlightIndex()
            return
        }
        let entities = current().sorted { $0.id.description < $1.id.description }
        guard entities != pendingSignature else { return }
        pendingSignature = entities
        let session = model.accountSession()
        spotlightIndexTask?.cancel()
        spotlightIndexTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard model.isCurrentAccountSession(session) else {
                pendingSignature = nil
                return
            }
            let index = CSSearchableIndex.default()
            let sameAccount = indexedSessionGeneration == session.generation
            let previous = sameAccount ? indexedEntities : [:]
            let latest = Dictionary(uniqueKeysWithValues: entities.map { ($0.id, $0) })
            if sameAccount {
                let removed = previous.keys.filter { latest[$0] == nil }
                if !removed.isEmpty {
                    try? await index.deleteAppEntities(identifiedBy: removed, ofType: ConversationEntity.self)
                }
            } else {
                try? await index.deleteAppEntities(ofType: ConversationEntity.self)
            }
            guard !Task.isCancelled, model.isCurrentAccountSession(session) else {
                // Spotlight may now hold a partial update; rebuild from scratch.
                indexedSessionGeneration = nil
                pendingSignature = nil
                return
            }
            let changed = entities.filter { previous[$0.id] != $0 }
            if !changed.isEmpty {
                try? await index.indexAppEntities(changed)
            }
            indexedEntities = latest
            indexedSessionGeneration = session.generation
        }
    }

    /// Sign-out and account switches drop everything indexed for the old account.
    private static func clearSpotlightIndex() {
        spotlightIndexTask?.cancel()
        spotlightIndexTask = nil
        pendingSignature = nil
        guard indexedSessionGeneration != nil || !indexedEntities.isEmpty else { return }
        indexedEntities = [:]
        indexedSessionGeneration = nil
        Task {
            try? await CSSearchableIndex.default().deleteAppEntities(ofType: ConversationEntity.self)
        }
    }

    static func current() -> [ConversationEntity] {
        guard let model = SakuraCordRuntimeModelHolder.shared.model else {
            return []
        }
        var seen = Set<ChannelID>()
        var result: [ConversationEntity] = []
        // visibleChannels is already permission-filtered; raw snapshot channels
        // must pass the same view check the forward picker uses.
        let snapshotChannels = (model.snapshot?.channels ?? []).filter {
            model.canSearchForwardDestination($0)
        }
        for channel in model.visibleChannels + snapshotChannels {
            guard channel.kind != .unknown,
                  seen.insert(channel.id).inserted
            else { continue }
            result.append(entity(for: channel, model: model))
        }
        return result
    }

    static func recent(limit: Int) -> [ConversationEntity] {
        guard let model = SakuraCordRuntimeModelHolder.shared.model else {
            return []
        }
        let catalog = Dictionary(uniqueKeysWithValues: current().map { ($0.id, $0) })
        var ordered: [ConversationEntity] = []
        var seen = Set<ChannelID>()
        if let selected = model.selectedChannelID,
           let entity = catalog[selected]
        {
            ordered.append(entity)
            seen.insert(selected)
        }
        for channelID in model.forwardDestinationHistory {
            guard seen.insert(channelID).inserted,
                  let entity = catalog[channelID]
            else { continue }
            ordered.append(entity)
        }
        ordered.append(
            contentsOf: catalog.values
                .filter { seen.insert($0.id).inserted }
                .sorted { $0.title < $1.title }
        )
        return Array(ordered.prefix(limit))
    }

    private static func entity(for channel: Channel, model: AppModel) -> ConversationEntity {
        let guildName = channel.guildID.flatMap { guildID in
            model.serverRailGuildsByID[guildID]?.name
                ?? model.snapshot?.guilds.first { $0.id == guildID }?.name
        }
        return ConversationEntity(
            id: channel.id,
            title: title(for: channel),
            subtitle: subtitle(for: channel, guildName: guildName)
        )
    }

    private static func title(for channel: Channel) -> String {
        switch channel.kind {
        case .directMessage, .groupDirectMessage:
            if channel.hasExplicitName, !channel.name.isEmpty {
                return channel.name
            }
            let names = channel.recipients.map(\.displayName).filter { !$0.isEmpty }
            return names.isEmpty ? channel.name : names.joined(separator: ", ")
        default:
            return channel.guildID == nil ? channel.name : "#\(channel.name)"
        }
    }

    private static func subtitle(for channel: Channel, guildName: String?) -> String? {
        switch channel.kind {
        case .directMessage:
            "Direct Message"
        case .groupDirectMessage:
            "Group Direct Message"
        default:
            guildName
        }
    }
}
