import SwiftUI

/// YAML code editor: syntax highlighting, line numbers (macOS), auto-indent,
/// two-space tabs, find bar and an error-line marker.
struct YAMLEditorView: View {
    @Binding var text: String
    var isEditable = true
    var errorLine: Int?

    var body: some View {
        PlatformYAMLEditor(text: $text, isEditable: isEditable, errorLine: errorLine)
    }
}

#if os(macOS)
import AppKit

typealias PlatformColor = NSColor
typealias PlatformFont = NSFont
#else
import UIKit

typealias PlatformColor = UIColor
typealias PlatformFont = UIFont
#endif

enum EditorTheme {
    static let fontSize: CGFloat = 12.5
    static var font: PlatformFont { .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    #if os(macOS)
    static let text = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    #else
    static let text = UIColor.label
    static let secondary = UIColor.secondaryLabel
    #endif

    static func color(for kind: YAMLHighlighter.TokenKind) -> PlatformColor {
        switch kind {
        case .key: .systemBlue
        case .string, .blockScalar: .systemRed
        case .number: .systemPurple
        case .keyword: .systemPink
        case .comment: .systemGray
        case .punctuation: secondary
        case .anchor: .systemTeal
        case .documentMarker: .systemOrange
        }
    }

    /// Re-applies highlighting to the whole storage. Fast enough for typical manifests.
    static func highlight(_ storage: NSTextStorage) {
        let full = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: text], range: full)
        for token in YAMLHighlighter.tokens(in: storage.string) where NSMaxRange(token.range) <= storage.length {
            storage.addAttribute(.foregroundColor, value: color(for: token.kind), range: token.range)
        }
        storage.endEditing()
    }

    /// Indentation for a new line after `line` (keeps indent, +2 after "key:" / block scalar / list item).
    static func indentation(after line: String) -> String {
        var indent = String(line.prefix { $0 == " " })
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(":") || trimmed.range(of: #"[:\-]\s*[|>][-+0-9]*$"#, options: .regularExpression) != nil
            || trimmed.hasSuffix("- |") {
            indent += "  "
        } else if trimmed.hasPrefix("- ") {
            indent += "  "
        }
        if trimmed.hasPrefix("- "), trimmed.hasSuffix(":") { indent += "  " }
        return indent
    }
}

#if os(macOS)

private struct PlatformYAMLEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var errorLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        // TextKit 1 so the line-number ruler can use NSLayoutManager.
        let textView = NSTextView(usingTextLayoutManager: false)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.font = EditorTheme.font
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.delegate = context.coordinator
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        context.coordinator.ruler = ruler

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        textView.string = text
        if let storage = textView.textStorage { EditorTheme.highlight(storage) }
        Self.scrollToLeadingEdge(scrollView)
        return scrollView
    }

    /// The ruler is laid out via the clip view's content insets: the leading edge is at x = -inset.
    /// With long lines (horizontal scrolling) the clip view can start at x = 0 instead, hiding the first
    /// characters behind the line numbers.
    private static func scrollToLeadingEdge(_ scrollView: NSScrollView) {
        DispatchQueue.main.async {
            let clip = scrollView.contentView
            let leading = -clip.contentInsets.left
            guard clip.bounds.origin.x != leading else { return }
            clip.scroll(to: NSPoint(x: leading, y: clip.bounds.origin.y))
            scrollView.reflectScrolledClipView(clip)
        }
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        textView.isEditable = isEditable
        textView.backgroundColor = isEditable ? .textBackgroundColor : .controlBackgroundColor
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            if let storage = textView.textStorage { EditorTheme.highlight(storage) }
            let length = (text as NSString).length
            textView.selectedRanges = selection.filter { NSMaxRange($0.rangeValue) <= length }.nonEmpty
                ?? [NSValue(range: NSRange(location: 0, length: 0))]
            Self.scrollToLeadingEdge(scrollView)
        }
        if context.coordinator.ruler?.errorLine != errorLine {
            context.coordinator.ruler?.errorLine = errorLine
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        weak var ruler: LineNumberRulerView?

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if let storage = textView.textStorage { EditorTheme.highlight(storage) }
            text.wrappedValue = textView.string
            ruler?.needsDisplay = true
        }

        @objc func boundsChanged() { ruler?.needsDisplay = true }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("  ", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertNewline(_:)):
                let ns = textView.string as NSString
                let selection = textView.selectedRange()
                let lineStart = ns.lineRange(for: NSRange(location: selection.location, length: 0)).location
                let line = ns.substring(with: NSRange(location: lineStart, length: selection.location - lineStart))
                textView.insertText("\n" + EditorTheme.indentation(after: line), replacementRange: selection)
                return true
            default:
                return false
            }
        }
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}

