import Foundation
import ODiskCore

// Developer tool: `odisk-cli drives` or `odisk-cli bench <folder> [sizeMiB] [seconds] [readsOnly]`.
let args = CommandLine.arguments
switch args.dropFirst().first {
case "bench":
    let folder = URL(fileURLWithPath: args.count > 2 ? args[2] : NSTemporaryDirectory())
    let size = (args.count > 3 ? Int(args[3]) ?? 1024 : 1024) << 20
    let secs = args.count > 4 ? Double(args[4]) ?? 3 : 3
    var tests = BenchmarkTest.standard
    if let only = ProcessInfo.processInfo.environment["ODISK_TESTS"] { tests = tests.filter { only.contains($0.label) } }
    let settings = BenchmarkSettings(fileSizeBytes: size, passes: 1, secondsPerPass: secs, tests: tests, includeWrites: args.count <= 5)
    let rows = try BenchmarkEngine(settings: settings).run(in: folder, cancellation: BenchmarkCancellation()) { _ in }
    for r in rows {
        print(r.test.label.padding(toLength: 13, withPad: " ", startingAt: 0),
              Formatters.throughput(r.read?.bytesPerSecond ?? 0), Formatters.throughput(r.write?.bytesPerSecond ?? 0))
    }
default:
    for d in DriveScanner.scan() {
        print(d.displayName, "|", d.model, "|", d.connectionDescription, "| smart:", d.smartCapable)
        if case let .success(s) = DriveScanner.readSMART(registryEntryID: d.registryEntryID) {
            print("  ", s.assessment.status.title, s.assessment.lifeRemainingPercent ?? -1, "%", s.log.compositeTemperatureCelsius ?? -1, "C")
        }
    }
}
