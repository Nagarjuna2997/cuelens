import Foundation

struct Workspace: Codable {
    var assistants = [AssistantProfile]()
    var preferences = Preferences()
    var shareChecks: [ShareCheck]?
    var overlay: OverlayPreferences?
}

struct Vault {
    let directory: URL
    private let files = FileManager.default

    static func live() -> Self {
        #if DEBUG
        if let value = ProcessInfo.processInfo.environment["CUELENS_TEST_WORKSPACE"],
           let id = UUID(uuidString: value) {
            return Self(directory: FileManager.default.temporaryDirectory.appending(path: id.uuidString))
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(directory: support.appendingPathComponent("CueLens", isDirectory: true))
    }

    func load() throws -> Workspace {
        let url = directory.appendingPathComponent("workspace.json")
        guard files.fileExists(atPath: url.path) else { return Workspace() }
        return try read(Workspace.self, from: url)
    }

    func save(_ workspace: Workspace) throws {
        try write(workspace, to: directory.appendingPathComponent("workspace.json"))
    }

    func sessions() throws -> [MeetingSession] {
        guard files.fileExists(atPath: sessionsDirectory.path) else { return [] }
        return try files.contentsOfDirectory(at: sessionsDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try read(MeetingSession.self, from: $0) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    func save(_ session: MeetingSession) throws {
        try write(session, to: sessionURL(session.id))
    }

    func deleteSession(_ id: UUID) throws {
        let audio = audioDirectory(id)
        if files.fileExists(atPath: audio.path) { try files.removeItem(at: audio) }
        let record = sessionURL(id)
        if files.fileExists(atPath: record.path) { try files.removeItem(at: record) }
    }

    func audioDirectory(_ id: UUID) -> URL {
        directory.appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private var sessionsDirectory: URL { directory.appendingPathComponent("Sessions", isDirectory: true) }

    private func sessionURL(_ id: UUID) -> URL {
        sessionsDirectory.appendingPathComponent(id.uuidString).appendingPathExtension("json")
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}
