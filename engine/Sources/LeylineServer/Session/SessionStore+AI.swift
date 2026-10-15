// SPDX-License-Identifier: GPL-3.0-or-later

// Keys, feature models, the ledger and the assistant's conversations on the event plane
// (docs/dev/engine-internals.md, "Credentials and usage" and "Assistant"). `CredentialStore`,
// `Ledger` and `ConversationStore` own them; the store publishes them like any other state, whole
// every time, so a deleted key is a shorter list and needs no tombstone (invariant 6).

import EngineCore
import Foundation
import LeylineProto

extension SessionStore {
    /// Installed by the daemon so `GetState` carries the keys and feature models.
    func setAIProvider(_ provider: @escaping @Sendable () async -> Leyline_V1_AIState) {
        aiProvider = provider
    }

    /// Publishes the credential store's current state, caused by `by`. Two changes can race here
    /// across the hop from the credential store, so a state no newer than the last one published
    /// is dropped: the newer one is already out, and it carries this change too.
    func publishAI(from credentials: CredentialStore, by: ClientContext) async {
        let (state, version) = await credentials.versioned()
        guard version > aiPublishedVersion else { return }
        aiPublishedVersion = version
        emit(.ai(state), captureID: nil, by: by)
    }

    /// Installed by the daemon so `GetState` carries the ledger's lines.
    func setUsageProvider(_ provider: @escaping @Sendable () async -> [Leyline_V1_UsageLine]) {
        usageProvider = provider
    }

    /// Publishes one ledger line after a report, unless a newer state of the same line is already
    /// out: two reports to one line race here the way two key changes do (`publishAI`).
    func publishUsage(_ line: Leyline_V1_UsageLine, version: UInt64, by: ClientContext) {
        let key = Ledger.key(of: line)
        guard version > usagePublishedVersions[key, default: 0] else { return }
        usagePublishedVersions[key] = version
        emit(.usage(line), captureID: nil, by: by)
    }

    /// Installed by the daemon so `GetState` carries the assistant's conversations.
    func setConversationsProvider(_ provider: @escaping @Sendable () async -> [Leyline_V1_Conversation]) {
        conversationsProvider = provider
    }

    /// Publishes one conversation, unless a newer state of it is already out: the conversation
    /// store's changes cross an actor hop to get here and can arrive out of order, as two key
    /// changes can (`publishAI`). Its own `seq` orders them.
    func publishConversation(_ conversation: Leyline_V1_Conversation, by: ClientContext) {
        let id = conversation.conversationID
        guard conversation.seq > conversationPublishedSeqs[id, default: 0] else { return }
        conversationPublishedSeqs[id] = conversation.seq
        emit(.conversation(conversation), captureID: nil, by: by)
    }

    /// Drops what `publishConversation` remembers of a conversation the store has forgotten.
    func forgetConversation(_ id: String) {
        conversationPublishedSeqs[id] = nil
    }
}
