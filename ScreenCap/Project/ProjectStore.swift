import Foundation
import ScreenCapCore

/// A `.reel` recording: a folder holding the raw tracks, the event log and the edit decisions.
/// Raw media is written once by the recorder; the editor only ever writes `edits.json`.
struct ReelBundle: Hashable, Sendable {
    let url: URL

    var screen: URL { url.appending(path: "screen.mov") }
    var camera: URL { url.appending(path: "camera.mov") }
    var mic: URL { url.appending(path: "mic.mov") }
    var systemAudio: URL { url.appending(path: "system.mov") }
    var events: URL { url.appending(path: "events.jsonl") }
    var infoFile: URL { url.appending(path: "project.json") }
    var editsFile: URL { url.appending(path: "edits.json") }

    var name: String { url.deletingPathExtension().lastPathComponent }

    func has(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    func loadInfo() throws -> ProjectInfo {
        try ReelJSON.decode(ProjectInfo.self, from: Data(contentsOf: infoFile))
    }

    func save(_ info: ProjectInfo) throws {
        try ReelJSON.encode(info).write(to: infoFile, options: .atomic)
    }

    func loadEdits() -> EditDecisions? {
        (try? Data(contentsOf: editsFile)).flatMap { try? ReelJSON.decode(EditDecisions.self, from: $0) }
    }

    func save(_ edits: EditDecisions) throws {
        try ReelJSON.encode(edits).write(to: editsFile, options: .atomic)
    }

    func loadEvents() -> [RecordedEvent] {
        (try? Data(contentsOf: events)).map(EventLog.parse) ?? []
    }
}

enum ProjectStore {
    /// ~/Movies/ScreenCap
    static var folder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies")
        return movies.appending(path: "ScreenCap")
    }

    static func create(info: ProjectInfo) throws -> ReelBundle {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let bundle = ReelBundle(url: folder.appending(path: "Recording \(formatter.string(from: info.createdAt)).reel"))
        try FileManager.default.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        try bundle.save(info)
        return bundle
    }

    /// Recordings in the default folder, newest first.
    static func all() -> [ReelBundle] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "reel" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .map(ReelBundle.init)
    }

    /// Recordings whose project file still says `recording`: the app died before stopping them.
    static func unfinished() -> [ReelBundle] {
        all().filter { (try? $0.loadInfo())?.state == .recording && $0.has($0.screen) }
    }
}