/// Line numbers for a TextKit 1 `NSTextView`; marks an error line in red.
final class LineNumberRulerView: NSRulerView {
    var errorLine: Int?

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let ns = textView.string as NSString
        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)

        var lineNumber = 1
        if charRange.location > 0 {
            ns.enumerateSubstrings(in: NSRange(location: 0, length: charRange.location), options: [.byLines, .substringNotRequired]) { _, _, _, _ in
                lineNumber += 1
            }
            // enumerateSubstrings counts the partial line containing `location` too.
            let prev = ns.character(at: charRange.location - 1)
            if prev != 0x0A { lineNumber -= 1 }
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: EditorTheme.fontSize - 1.5, weight: .regular)
        func draw(_ number: Int, atY y: CGFloat, height: CGFloat) {
            let isError = number == errorLine
            if isError {
                NSColor.systemRed.withAlphaComponent(0.2).setFill()
                NSRect(x: 0, y: y, width: bounds.width - 1, height: height).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: isError ? NSColor.systemRed : NSColor.tertiaryLabelColor,
            ]
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: bounds.width - size.width - 6, y: y + (height - size.height) / 2), withAttributes: attrs)
        }

        var index = charRange.location
        let end = NSMaxRange(charRange)
        while index < end || (index == end && index == ns.length && ns.length == 0) {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = convert(NSPoint(x: 0, y: lineRect.minY + textView.textContainerOrigin.y), from: textView).y
            draw(lineNumber, atY: y, height: lineRect.height)
            lineNumber += 1
            if NSMaxRange(lineRange) == index { break }
            index = NSMaxRange(lineRange)
        }
        // Empty last line after a trailing newline.
        if ns.length == 0 || ns.character(at: ns.length - 1) == 0x0A {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                let y = convert(NSPoint(x: 0, y: extra.minY + textView.textContainerOrigin.y), from: textView).y
                if ns.length == 0 { lineNumber = 1 }
                draw(lineNumber, atY: y, height: extra.height)
            }
        }
    }
}

#else

private struct PlatformYAMLEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var errorLine: Int?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = EditorTheme.font
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.isFindInteractionEnabled = true
        textView.delegate = context.coordinator
        textView.text = text
        EditorTheme.highlight(textView.textStorage)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        textView.isEditable = isEditable
        if textView.text != text {
            textView.text = text
            EditorTheme.highlight(textView.textStorage)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            let selection = textView.selectedRange
            EditorTheme.highlight(textView.textStorage)
            textView.selectedRange = selection
            text.wrappedValue = textView.text
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText string: String) -> Bool {
            guard string == "\n" else { return true }
            let ns = textView.text as NSString
            let lineStart = ns.lineRange(for: NSRange(location: range.location, length: 0)).location
            let line = ns.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            textView.replace(textView.textRange(from: range) ?? UITextRange(), withText: "\n" + EditorTheme.indentation(after: line))
            return false
        }
    }
}

private extension UITextView {
    func textRange(from range: NSRange) -> UITextRange? {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length) else { return nil }
        return textRange(from: start, to: end)
    }
}
#endif
