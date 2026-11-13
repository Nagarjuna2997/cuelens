import Foundation

struct Workspace: Codable {
    var assistants = [AssistantProfile]()
    var preferences = Preferences()
    var shareChecks: [ShareCheck]?
    var overlay: OverlayPreferences?
    var camera: CameraStudioSettings?
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
        try readHistory().sessions
    }

    func readHistory() throws -> (sessions: [MeetingSession], unreadableCount: Int) {
        guard files.fileExists(atPath: sessionsDirectory.path) else { return ([], 0) }
        let urls = try files.contentsOfDirectory(at: sessionsDirectory,
                                                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.pathExtension == "json" }
        var sessions = [MeetingSession]()
        var unreadable = 0
        for url in urls {
            do {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    unreadable += 1
                    continue
                }
                let session = try read(MeetingSession.self, from: url)
                guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) == session.id else {
                    unreadable += 1
                    continue
                }
                sessions.append(session)
            } catch {
                // One damaged record must not hide the remaining history. Keep it available for recovery.
                unreadable += 1
            }
        }
        return (sessions.sorted { $0.startedAt > $1.startedAt }, unreadable)
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

    func audioFiles(for id: UUID) throws -> [URL] {
        let folder = audioDirectory(id)
        guard files.fileExists(atPath: folder.path) else { return [] }
        let expected = directory.resolvingSymlinksInPath().appending(path: "Audio").appending(path: id.uuidString)
        // URL equality includes the directory hint's trailing slash. Compare filesystem
        // paths so a real session directory is accepted while redirected folders are not.
        guard folder.resolvingSymlinksInPath().standardizedFileURL.path == expected.standardizedFileURL.path else {
            throw CocoaError(.fileReadNoPermission)
        }
        let extensions: Set<String> = ["caf", "wav", "aiff", "m4a"]
        return try files.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { url in
                guard extensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
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
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
