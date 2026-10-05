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
    /// Which S.M.A.R.T. interface the drive exposes, if any.
    public var smartProtocol: SMARTProtocol?
    public var smartCapable: Bool { smartProtocol != nil }
    public var registryEntryID: UInt64
    public var volumes: [Volume]

    public init(id: String, bsdName: String, model: String, vendor: String, firmware: String, serial: String,
                capacityBytes: Int64, interconnect: String, isInternal: Bool, isSolidState: Bool, isRemovable: Bool,
                usbLinkSpeedBitsPerSecond: Int64?, smartProtocol: SMARTProtocol?, registryEntryID: UInt64, volumes: [Volume]) {
        self.id = id; self.bsdName = bsdName; self.model = model; self.vendor = vendor; self.firmware = firmware
        self.serial = serial; self.capacityBytes = capacityBytes; self.interconnect = interconnect
        self.isInternal = isInternal; self.isSolidState = isSolidState; self.isRemovable = isRemovable
        self.usbLinkSpeedBitsPerSecond = usbLinkSpeedBitsPerSecond; self.smartProtocol = smartProtocol
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

/// Protocol-neutral numbers the Health page, history and alerts use.
public struct HealthMetrics: Equatable, Sendable, Codable {
    public var temperatureCelsius: Int?
    public var warningTemperatureCelsius: Int?
    public var criticalTemperatureCelsius: Int?
    public var lifeUsedPercent: Int?
    public var bytesWritten: Double?
    public var bytesRead: Double?
    public var powerOnHours: Double?
    public var powerCycles: Double?
    public var unsafeShutdowns: Double?
    /// NVMe: media and data integrity errors. ATA: uncorrectable sectors.
    public var mediaErrors: Double?
    public var availableSparePercent: Int?
    public var availableSpareThresholdPercent: Int?
    /// ATA only.
    public var reallocatedSectors: Double?
    public var pendingSectors: Double?

    public init() {}

    public init(nvme log: NVMeHealthLog, identify: NVMeIdentify?) {
        temperatureCelsius = log.compositeTemperatureCelsius
        if let id = identify {
            warningTemperatureCelsius = id.warningTemperatureKelvin > 273 ? id.warningTemperatureKelvin - 273 : nil
            criticalTemperatureCelsius = id.criticalTemperatureKelvin > 273 ? id.criticalTemperatureKelvin - 273 : nil
        }
        lifeUsedPercent = log.percentageUsed
        bytesWritten = log.bytesWritten
        bytesRead = log.bytesRead
        powerOnHours = log.powerOnHours
        powerCycles = log.powerCycles
        unsafeShutdowns = log.unsafeShutdowns
        mediaErrors = log.mediaErrors
        availableSparePercent = log.availableSparePercent
        availableSpareThresholdPercent = log.availableSpareThresholdPercent
    }
}

extension HealthMetrics {
    public init(ata log: ATAHealthLog) {
        self.init()
        temperatureCelsius = log.temperatureCelsius
        lifeUsedPercent = log.lifeRemainingPercent.map { 100 - $0 }
        bytesWritten = log.hostBytesWritten
        bytesRead = log.hostBytesRead
        powerOnHours = log.powerOnHours.map(Double.init)
        powerCycles = log.powerCycles.map(Double.init)
        unsafeShutdowns = log.unsafeShutdowns.map(Double.init)
        mediaErrors = log.uncorrectableSectors.map(Double.init)
        reallocatedSectors = log.reallocatedSectors.map(Double.init)
        pendingSectors = log.pendingSectors.map(Double.init)
    }
}

public enum SMARTProtocol: String, Sendable, Codable {
    case nvme = "NVMe"
    case ata = "ATA"
}

/// A SMART reading for one drive at one moment.
public struct SMARTSnapshot: Equatable, Sendable, Codable {
    public var date: Date
    public var smartProtocol: SMARTProtocol
    public var nvme: NVMeHealthLog?
    public var nvmeIdentify: NVMeIdentify?
    public var ata: ATAHealthLog?
    public var ataIdentify: ATAIdentify?
    public var assessment: HealthAssessment
    public var metrics: HealthMetrics

    public init(date: Date, log: NVMeHealthLog, identify: NVMeIdentify?) {
        self.date = date
        smartProtocol = .nvme
        nvme = log
        nvmeIdentify = identify
        assessment = HealthPolicy.assess(log, identify: identify)
        metrics = HealthMetrics(nvme: log, identify: identify)
    }

    public init(date: Date, ata log: ATAHealthLog, identify: ATAIdentify?) {
        self.date = date
        smartProtocol = .ata
        ata = log
        ataIdentify = identify
        assessment = ATAHealthPolicy.assess(log)
        metrics = HealthMetrics(ata: log)
    }

    public var firmware: String? { nvmeIdentify?.firmwareRevision ?? ataIdentify?.firmwareRevision }
    public var serial: String? { nvmeIdentify?.serialNumber ?? ataIdentify?.serialNumber }
}

public enum SMARTReadError: Error, Equatable, Sendable {
    /// The drive or its enclosure doesn't pass SMART through (common for USB-SATA bridges).
    case notSupported
    /// The sandbox or the OS refused to open the drive's SMART interface.
    case accessDenied(Int32)
    case failed(Int32)
}
