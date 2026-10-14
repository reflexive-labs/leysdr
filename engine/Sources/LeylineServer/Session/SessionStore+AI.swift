// SPDX-License-Identifier: GPL-3.0-or-later

// Keys and feature models on the event plane (docs/dev/engine-internals.md, "Credentials and
// usage"). `CredentialStore` owns them; the store publishes them like any other state, the whole
// `AIState` every time, so a deleted key is a shorter list and needs no tombstone (invariant 6).

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
}
