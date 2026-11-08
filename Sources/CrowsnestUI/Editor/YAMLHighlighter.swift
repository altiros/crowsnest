import Foundation

/// Line-based YAML tokenizer for syntax highlighting. Ranges are UTF-16 (`NSRange`)
/// so they can be applied directly to `NSTextStorage`.
public enum YAMLHighlighter {
    public enum TokenKind: Sendable, Equatable {
        case key, string, number, keyword, comment, punctuation, anchor, documentMarker, blockScalar
    }

    public struct Token: Sendable, Equatable {
        public var kind: TokenKind
        public var range: NSRange
    }

    nonisolated(unsafe) private static let keyPattern = try! NSRegularExpression(
        pattern: #"^("(?:[^"\\]|\\.)*"|'[^']*'|[^\s#'"\-\[\]{}][^#]*?|-[^\s#][^#]*?)\s*:(?=\s|$)"#)
    nonisolated(unsafe) private static let numberPattern = try! NSRegularExpression(
        pattern: #"^[-+]?(?:\d[\d_]*(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$|^0x[0-9a-fA-F]+$|^0o[0-7]+$"#)
    nonisolated(unsafe) private static let blockScalarPattern = try! NSRegularExpression(pattern: #"^[|>][-+0-9]*$"#)
    private static let keywords: Set<String> = ["true", "false", "yes", "no", "on", "off", "null", "~"]

    public static func tokens(in text: String) -> [Token] {
        let ns = text as NSString
        var tokens: [Token] = []
        var location = 0
        var blockIndent: Int?

        while location < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            var contentLength = lineRange.length
            while contentLength > 0 {
                let c = ns.character(at: lineRange.location + contentLength - 1)
                if c == 0x0A || c == 0x0D { contentLength -= 1 } else { break }
            }
            let line = ns.substring(with: NSRange(location: lineRange.location, length: contentLength)) as NSString
            tokenize(line: line, offset: lineRange.location, blockIndent: &blockIndent, into: &tokens)
        }
        return tokens
    }

    private static func tokenize(line: NSString, offset: Int, blockIndent: inout Int?, into tokens: inout [Token]) {
        let length = line.length
        var indent = 0
        while indent < length, line.character(at: indent) == 0x20 { indent += 1 }
        let isBlank = indent == length

        if let block = blockIndent {
            if isBlank { return }
            if indent > block {
                tokens.append(Token(kind: .blockScalar, range: NSRange(location: offset + indent, length: length - indent)))
                return
            }
            blockIndent = nil
        }
        if isBlank { return }

        func add(_ kind: TokenKind, _ start: Int, _ len: Int) {
            guard len > 0 else { return }
            tokens.append(Token(kind: kind, range: NSRange(location: offset + start, length: len)))
        }

        let trimmed = line.substring(from: indent)
        if trimmed.hasPrefix("#") {
            add(.comment, indent, length - indent)
            return
        }
        if indent == 0, trimmed == "---" || trimmed == "..." || trimmed.hasPrefix("--- ") {
            add(.documentMarker, 0, min(3, length))
            if length > 4 { scanValue(line, from: 4, keyColumn: 0, add: add, blockIndent: &blockIndent) }
            return
        }

        var pos = indent
        // Sequence dashes ("- ", possibly nested "- - ").
        while pos < length, line.character(at: pos) == 0x2D /* - */,
              pos + 1 == length || line.character(at: pos + 1) == 0x20 {
            add(.punctuation, pos, 1)
            pos += 1
            while pos < length, line.character(at: pos) == 0x20 { pos += 1 }
        }
        guard pos < length else { return }

        let rest = line.substring(from: pos) as NSString
        if let match = keyPattern.firstMatch(in: rest as String, range: NSRange(location: 0, length: rest.length)) {
            let keyRange = match.range(at: 1)
            add(.key, pos + keyRange.location, keyRange.length)
            add(.punctuation, pos + match.range.length - 1, 1)
            scanValue(line, from: pos + match.range.length, keyColumn: pos, add: add, blockIndent: &blockIndent)
        } else {
            scanValue(line, from: pos, keyColumn: pos, add: add, blockIndent: &blockIndent)
        }
    }

    private static func scanValue(_ line: NSString, from start: Int, keyColumn: Int,
                                  add: (TokenKind, Int, Int) -> Void, blockIndent: inout Int?) {
        let length = line.length
        var pos = start
        while pos < length, line.character(at: pos) == 0x20 { pos += 1 }
        guard pos < length else { return }

        // Find a trailing comment (" #" outside quotes).
        var end = length
        var quote: unichar?
        var i = pos
        while i < length {
            let c = line.character(at: i)
            if let q = quote {
                if c == q { quote = nil }
            } else if c == 0x22 || c == 0x27 {
                if i == pos { quote = c }
            } else if c == 0x23 /* # */, i > pos, line.character(at: i - 1) == 0x20 {
                end = i
                break
            }
            i += 1
        }
        if end < length { add(.comment, end, length - end) }
        var valueEnd = end
        while valueEnd > pos, line.character(at: valueEnd - 1) == 0x20 { valueEnd -= 1 }
        guard valueEnd > pos else { return }

        let value = line.substring(with: NSRange(location: pos, length: valueEnd - pos))
        let valueRange = NSRange(location: 0, length: (value as NSString).length)
        let first = value.first!
        if blockScalarPattern.firstMatch(in: value, range: valueRange) != nil {
            add(.keyword, pos, valueEnd - pos)
            blockIndent = keyColumn
        } else if first == "\"" || first == "'" {
            add(.string, pos, valueEnd - pos)
        } else if first == "&" || first == "*" || first == "!" {
            add(.anchor, pos, valueEnd - pos)
        } else if first == "{" || first == "[" {
            add(.punctuation, pos, 1)
        } else if keywords.contains(value.lowercased()) {
            add(.keyword, pos, valueEnd - pos)
        } else if numberPattern.firstMatch(in: value, range: valueRange) != nil {
            add(.number, pos, valueEnd - pos)
        } else {
            add(.string, pos, valueEnd - pos)
        }
    }
}
