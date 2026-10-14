import Foundation

/// Rewrite one member of a user's JSON config and leave every other
/// byte as they wrote it.
///
/// `JSONSerialization` round-trips lose key order, spacing and number
/// spelling, so an install used to rewrite the whole `settings.json` in its
/// own style. This reads the text with byte offsets — enough to find the
/// root object's `hooks` member, its events and their entries — and splices
/// one replacement into the original bytes. The caller validates the text
/// with `JSONSerialization` first; a shape this reader does not follow
/// throws, and the file is refused rather than guessed at.
package enum JSONSplice {
    package struct Malformed: Error {}
    /// `hooks`, or an event under it Pulse must add to, is not the
    /// documented shape (an object of arrays): refused, never guessed at.
    package struct UnexpectedShape: Error {}

    /// A leading UTF-8 byte-order mark, split off so the reader sees JSON
    /// and the writer can put it back.
    package static func splitBOM(_ text: String) -> (bom: String, body: String) {
        guard text.unicodeScalars.first == "\u{FEFF}" else { return ("", text) }
        return ("\u{FEFF}", String(String.UnicodeScalarView(text.unicodeScalars.dropFirst())))
    }

    /// Whether `text` has a `//` or `/* */` comment outside its strings.
    package static func hasComments(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        var index = 0
        var inString = false
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                if byte == UInt8(ascii: "\\") {
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") { inString = false }
            } else if byte == UInt8(ascii: "\"") {
                inString = true
            } else if byte == UInt8(ascii: "/"), index + 1 < bytes.count,
                      bytes[index + 1] == UInt8(ascii: "/") || bytes[index + 1] == UInt8(ascii: "*") {
                return true
            }
            index += 1
        }
        return false
    }

    package struct Member {
        package var key: String
        /// Offset of the key's opening quote.
        package var start: Int
        package var valueStart: Int
        /// One past the value's last byte.
        package var valueEnd: Int
    }

    package struct Reader {
        package let bytes: [UInt8]
        package var index = 0

        package init(_ bytes: [UInt8], at index: Int = 0) {
            self.bytes = bytes
            self.index = index
        }

        package static func isSpace(_ byte: UInt8) -> Bool {
            byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
        }

        package mutating func skipSpace() {
            while index < bytes.count, Self.isSpace(bytes[index]) { index += 1 }
        }

        package mutating func expect(_ byte: UInt8) throws {
            guard index < bytes.count, bytes[index] == byte else { throw Malformed() }
            index += 1
        }

        /// One value from here; its byte range.
        package mutating func skipValue() throws -> Range<Int> {
            skipSpace()
            guard index < bytes.count else { throw Malformed() }
            let start = index
            switch bytes[index] {
            case UInt8(ascii: "{"): _ = try members()
            case UInt8(ascii: "["): _ = try elements()
            case UInt8(ascii: "\""): _ = try string()
            default:
                while index < bytes.count, !Self.isSpace(bytes[index]),
                      bytes[index] != UInt8(ascii: ","), bytes[index] != UInt8(ascii: "}"), bytes[index] != UInt8(ascii: "]") {
                    index += 1
                }
                guard index > start else { throw Malformed() }
            }
            return start..<index
        }

        /// A string from its opening quote, decoded.
        package mutating func string() throws -> String {
            let open = index
            try expect(UInt8(ascii: "\""))
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                index += bytes[index] == UInt8(ascii: "\\") ? 2 : 1
            }
            guard index < bytes.count else { throw Malformed() }
            index += 1
            let raw = Data(bytes[open..<index])
            guard let text = try? JSONSerialization.jsonObject(with: raw, options: [.fragmentsAllowed]) as? String else {
                throw Malformed()
            }
            return text
        }

        /// An object from its `{`: the members in order.
        package mutating func members() throws -> [Member] {
            try expect(UInt8(ascii: "{"))
            var out: [Member] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                index += 1
                return out
            }
            while true {
                skipSpace()
                let start = index
                let key = try string()
                skipSpace()
                try expect(UInt8(ascii: ":"))
                let value = try skipValue()
                out.append(Member(key: key, start: start, valueStart: value.lowerBound, valueEnd: value.upperBound))
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "}"))
                return out
            }
        }

        /// An array from its `[`: the elements' ranges in order.
        package mutating func elements() throws -> [Range<Int>] {
            try expect(UInt8(ascii: "["))
            var out: [Range<Int>] = []
            skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                index += 1
                return out
            }
            while true {
                out.append(try skipValue())
                skipSpace()
                guard index < bytes.count else { throw Malformed() }
                if bytes[index] == UInt8(ascii: ",") {
                    index += 1
                    continue
                }
                try expect(UInt8(ascii: "]"))
                return out
            }
        }
    }

    /// `{"a": 1, "b": "x"}` from members whose values are already JSON text.
    package static func inlineObject(_ members: [(String, String)]) -> String {
        "{" + members.map { HookModules.literal($0.0) + ": " + $0.1 }.joined(separator: ", ") + "}"
    }

    /// `text` with its root object's `hooks` member rebuilt: the user's own
    /// events and entries verbatim and in their order, every entry
    /// `isPulse` says is Pulse's dropped, `pulse`'s entries appended per
    /// event (new events after the user's). Every byte outside `hooks` is
    /// kept. `ensureVersion` adds `"version": 1` when the root has none;
    /// `dropEmptyHooks` removes a `hooks` member left empty.
    package static func replacingHooks(
        in original: String,
        pulse: [(String, [String])],
        isPulse: (String) -> Bool,
        ensureVersion: Bool,
        dropEmptyHooks: Bool
    ) throws -> String {
        // A byte-order mark stays where it was; the JSON after it is read.
        let (bom, text) = splitBOM(original)
        // A file with CRLF line endings gets CRLF in what Pulse writes too.
        let lineBreak = text.contains("\r\n") ? "\r\n" : "\n"
        func breaks(_ fragment: String) -> String {
            guard lineBreak != "\n" else { return fragment }
            return fragment.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: lineBreak)
        }
        let bytes = Array(text.utf8)
        let unit = indentUnit(bytes)
        func slice(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No file (or an empty one): a document of Pulse's own.
            var members: [String] = []
            if ensureVersion { members.append(unit + "\"version\": 1") }
            let fresh = try merge([], pulse: pulse, isPulse: isPulse)
            let hooks = hooksObject(fresh, indent: unit, unit: unit, inline: false)
            if hooks != "{}" || !dropEmptyHooks { members.append(unit + "\"hooks\": " + hooks) }
            return bom + (members.isEmpty ? "{}\n" : "{\n" + members.joined(separator: ",\n") + "\n}\n")
        }

        var reader = Reader(bytes)
        reader.skipSpace()
        let open = reader.index
        let root = try reader.members()
        let close = reader.index - 1
        let found = root.last { $0.key == "hooks" }

        // The events the file already has, in order.
        var existing: [Event] = []
        // A `hooks` that is not an object has nowhere for an entry to go,
        // and replacing it would lose what the user put there.
        if let found, bytes[found.valueStart] != UInt8(ascii: "{") { throw UnexpectedShape() }
        if let found {
            var inner = Reader(bytes, at: found.valueStart)
            for member in try inner.members() {
                var event = Event(key: member.key, raw: slice(member.valueStart..<member.valueEnd), entries: nil)
                if bytes[member.valueStart] == UInt8(ascii: "[") {
                    var list = Reader(bytes, at: member.valueStart)
                    event.entries = try list.elements().map(slice)
                }
                existing.append(event)
            }
        }
        let merged = try merge(existing, pulse: pulse, isPulse: isPulse)
        let dropHooks = merged.isEmpty && dropEmptyHooks

        // Non-overlapping edits, applied from the end of the file.
        var edits: [(range: Range<Int>, text: String)] = []
        if let found {
            let indent = lineIndent(bytes, at: found.start)
            let changed = merged.count != existing.count || merged.contains(where: \.changed)
            if dropHooks {
                edits.append((removalRange(of: found, in: root, open: open, close: close), ""))
            } else if changed {
                let hooks = hooksObject(merged, indent: indent ?? "", unit: unit, inline: indent == nil)
                edits.append((found.valueStart..<found.valueEnd, hooks))
            }
        }
        // New members go after the last one, indented like it.
        let indent: String?
        if let last = root.last {
            indent = lineIndent(bytes, at: last.start)
        } else {
            indent = unit
        }
        var added: [(String, String)] = []
        if ensureVersion, !root.contains(where: { $0.key == "version" }) { added.append(("version", "1")) }
        if found == nil, !dropHooks {
            added.append(("hooks", hooksObject(merged, indent: indent ?? "", unit: unit, inline: indent == nil)))
        }
        if !added.isEmpty {
            let lead = indent.map { "\n" + $0 } ?? " "
            let body = added.map { lead + HookModules.literal($0.0) + ": " + $0.1 }.joined(separator: ",")
            if let last = root.last {
                edits.append((last.valueEnd..<last.valueEnd, "," + body))
            } else {
                edits.append(((open + 1)..<close, body + (indent == nil ? " " : "\n")))
            }
        }
        guard !edits.isEmpty else { return original }
        var out = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            out.replaceSubrange(edit.range, with: Array(breaks(edit.text).utf8))
        }
        return bom + String(decoding: out, as: UTF8.self)
    }

    /// One event of the `hooks` object.
    package struct Event {
        package var key: String
        /// The value exactly as written.
        package var raw: String
        /// Its entries' texts, when the value is an array.
        package var entries: [String]?
        /// Pulse's entries were removed or added.
        package var changed = false
    }

    /// The user's events with Pulse's entries taken out and `pulse`'s put
    /// in; an event Pulse emptied goes, one the user left empty (`[]`)
    /// stays. An event Pulse must add to whose value is not an array throws
    /// `UnexpectedShape` — a second member with the same key would be
    /// invalid, and replacing the user's value would lose it.
    package static func merge(_ existing: [Event], pulse: [(String, [String])], isPulse: (String) -> Bool) throws -> [Event] {
        var out: [Event] = []
        var placed: Set<String> = []
        for event in existing {
            guard let entries = event.entries else {
                if pulse.contains(where: { $0.0 == event.key && !$0.1.isEmpty }) { throw UnexpectedShape() }
                out.append(event)
                placed.insert(event.key)
                continue
            }
            var kept = entries.filter { !isPulse($0) }
            var changed = kept.count != entries.count
            if let mine = pulse.first(where: { $0.0 == event.key })?.1, !placed.contains(event.key) {
                kept += mine
                changed = changed || !mine.isEmpty
                placed.insert(event.key)
            }
            guard !kept.isEmpty || entries.isEmpty else { continue }
            out.append(Event(key: event.key, raw: event.raw, entries: kept, changed: changed))
        }
        for (key, entries) in pulse where !placed.contains(key) && !entries.isEmpty {
            placed.insert(key)
            out.append(Event(key: key, raw: "", entries: entries, changed: true))
        }
        return out
    }

    /// The `hooks` object's text. An event nobody changed keeps its bytes.
    package static func hooksObject(_ events: [Event], indent: String, unit: String, inline: Bool) -> String {
        guard !events.isEmpty else { return "{}" }
        func value(_ event: Event) -> String {
            guard event.changed, let entries = event.entries else { return event.raw }
            if inline { return "[" + entries.joined(separator: ", ") + "]" }
            let inner = indent + unit + unit
            return "[\n" + entries.map { inner + $0 }.joined(separator: ",\n") + "\n" + indent + unit + "]"
        }
        if inline {
            return "{" + events.map { HookModules.literal($0.key) + ": " + value($0) }.joined(separator: ", ") + "}"
        }
        return "{\n" + events.map { indent + unit + HookModules.literal($0.key) + ": " + value($0) }.joined(separator: ",\n")
            + "\n" + indent + "}"
    }

    /// The whitespace before `offset` on its line, or nil when something
    /// else precedes it there (the member is inline).
    package static func lineIndent(_ bytes: [UInt8], at offset: Int) -> String? {
        var start = offset
        while start > 0, bytes[start - 1] != 0x0A {
            guard bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 else { return nil }
            start -= 1
        }
        return String(decoding: bytes[start..<offset], as: UTF8.self)
    }

    /// The file's own indentation step: the leading whitespace of its first
    /// indented line, else two spaces.
    package static func indentUnit(_ bytes: [UInt8]) -> String {
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                var end = index + 1
                while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
                if end > index + 1, end < bytes.count, bytes[end] != 0x0A {
                    return String(decoding: bytes[(index + 1)..<end], as: UTF8.self)
                }
            }
            index += 1
        }
        return "  "
    }

    /// The bytes that remove `member` and one separator beside it.
    package static func removalRange(of member: Member, in members: [Member], open: Int, close: Int) -> Range<Int> {
        guard let position = members.firstIndex(where: { $0.start == member.start }) else {
            return member.start..<member.valueEnd
        }
        if position > 0 { return members[position - 1].valueEnd..<member.valueEnd }
        if members.count > 1 { return member.start..<members[1].start }
        return (open + 1)..<close
    }
}
