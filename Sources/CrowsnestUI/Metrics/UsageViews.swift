import Charts
import CrowsnestKit
import SwiftUI

enum UsageResource: Sendable {
    case cpu, memory

    var title: String { self == .cpu ? "CPU" : "Memory" }

    func format(_ value: Double) -> String {
        self == .cpu ? Quantity.formatCPU(value) : Quantity.formatBytes(value)
    }

    func value(_ sample: UsageSample) -> Double { self == .cpu ? sample.cpu : sample.memory }
    func value(_ usage: ResourceUsage) -> Double { self == .cpu ? usage.cpu : usage.memory }
}

/// Small line chart of the last minutes, with optional request/limit rules.
struct UsageChart: View {
    let samples: [UsageSample]
    let resource: UsageResource
    var request: Double?
    var limit: Double?
    var limitLabel = "limit"

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(resource.title).font(.caption.weight(.semibold))
                Spacer()
                if let last = samples.last {
                    Text(resource.format(resource.value(last))).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if samples.count < 2 {
                Text("Collecting data …").font(.caption).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
            } else {
                Chart {
                    ForEach(samples) { s in
                        AreaMark(x: .value("Time", s.date), y: .value(resource.title, resource.value(s)))
                            .foregroundStyle(Color.accentColor.opacity(0.15))
                        LineMark(x: .value("Time", s.date), y: .value(resource.title, resource.value(s)))
                            .foregroundStyle(Color.accentColor)
                    }
                    if let request = visible(request) {
                        RuleMark(y: .value("Request", request))
                            .foregroundStyle(.secondary)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text("request").font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                    }
                    if let limit = visible(limit) {
                        RuleMark(y: .value("Limit", limit))
                            .foregroundStyle(.red.opacity(0.7))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .annotation(position: .top, alignment: .trailing) {
                                Text(limitLabel).font(.system(size: 9)).foregroundStyle(.red.opacity(0.8))
                            }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: showsSeconds ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text(resource.format(v)) } }
                    }
                }
                .chartYScale(domain: 0...max(yMax, 1e-9))
                .frame(height: 80)
            }
        }
    }

    /// With only a few minutes of data, minute labels would repeat.
    private var showsSeconds: Bool {
        guard let first = samples.first?.date, let last = samples.last?.date else { return false }
        return last.timeIntervalSince(first) < 5 * 60
    }

    private var peak: Double { samples.map(resource.value).max() ?? 0 }

    /// Request/limit lines are only drawn when they are close enough to the usage to be readable.
    private func visible(_ value: Double?) -> Double? {
        guard let value, value <= max(peak, 1e-9) * 2.5 else { return nil }
        return value
    }

    private var yMax: Double {
        max(peak * 1.25, visible(request) ?? 0, visible(limit) ?? 0)
    }
}

/// "Usage" section with charts for CPU and memory.
struct UsageChartsSection: View {
    let title: String
    let samples: [UsageSample]
    var spec: ResourceSpec?
    var limitLabel = "limit"

    var body: some View {
        Section {
            UsageChart(samples: samples, resource: .cpu, request: spec?.cpuRequest, limit: spec?.cpuLimit, limitLabel: limitLabel)
            UsageChart(samples: samples, resource: .memory, request: spec?.memoryRequest, limit: spec?.memoryLimit, limitLabel: limitLabel)
        } header: {
            Text(title)
        } footer: {
            Text("Last \(Int(MetricsStore.window / 60)) minutes, sampled every \(Int(MetricsStore.interval.components.seconds)) s while Crowsnest is open.")
        }
    }
}

/// One row: "12m of 500m limit" with a small bar.
struct UsageMeterRow: View {
    let resource: UsageResource
    let used: Double
    var request: Double?
    var limit: Double?

    var body: some View {
        LabeledContent(resource.title) {
            HStack(spacing: 8) {
                if let reference = limit ?? request, reference > 0 {
                    MiniBar(fraction: used / reference, isLimit: limit != nil)
                        .frame(width: 60)
                }
                Text(text).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var text: String {
        var parts = [resource.format(used)]
        if let request { parts.append("req \(resource.format(request))") }
        if let limit { parts.append("lim \(resource.format(limit))") }
        return parts.joined(separator: " · ")
    }
}

/// Compact usage bar; turns orange/red near a limit.
struct MiniBar: View {
    let fraction: Double
    var isLimit = true

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(color).frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .help("\(Int((fraction * 100).rounded())) % of \(isLimit ? "limit" : "request")")
    }

    private var color: Color {
        guard isLimit else { return .accentColor }
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }
}
