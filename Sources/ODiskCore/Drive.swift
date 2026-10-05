import Foundation

public enum DriveKind: String, Sendable, Codable {
    case internalSSD, externalSSD, internalHDD, externalHDD, sdCard, other

    public var symbolName: String {
        switch self {
        case .internalSSD, .internalHDD: "internaldrive"
        case .externalSSD, .externalHDD: "externaldrive"
        case .sdCard: "sdcard"
        case .other: "opticaldiscdrive"
        }
    }
}

public struct Volume: Identifiable, Hashable, Sendable, Codable {
    public var id: String { mountPath }
    public var name: String
    public var mountPath: String
    public var bsdName: String
    public var fileSystem: String
    public var totalBytes: Int64
    public var availableBytes: Int64
    public var isReadOnly: Bool
    public var isStartupDisk: Bool

    public init(name: String, mountPath: String, bsdName: String, fileSystem: String, totalBytes: Int64,
                availableBytes: Int64, isReadOnly: Bool, isStartupDisk: Bool) {
        self.name = name; self.mountPath = mountPath; self.bsdName = bsdName; self.fileSystem = fileSystem
        self.totalBytes = totalBytes; self.availableBytes = availableBytes; self.isReadOnly = isReadOnly
        self.isStartupDisk = isStartupDisk
    }

    public var usedFraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(totalBytes - availableBytes) / Double(totalBytes))) : 0
    }
}

/// A physical drive, as macOS's storage stack describes it, plus SMART when the drive exposes it.
public struct Drive: Identifiable, Hashable, Sendable, Codable {
    /// Stable across reconnects when the drive reports a serial; otherwise the BSD name.
    public var id: String
    public var bsdName: String
    public var model: String
    public var vendor: String
    public var firmware: String
    public var serial: String
    public var capacityBytes: Int64
    /// "PCI-Express", "Apple Fabric", "USB", "Thunderbolt", "SATA", "Secure Digital", …
    public var interconnect: String
    public var isInternal: Bool
    public var isSolidState: Bool
    public var isRemovable: Bool
    /// USB link speed in bits per second, when the drive hangs off USB.
    public var usbLinkSpeedBitsPerSecond: Int64?
    public var smartCapable: Bool
    public var registryEntryID: UInt64
    public var volumes: [Volume]

    public init(id: String, bsdName: String, model: String, vendor: String, firmware: String, serial: String,
                capacityBytes: Int64, interconnect: String, isInternal: Bool, isSolidState: Bool, isRemovable: Bool,
                usbLinkSpeedBitsPerSecond: Int64?, smartCapable: Bool, registryEntryID: UInt64, volumes: [Volume]) {
        self.id = id; self.bsdName = bsdName; self.model = model; self.vendor = vendor; self.firmware = firmware
        self.serial = serial; self.capacityBytes = capacityBytes; self.interconnect = interconnect
        self.isInternal = isInternal; self.isSolidState = isSolidState; self.isRemovable = isRemovable
        self.usbLinkSpeedBitsPerSecond = usbLinkSpeedBitsPerSecond; self.smartCapable = smartCapable
        self.registryEntryID = registryEntryID; self.volumes = volumes
    }

    public var kind: DriveKind {
        if interconnect == "Secure Digital" { return .sdCard }
        switch (isInternal, isSolidState) {
        case (true, true): return .internalSSD
        case (false, true): return .externalSSD
        case (true, false): return .internalHDD
        case (false, false): return .externalHDD
        }
    }

    /// What a person calls this drive: the startup volume or first volume name, else the model.
    public var displayName: String {
        primaryVolumeName ?? model
    }

    var primaryVolumeName: String? {
        (volumes.first(where: \.isStartupDisk) ?? volumes.first)?.name
    }

    /// Human interconnect, e.g. "USB 10 Gb/s" or "Internal (Apple Fabric)".
    public var connectionDescription: String {
        if let s = usbLinkSpeedBitsPerSecond, s > 0 {
            let gbps = Double(s) / 1_000_000_000
            return gbps >= 1 ? "USB \(Formatters.trim(gbps)) Gb/s" : "USB \(Int(Double(s) / 1_000_000)) Mb/s"
        }
        return isInternal ? "Internal · \(interconnect)" : interconnect
    }
}

/// A SMART reading for one drive at one moment.
public struct SMARTSnapshot: Equatable, Sendable, Codable {
    public var date: Date
    public var log: NVMeHealthLog
    public var identify: NVMeIdentify?
    public var assessment: HealthAssessment

    public init(date: Date, log: NVMeHealthLog, identify: NVMeIdentify?) {
        self.date = date; self.log = log; self.identify = identify
        self.assessment = HealthPolicy.assess(log, identify: identify)
    }
}

public enum SMARTReadError: Error, Equatable, Sendable {
    /// The drive or its enclosure doesn't pass SMART through (common for USB-SATA bridges).
    case notSupported
    /// The sandbox or the OS refused to open the drive's SMART interface.
    case accessDenied(Int32)
    case failed(Int32)
}
