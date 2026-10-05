import Foundation
import IOKit
import CODiskSMART

/// Finds physical drives through the IORegistry (allowed in the App Sandbox) and reads SMART through
/// the NVMe SMART user client (needs the iokit-user-client-class exception in the sandbox).
public enum DriveScanner {
    public static func scan() -> [Drive] {
        let volumesByDevice = mountedVolumesByDevice()
        var drives: [Drive] = []
        var iterator: io_iterator_t = 0
        guard let match = IOServiceMatching("IOMedia") as NSMutableDictionary? else { return [] }
        match["IOPropertyMatch"] = ["Whole": true]
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            // A physical whole disk sits on IOBlockStorageDriver → IOBlockStorageDevice.
            // APFS's synthesized disks sit on a container instead, so they are skipped here.
            guard let driver = parent(of: media) else { continue }
            defer { IOObjectRelease(driver) }
            guard IOObjectConformsTo(driver, "IOBlockStorageDriver") != 0, let device = parent(of: driver) else { continue }
            defer { IOObjectRelease(device) }
            guard IOObjectConformsTo(device, "IOBlockStorageDevice") != 0 else { continue }

            let protocolInfo = dictionary(device, "Protocol Characteristics")
            let deviceInfo = dictionary(device, "Device Characteristics")
            let interconnect = protocolInfo["Physical Interconnect"] as? String ?? "Unknown"
            let location = protocolInfo["Physical Interconnect Location"] as? String ?? ""
            if interconnect == "Virtual Interface" || location == "File" { continue } // disk images

            let bsd = string(media, "BSD Name") ?? "disk?"
            let serial = (deviceInfo["Serial Number"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var entryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(device, &entryID)
            let vendor = (deviceInfo["Vendor Name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let product = (deviceInfo["Product Name"] as? String ?? "Drive").trimmingCharacters(in: .whitespaces)

            drives.append(Drive(
                id: serial.isEmpty ? bsd : "\(product)#\(serial)",
                bsdName: bsd,
                model: vendor.isEmpty || product.localizedCaseInsensitiveContains(vendor) ? product : "\(vendor) \(product)",
                vendor: vendor,
                firmware: (deviceInfo["Product Revision Level"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                serial: serial,
                capacityBytes: (property(media, "Size") as? NSNumber)?.int64Value ?? 0,
                interconnect: interconnect,
                isInternal: location == "Internal",
                isSolidState: (deviceInfo["Medium Type"] as? String) != "Rotational",
                isRemovable: (property(media, "Removable") as? Bool) ?? false,
                usbLinkSpeedBitsPerSecond: interconnect == "USB" ? usbLinkSpeed(of: device) : nil,
                smartProtocol: (property(device, "NVMe SMART Capable") as? Bool) == true ? .nvme
                    : ((property(device, "SMART Capable") as? Bool) == true ? .ata : nil),
                registryEntryID: entryID,
                volumes: (volumesByDevice[entryID] ?? []).sorted { ($0.isStartupDisk ? 0 : 1, $0.name) < ($1.isStartupDisk ? 0 : 1, $1.name) }
            ))
        }
        // Startup drive first, then internal, then by name.
        return drives.sorted {
            let a = ($0.volumes.contains(where: \.isStartupDisk) ? 0 : 1, $0.isInternal ? 0 : 1, $0.displayName)
            let b = ($1.volumes.contains(where: \.isStartupDisk) ? 0 : 1, $1.isInternal ? 0 : 1, $1.displayName)
            return a < b
        }
    }

    /// Reads S.M.A.R.T. for a drive found by `scan()`, using the drive's protocol.
    public static func readSMART(drive: Drive) -> Result<SMARTSnapshot, SMARTReadError> {
        switch drive.smartProtocol {
        case .nvme: readSMART(registryEntryID: drive.registryEntryID)
        case .ata: readATASMART(registryEntryID: drive.registryEntryID)
        case nil: .failure(.notSupported)
        }
    }

    /// Reads ATA S.M.A.R.T. (SATA drives, internal or behind a USB bridge that supports SAT).
    public static func readATASMART(registryEntryID: UInt64) -> Result<SMARTSnapshot, SMARTReadError> {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard service != 0 else { return .failure(.notSupported) }
        defer { IOObjectRelease(service) }
        var data = [UInt8](repeating: 0, count: 512)
        var thresholds = [UInt8](repeating: 0, count: 512)
        var identify = [UInt8](repeating: 0, count: 512)
        var exceeded: Int32 = 0
        let rc = odisk_ata_read(service, &data, &thresholds, &identify, &exceeded)
        guard rc == 0 else { return .failure(mapError(rc)) }
        guard let log = try? ATAHealthLog(data: data, thresholds: thresholds, thresholdExceeded: exceeded != 0) else {
            return .failure(.failed(-1))
        }
        return .success(SMARTSnapshot(date: Date(), ata: log, identify: ATAIdentify(bytes: identify)))
    }

    static func mapError(_ rc: Int32) -> SMARTReadError {
        let code = Int32(bitPattern: UInt32(truncatingIfNeeded: rc))
        switch UInt32(bitPattern: code) {
        case 0xe00002e2, 0xe00002c1, 0xe00002be: return .accessDenied(code)
        case 0xe00002c7: return .notSupported
        default: return .failed(code)
        }
    }

    /// Reads the NVMe health log for a drive found by `scan()`.
    public static func readSMART(registryEntryID: UInt64) -> Result<SMARTSnapshot, SMARTReadError> {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryEntryID))
        guard service != 0 else { return .failure(.notSupported) }
        defer { IOObjectRelease(service) }
        guard (property(service, "NVMe SMART Capable") as? Bool) == true else { return .failure(.notSupported) }
        var log = [UInt8](repeating: 0, count: 512)
        var identify = [UInt8](repeating: 0, count: 4096)
        let rc = odisk_nvme_read(service, &log, &identify)
        guard rc == 0 else { return .failure(mapError(rc)) }
        guard let parsed = try? NVMeHealthLog(bytes: log) else { return .failure(.failed(-1)) }
        return .success(SMARTSnapshot(date: Date(), log: parsed, identify: NVMeIdentify(bytes: identify)))
    }

    // MARK: - Volumes

    static func mountedVolumesByDevice() -> [UInt64: [Volume]] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
                                      .volumeAvailableCapacityKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
                                      .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var result: [UInt64: [Volume]] = [:]
        for url in urls {
            var fs = statfs()
            guard statfs(url.path, &fs) == 0 else { continue }
            let from = withUnsafeBytes(of: fs.f_mntfromname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard from.hasPrefix("/dev/") else { continue } // network shares, etc.
            let bsd = String(from.dropFirst(5))
            guard let deviceID = blockStorageDeviceID(forBSDName: bsd) else { continue }
            let v = try? url.resourceValues(forKeys: Set(keys))
            let total = Int64(v?.volumeTotalCapacity ?? 0)
            let important = v?.volumeAvailableCapacityForImportantUsage ?? 0
            let available = important > 0 ? important : Int64(v?.volumeAvailableCapacity ?? 0)
            result[deviceID, default: []].append(Volume(
                name: v?.volumeLocalizedName ?? url.lastPathComponent,
                mountPath: url.path,
                bsdName: bsd,
                fileSystem: v?.volumeLocalizedFormatDescription ?? withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
                totalBytes: total,
                availableBytes: available,
                isReadOnly: v?.volumeIsReadOnly ?? false,
                isStartupDisk: v?.volumeIsRootFileSystem ?? (url.path == "/")
            ))
        }
        return result
    }

    /// Walks from a BSD node (e.g. disk3s1s1) up the service plane, through APFS containers and
    /// partition schemes, to the physical IOBlockStorageDevice.
    static func blockStorageDeviceID(forBSDName bsd: String) -> UInt64? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard service != 0 else { return nil }
        var current = service
        for _ in 0..<40 {
            if IOObjectConformsTo(current, "IOBlockStorageDevice") != 0 {
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(current, &id)
                IOObjectRelease(current)
                return id
            }
            guard let next = parent(of: current) else { break }
            IOObjectRelease(current)
            current = next
        }
        IOObjectRelease(current)
        return nil
    }

    // MARK: - Registry helpers

    static func parent(of entry: io_registry_entry_t) -> io_registry_entry_t? {
        var p: io_registry_entry_t = 0
        return IORegistryEntryGetParentEntry(entry, kIOServicePlane, &p) == KERN_SUCCESS && p != 0 ? p : nil
    }

    static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func string(_ entry: io_registry_entry_t, _ key: String) -> String? { property(entry, key) as? String }

    static func dictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any] {
        property(entry, key) as? [String: Any] ?? [:]
    }

    static func usbLinkSpeed(of device: io_registry_entry_t) -> Int64? {
        let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        let value = IORegistryEntrySearchCFProperty(device, kIOServicePlane, "UsbLinkSpeed" as CFString, kCFAllocatorDefault, options)
        return (value as? NSNumber)?.int64Value
    }
}
