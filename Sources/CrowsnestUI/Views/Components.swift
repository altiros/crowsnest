import CrowsnestKit
import SwiftUI

extension StatusTone {
    var color: Color {
        switch self {
        case .ok: .green
        case .progress: .blue
        case .warning: .orange
        case .error: .red
        case .neutral: .secondary
        }
    }
}

struct StatusDot: View {
    var tone: StatusTone
    var body: some View {
        Circle().fill(tone.color).frame(width: 8, height: 8)
    }
}

struct StatusLabel: View {
    var text: String
    var tone: StatusTone
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(tone: tone)
            Text(text).foregroundStyle(tone == .error ? Color.red : Color.primary)
        }
    }
}

struct CellView: View {
    var value: CellValue
    var now: Date
    var body: some View {
        switch value {
        case .status(let text, let tone):
            StatusLabel(text: text, tone: tone)
        case .number(let n):
            Text(String(n)).monospacedDigit()
        case .meter(_, let fraction, let text):
            HStack(spacing: 6) {
                Text(text).monospacedDigit()
                if let fraction {
                    MiniBar(fraction: fraction).frame(width: 28)
                }
            }
        default:
            Text(value.display(now: now))
        }
    }
}

/// Small rounded tag, used for labels and selectors.
struct Chip: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            .textSelection(.enabled)
    }
}

/// Wrapping horizontal layout.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal: proposal, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, origin) in rows.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (origins: [CGPoint], width: CGFloat, height: CGFloat) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            width = max(width, x)
            rowHeight = max(rowHeight, size.height)
        }
        return (origins, width, y + rowHeight)
    }
}

struct ChipList: View {
    var items: [String]
    var body: some View {
        FlowLayout {
            ForEach(items, id: \.self) { Chip(text: $0) }
        }
    }
}

/// A usage bar like Lens' CPU/memory indicators.
struct UsageBar: View {
    var title: String
    var used: Double
    var requested: Double?
    var capacity: Double
    var format: (Double) -> String

    private func fraction(_ v: Double) -> Double { capacity > 0 ? min(1, v / capacity) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(format(used)) / \(format(capacity))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    if let requested {
                        Capsule().fill(Color.accentColor.opacity(0.3)).frame(width: geo.size.width * fraction(requested))
                    }
                    Capsule().fill(barColor).frame(width: geo.size.width * fraction(used))
                }
            }
            .frame(height: 8)
            HStack(spacing: 12) {
                Text("Usage \(Int((fraction(used) * 100).rounded())) %")
                if let requested { Text("Requests \(Int((fraction(requested) * 100).rounded())) %") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var barColor: Color {
        switch fraction(used) {
        case ..<0.7: .green
        case ..<0.9: .orange
        default: .red
        }
    }
}

extension View {
    /// Shows `model.toast` briefly at the bottom.
    func toastOverlay(_ message: Binding<String?>) -> some View {
        overlay(alignment: .bottom) {
            if let text = message.wrappedValue {
                Text(text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(radius: 4)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: text) {
                        try? await Task.sleep(for: .seconds(2.5))
                        withAnimation { message.wrappedValue = nil }
                    }
            }
        }
        .animation(.default, value: message.wrappedValue)
    }
}

#if os(macOS)
import AppKit
enum Pasteboard {
    static func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    static var string: String? { NSPasteboard.general.string(forType: .string) }
}
#else
import UIKit
enum Pasteboard {
    static func copy(_ string: String) { UIPasteboard.general.string = string }
    static var string: String? { UIPasteboard.general.string }
}
#endif


extension View {
    /// Link-styled button on macOS, tinted borderless button on iPadOS.
    @ViewBuilder
    func linkButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.link)
        #else
        buttonStyle(.borderless).tint(.accentColor)
        #endif
    }

    /// Borderless menu on macOS (default menu button style elsewhere).
    @ViewBuilder
    func borderlessMenuStyle() -> some View {
        #if os(macOS)
        menuStyle(.borderlessButton)
        #else
        self
        #endif
    }
}

extension View {
    /// iPad: while the inspector is open, the table shows its first column only (like a compact list).
    /// A full-width table next to the inspector would scroll sideways and hide the name column.
    @ViewBuilder
    func compactWhileInspecting(_ inspecting: Bool) -> some View {
        #if os(macOS)
        self
        #else
        if inspecting { environment(\.horizontalSizeClass, .compact) } else { self }
        #endif
    }
}
