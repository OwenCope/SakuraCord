import AppIntents
import Foundation
import SakuraCordModels

struct OpenConversationIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Conversation"
    static let description = IntentDescription("Opens a conversation in SakuraCord.")

    @Parameter(title: "Conversation")
    var target: ConversationEntity

    init() {}

    init(target: ConversationEntity) {
        self.target = target
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)")
    }

    func perform() async throws -> some IntentResult {
        let channelID = target.id
        try await Self.open(channelID)
        return .result()
    }

    @MainActor
    private static func open(_ channelID: ChannelID) async throws {
        try await IntentModelAccess.requireWorkspaceModel().navigate(to: channelID)
    }
}
