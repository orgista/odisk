import Foundation
import Testing
@testable import ODiskCore

/// One synthetic SMART attribute for building 512-byte READ DATA / THRESHOLDS buffers.
struct FakeATAAttribute {
    var id: UInt8
    var flags: UInt16 = 0x0033
    var current: UInt8 = 100
    var worst: UInt8 = 100
    var threshold: UInt8 = 0
    var raw: UInt64 = 0
}

func makeATABuffers(_ attrs: [FakeATAAttribute]) -> (data: [UInt8], thresholds: [UInt8]) {
    var d = [UInt8](repeating: 0, count: 512)
    var t = [UInt8](repeating: 0, count: 512)
    d[0] = 0x10; t[0] = 0x10
    for (i, a) in attrs.enumerated() {
        let o = 2 + i * 12
        d[o] = a.id
        d[o + 1] = UInt8(a.flags & 0xff); d[o + 2] = UInt8(a.flags >> 8)
        d[o + 3] = a.current; d[o + 4] = a.worst
        for b in 0..<6 { d[o + 5 + b] = UInt8((a.raw >> (8 * UInt64(b))) & 0xff) }
        t[o] = a.id; t[o + 1] = a.threshold
    }
    return (d, t)
}

func makeATALog(_ attrs: [FakeATAAttribute], exceeded: Bool = false) throws -> ATAHealthLog {
    let b = makeATABuffers(attrs)
    return try ATAHealthLog(data: b.data, thresholds: b.thresholds, thresholdExceeded: exceeded)
}

let healthyATA: [FakeATAAttribute] = [
    FakeATAAttribute(id: 0x05, current: 100, threshold: 10),
    FakeATAAttribute(id: 0x09, raw: 12_345),
    FakeATAAttribute(id: 0x0C, raw: 678),
    FakeATAAttribute(id: 0xC2, current: 66, raw: 0x0028_0012_0022), // 34 °C, min/max packed above
    FakeATAAttribute(id: 0xE7, current: 97),
    FakeATAAttribute(id: 0xF1, raw: 2_000_000),
]

@Suite struct ATAParsingTests {
    @Test func parsesAttributesAndThresholds() throws {
        let log = try makeATALog(healthyATA)
        #expect(log.attributes.count == healthyATA.count)
        let realloc = try #require(log.attribute(0x05))
        #expect(realloc.name == "Reallocated Sectors Count")
        #expect(realloc.threshold == 10)
        #expect(realloc.isPrefailure)
        #expect(log.powerOnHours == 12_345)
        #expect(log.powerCycles == 678)
        #expect(log.lifeRemainingPercent == 97)
        #expect(log.hostBytesWritten == Double(2_000_000 * 512))
        #expect(log.hostBytesRead == nil)
    }

    @Test func skipsEmptySlotsAndNamesUnknownIDs() throws {
        let log = try makeATALog([FakeATAAttribute(id: 0x01), FakeATAAttribute(id: 0x00), FakeATAAttribute(id: 0xE1)])
        #expect(log.attributes.map(\.id) == [0x01, 0xE1])
        #expect(log.attribute(0xE1)?.name == "Vendor Specific")
    }

    @Test func rawValueIs48Bits() throws {
        let log = try makeATALog([FakeATAAttribute(id: 0xF2, raw: 0xAABB_CCDD_EEFF)])
        #expect(log.attribute(0xF2)?.raw == 0xAABB_CCDD_EEFF)
    }

    @Test func temperatureFromLowByteOfC2() throws {
        #expect(try makeATALog(healthyATA).temperatureCelsius == 34)
        #expect(try makeATALog([FakeATAAttribute(id: 0xBE, raw: 41)]).temperatureCelsius == 41)
        #expect(try makeATALog([FakeATAAttribute(id: 0xC2, raw: 0)]).temperatureCelsius == nil)
    }

    @Test func lifeFromPercentageUsed() throws {
        #expect(try makeATALog([FakeATAAttribute(id: 0xCA, raw: 7)]).lifeRemainingPercent == 93)
    }

    @Test func rejectsShortBuffer() {
        #expect(throws: ATAParseError.shortBuffer(100)) {
            try ATAHealthLog(data: [UInt8](repeating: 0, count: 100), thresholds: [UInt8](repeating: 0, count: 512),
                             thresholdExceeded: false)
        }
    }

    @Test func identifySwapsBytesPerWord() throws {
        var b = [UInt8](repeating: 0, count: 512)
        func put(_ s: String, word: Int, words: Int) {
            let chars = Array(s.utf8) + [UInt8](repeating: 0x20, count: words * 2 - s.utf8.count)
            for w in 0..<words { b[(word + w) * 2] = chars[w * 2 + 1]; b[(word + w) * 2 + 1] = chars[w * 2] }
        }
        put("S4X1NJ0N123456", word: 10, words: 10)
        put("2B6Q", word: 23, words: 4)
        put("Samsung SSD 870 EVO 1TB", word: 27, words: 20)
        b[434] = 1
        let id = try #require(ATAIdentify(bytes: b))
        #expect(id.modelNumber == "Samsung SSD 870 EVO 1TB")
        #expect(id.serialNumber == "S4X1NJ0N123456")
        #expect(id.firmwareRevision == "2B6Q")
        #expect(id.isSolidState)
    }

    @Test func emptyIdentifyIsNil() {
        #expect(ATAIdentify(bytes: [UInt8](repeating: 0, count: 512)) == nil)
    }
}

@Suite struct ATAHealthPolicyTests {
    @Test func healthyDriveIsGood() throws {
        let a = ATAHealthPolicy.assess(try makeATALog(healthyATA))
        #expect(a.status == .good)
        #expect(a.findings.isEmpty)
        #expect(a.lifeRemainingPercent == 97)
        #expect(a.temperature == .normal)
    }

    @Test func attributeAtThresholdIsBad() throws {
        var attrs = healthyATA
        attrs[0].current = 10
        let a = ATAHealthPolicy.assess(try makeATALog(attrs))
        #expect(a.status == .bad)
        #expect(a.findings.contains { $0.message.contains("Reallocated Sectors Count") })
    }

    @Test func returnStatusExceededIsBad() throws {
        #expect(ATAHealthPolicy.assess(try makeATALog(healthyATA, exceeded: true)).status == .bad)
    }

    @Test func pendingSectorsAreCaution() throws {
        let a = ATAHealthPolicy.assess(try makeATALog(healthyATA + [FakeATAAttribute(id: 0xC5, raw: 3)]))
        #expect(a.status == .caution)
        #expect(a.findings.first?.message.contains("3 sectors") == true)
    }

    @Test func lowLifeIsCaution() throws {
        #expect(ATAHealthPolicy.assess(try makeATALog([FakeATAAttribute(id: 0xE7, current: 8)])).status == .caution)
    }

    @Test(arguments: [(40, TemperatureStatus.normal), (55, .warm), (70, .hot)])
    func temperatureBands(celsius: Int, expected: TemperatureStatus) throws {
        let log = try makeATALog([FakeATAAttribute(id: 0xC2, raw: UInt64(celsius))])
        #expect(ATAHealthPolicy.temperatureStatus(log) == expected)
    }
}
