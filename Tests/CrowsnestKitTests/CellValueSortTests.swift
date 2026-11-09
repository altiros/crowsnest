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
