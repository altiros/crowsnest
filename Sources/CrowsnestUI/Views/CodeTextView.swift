import SwiftUI

/// Monospaced, fast text view for YAML and logs (native text views handle
/// large content and find/selection far better than SwiftUI `Text`).
struct CodeTextView: View {
    @Binding var text: String
    var isEditable = false
    var scrollToEnd = false

    var body: some View {
        PlatformCodeTextView(text: $text, isEditable: isEditable, scrollToEnd: scrollToEnd)
    }
}

#if os(macOS)
import AppKit

private struct PlatformCodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var scrollToEnd: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.delegate = context.coordinator
        textView.string = text
        textView.isEditable = isEditable
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        textView.isEditable = isEditable
        textView.backgroundColor = isEditable ? .textBackgroundColor : .controlBackgroundColor
        if textView.string != text {
            let selection = textView.selectedRanges
            textView.string = text
            if scrollToEnd {
                textView.scrollToEndOfDocument(nil)
            } else if let first = selection.first?.rangeValue, NSMaxRange(first) <= (text as NSString).length {
                textView.selectedRanges = selection
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
#else
import UIKit

private struct PlatformCodeTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var scrollToEnd: Bool

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.spellCheckingType = .no
        textView.isFindInteractionEnabled = true
        textView.delegate = context.coordinator
        textView.text = text
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.text = $text
        textView.isEditable = isEditable
        if textView.text != text {
            textView.text = text
            if scrollToEnd, !text.isEmpty {
                textView.scrollRangeToVisible(NSRange(location: (text as NSString).length - 1, length: 1))
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}
#endif
