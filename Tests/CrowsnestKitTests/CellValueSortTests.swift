import Foundation
import Testing
@testable import CrowsnestKit

@Suite struct CellValueSortTests {
    func sorted(_ values: [CellValue]) -> [String] {
        values.sorted { CellValue.compare($0, $1) == .orderedAscending }.map { $0.display() }
    }

    @Test func cpuQuantitiesSortByValue() {
        #expect(sorted([.text("2"), .text("500m"), .text("1500m"), .text("100m")]) == ["100m", "500m", "1500m", "2"])
    }

    @Test func memoryQuantitiesSortByValue() {
        #expect(sorted([.text("16Gi"), .text("512Mi"), .text("1Gi"), .text("128974848")]) == ["128974848", "512Mi", "1Gi", "16Gi"])
    }

    @Test func meterSortsByValueNotText() {
        let values: [CellValue] = [
            .meter(value: 0.012, fraction: nil, text: "12m"),
            .meter(value: 1.5, fraction: nil, text: "1.50"),
            .meter(value: 0.1, fraction: nil, text: "100m"),
            .meter(value: 0.002, fraction: nil, text: "2m"),
        ]
        #expect(sorted(values) == ["2m", "12m", "100m", "1.50"])
    }

    @Test func plainTextStillSortsNaturally() {
        #expect(sorted([.text("web-10"), .text("web-2"), .text("api")]) == ["api", "web-2", "web-10"])
    }

    @Test func quantitiesBeforePlaceholders() {
        #expect(sorted([.text("–"), .text("1Gi"), .text("<none>"), .text("100Mi")]).prefix(2) == ["100Mi", "1Gi"])
    }
}

@Suite struct ColumnSortTests {
    func column(_ kind: ResourceKind, _ title: String) throws -> ResourceColumn {
        try #require(kind.allColumns.first { $0.title == title })
    }

    func sortedDisplay(_ column: ResourceColumn, _ objects: [KubeObject]) -> [String] {
        objects.map(column.value).sorted { CellValue.compare($0, $1) == .orderedAscending }.map { $0.display() }
    }

    @Test func nodeMemorySortsByBytes() throws {
        let nodes = ["512Mi", "16Gi", "2Gi", "1048576Ki"].map { KubeObject(["kind": "Node", "status": ["capacity": ["memory": .string($0)]]]) }
        #expect(sortedDisplay(try column(.nodes, "Memory"), nodes) == ["512 MiB", "1.0 GiB", "2.0 GiB", "16 GiB"])
    }

    @Test func jobDurationSortsBySeconds() throws {
        func job(_ seconds: Double) -> KubeObject {
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let f = ISO8601DateFormatter()
            return KubeObject(["kind": "Job", "status": [
                "startTime": .string(f.string(from: start)),
                "completionTime": .string(f.string(from: start.addingTimeInterval(seconds))),
            ]])
        }
        let values = [job(300), job(45), job(7200), job(90)].map(try column(.jobs, "Duration").value)
            .sorted { CellValue.compare($0, $1) == .orderedAscending }
            .map { value -> Double in if case .meter(let seconds, _, _) = value { seconds } else { -1 } }
        #expect(values == [45, 90, 300, 7200])
    }

    @Test func textThatIsNotAQuantityStaysText() {
        let sorted = [CellValue.text("nan"), .text("inf"), .text("10"), .text("2")]
            .sorted { CellValue.compare($0, $1) == .orderedAscending }.map { $0.display() }
        #expect(sorted == ["2", "10", "inf", "nan"])
    }
}
