// SPDX-License-Identifier: GPL-3.0-or-later

// leyline.v1.Assistant: the assistant's conversations over the socket (docs/dev/engine-internals.md,
// "Assistant"). `ConversationStore` holds them and runs their workers; this file maps the RPCs onto
// it. Any client may watch, answer, end or delete any conversation, so `ley ask --continue` picks up one
// the app started. Every reply is the conversation's whole state after the call, the same state
// `Event.conversation` carries (invariant 6).

import EngineCore
import Foundation
import GRPCCore
import LeylineProto

struct AssistantService: Leyline_V1_Assistant.SimpleServiceProtocol {
    let conversations: ConversationStore
    let store: SessionStore

    func startConversation(request: Leyline_V1_StartConversationRequest, context _: ServerContext) async throws -> Leyline_V1_Conversation {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors { try await conversations.start(request, by: client) }
    }

    func sendMessage(request: Leyline_V1_SendMessageRequest, context _: ServerContext) async throws -> Leyline_V1_Conversation {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors { try await conversations.send(request.conversationID, text: request.text, by: client) }
    }

    /// Ends after it delivers ENDED or FAILED, when the client goes, or at the daemon's shutdown.
    func watchConversation(request: Leyline_V1_WatchConversationRequest, response: RPCWriter<Leyline_V1_Conversation>,
                           context _: ServerContext) async throws
    {
        let client = ClientContext.current
        let updates = try await mapErrors { try await conversations.watch(request.conversationID, sinceSeq: request.sinceSeq) }
        await store.streamOpened(client)
        defer { Task { await store.streamClosed(client) } }
        // RPC cancellation is not task cancellation in grpc-swift; the drain is a child task that
        // either ends, as `ControlService.watchEvents` explains.
        let drain = Task {
            for await conversation in updates {
                try await response.write(conversation)
            }
        }
        try await withRPCCancellationHandler {
            try await withTaskCancellationHandler {
                try await drain.value
            } onCancel: {
                drain.cancel()
            }
        } onCancelRPC: {
            drain.cancel()
        }
    }

    func resolveAction(request: Leyline_V1_ResolveActionRequest, context _: ServerContext) async throws -> Leyline_V1_Conversation {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors {
            try await conversations.resolve(request.conversationID, callID: request.callID, approve: request.approve, by: client)
        }
    }

    func answerViewTool(request: Leyline_V1_AnswerViewToolRequest, context _: ServerContext) async throws -> Leyline_V1_Conversation {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors { try await conversations.answerView(request, by: client) }
    }

    func stopTurn(request: Leyline_V1_ConversationRef, context _: ServerContext) async throws -> Leyline_V1_Conversation {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors { try await conversations.stopTurn(request.conversationID, by: client) }
    }

    func endConversation(request: Leyline_V1_ConversationRef, context _: ServerContext) async throws -> Leyline_V1_Conversation {
        let client = ClientContext.current
        await store.touchUnary(client)
        return try await mapErrors { try await conversations.end(request.conversationID, by: client) }
    }

    func listConversations(request _: Leyline_V1_ListConversationsRequest, context _: ServerContext) async throws -> Leyline_V1_ListConversationsResponse {
        await store.touchUnary(ClientContext.current)
        var response = Leyline_V1_ListConversationsResponse()
        response.conversations = await conversations.list()
        return response
    }

    /// Ends a conversation still going, then removes it and its files.
    func deleteConversation(request: Leyline_V1_ConversationRef, context _: ServerContext) async throws -> Leyline_V1_Empty {
        let client = ClientContext.current
        await store.touchUnary(client)
        try await mapErrors { try await conversations.delete(request.conversationID, by: client) }
        return Leyline_V1_Empty()
    }
}
