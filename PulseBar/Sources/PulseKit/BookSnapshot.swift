import Foundation

/// The reduced book, as the app last applied it: what outlives the event
/// log's rotation. Written by the app only (never a hook), private (0600),
/// atomically; read once at launch. A snapshot that does not decode, or of
/// another `version`, is ignored — the launch then replays the log alone.
///
/// It holds the book, the log it was reduced from (`gen`) and the last
/// `seq` applied, so the launch applies only the lines numbered past it,
/// and the connection facts Settings shows (the last line heard and the
/// last one not used, per agent). It is a cache of what the events said,
/// never a source: every fact in it came from a line.
package struct BookSnapshot: Codable, Equatable {
    /// Bumped whenever a stored type changes shape or meaning.
    package static let currentVersion = 2
    package static let fileName = "snapshot.json"

    package var version: Int
    package var gen: String
    package var seq: Int64
    package var book: SessionBook
    package var heard: [AgentID: Connection.Heard]
    package var ignored: [AgentID: Connection.Ignored]
    /// Every line the log was ever given had been applied.
    package var whole: Bool

    package init(
        gen: String, seq: Int64, book: SessionBook,
        heard: [AgentID: Connection.Heard], ignored: [AgentID: Connection.Ignored], whole: Bool
    ) {
        self.version = Self.currentVersion
        self.gen = gen
        self.seq = seq
        self.book = book
        self.heard = heard
        self.ignored = ignored
        self.whole = whole
    }

    package static var path: URL {
        EventLog.directory.appendingPathComponent(fileName)
    }

    /// The cursor the launch starts from: the snapshot's log and `seq`, and
    /// no header, so the first read takes the log whole and applies only
    /// what is past `seq`.
    package var cursor: EventLog.Cursor {
        EventLog.Cursor(header: "", offset: 0, gen: gen, seq: seq)
    }

    /// The bytes written. Nil when it cannot be encoded.
    package func encoded() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    /// The snapshot at `url`, or nil: missing, unreadable, another version.
    package static func load(at url: URL? = nil) -> BookSnapshot? {
        guard let data = try? Data(contentsOf: url ?? path) else { return nil }
        guard let snapshot = try? JSONDecoder().decode(BookSnapshot.self, from: data),
              snapshot.version == currentVersion
        else {
            DebugLog.write("snapshot ignored: not this version")
            return nil
        }
        return snapshot
    }

    /// Write `data` (an `encoded()` snapshot) privately and atomically.
    @discardableResult
    package static func write(_ data: Data, to url: URL? = nil) -> Bool {
        PrivateFile.write(data, to: url ?? path)
    }
}
