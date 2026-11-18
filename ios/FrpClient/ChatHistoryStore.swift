import Foundation

enum ChatMessageStatus: String, Codable { case complete, streaming, interrupted, failed }

struct ChatMessage: Identifiable, Codable, Equatable {
    var id = UUID()
    var role: ChatRole
    var content = ""
    var thinking = ""
    var status: ChatMessageStatus = .complete
    var createdAt = Date()
}

struct ChatConversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var slot: Int
    var identity: String
    var title = "新对话"
    var model = ""
    var createdAt = Date()
    var updatedAt = Date()
    var messages: [ChatMessage] = []
}

struct ChatHistoryDocument: Codable, Equatable {
    static let currentSchema = 1
    static let maximumConversations = 96
    static let maximumMessages = 512
    static let maximumFileBytes = 8_388_608
    var schemaVersion = Self.currentSchema
    var conversations: [ChatConversation] = []

    func validate() throws {
        guard schemaVersion == Self.currentSchema, conversations.count <= Self.maximumConversations,
              Set(conversations.map(\.id)).count == conversations.count else { throw ChatHistoryError.invalidData }
        for conversation in conversations {
            guard (0..<3).contains(conversation.slot), !conversation.identity.isEmpty,
                  conversation.identity.utf8.count <= 256, conversation.title.utf8.count <= 1024,
                  conversation.model.utf8.count <= 1024,
                  conversation.messages.count <= Self.maximumMessages,
                  Set(conversation.messages.map(\.id)).count == conversation.messages.count else {
                throw ChatHistoryError.invalidData
            }
            for message in conversation.messages {
                guard message.content.utf8.count <= OllamaNDJSONParser.maximumResponseBytes,
                      message.thinking.utf8.count <= OllamaNDJSONParser.maximumResponseBytes else {
                    throw ChatHistoryError.invalidData
                }
            }
        }
    }
}

enum ChatHistoryError: Error { case invalidData, tooLarge }

protocol ChatHistoryStore {
    func load() throws -> ChatHistoryDocument?
    func save(_ document: ChatHistoryDocument) throws
}

/// The chat archive contains conversations only, never relay credentials. It is
/// excluded from device backups, protected by iOS Data Protection and written
/// atomically so an interrupted write does not destroy the last saved archive.
final class FileChatHistoryStore: ChatHistoryStore {
    let url: URL

    init(url: URL? = nil) {
        if let url { self.url = url }
        else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.url = support.appendingPathComponent("LocalChats", isDirectory: true).appendingPathComponent("history.json")
        }
    }

    func load() throws -> ChatHistoryDocument? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let bytes = attributes[.size] as? NSNumber,
              bytes.int64Value <= Int64(ChatHistoryDocument.maximumFileBytes) else { throw ChatHistoryError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= ChatHistoryDocument.maximumFileBytes else { throw ChatHistoryError.tooLarge }
        let document = try JSONDecoder().decode(ChatHistoryDocument.self, from: data)
        try document.validate()
        return document
    }

    func save(_ document: ChatHistoryDocument) throws {
        try document.validate()
        let data = try JSONEncoder().encode(document)
        guard data.count <= ChatHistoryDocument.maximumFileBytes else { throw ChatHistoryError.tooLarge }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var backupExcludedDirectory = directory
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try backupExcludedDirectory.setResourceValues(resources)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var backupExcludedFile = url
        try backupExcludedFile.setResourceValues(resources)
    }
}
