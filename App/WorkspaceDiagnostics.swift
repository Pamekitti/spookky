import AppKit
import Darwin
import SpookkyCore

@MainActor final class WorkspaceDiagnostics {
    struct Sample: Codable, Sendable {
        let name: String
        let unit: String
        let value: Double
        let warm: Bool
        let surfaceCount: Int
        let residentMiB: Double?
    }
    private var samples: [Sample] = []
    private let url: URL
    private let writer = DispatchQueue(label: "dev.spookky.workspace-diagnostics", qos: .utility)
    private var requests: DispatchSourceFileSystemObject?
    var historyMarker: (() -> Int?)?
    var visibility: (() -> Bool)?
    init?(root: URL) {
        guard CommandLine.arguments.contains("--workspace-measure"),
              ProcessInfo.processInfo.environment["SPOOKKY_M1_DATA"] != nil,
              root.path.hasPrefix("/tmp/spookky-m1-") else { return nil }
        url = root.appendingPathComponent("workspace-timings.json")
        let descriptor = open(root.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let requests = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        requests.setEventHandler { [weak self] in
            Task { @MainActor in self?.recordCPU() }
        }
        requests.setCancelHandler { close(descriptor) }
        self.requests = requests; requests.resume()
    }
    func record(elapsed: Double, warm: Bool, surfaces: Int) {
        guard samples.count < 1000 else { return }
        samples.append(Sample(name: "selection_to_attached_and_focused", unit: "milliseconds", value: elapsed * 1000, warm: warm, surfaceCount: surfaces,
            residentMiB: Self.residentMiB()))
        let snapshot = samples, destination = url
        writer.async { try? PrivateFiles.write(snapshot, to: destination) }
    }
    static func residentMiB() -> Double? {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : nil
    }
    private struct CPU: Codable, Sendable {
        let request: String
        let pid: Int32
        let monotonic_seconds: Double
        let children_cpu_seconds: Double
        let history_marker: Int?
        let window_visible: Bool?
        let app_active: Bool
    }
    private func recordCPU() {
        let requestURL = url.deletingLastPathComponent().appendingPathComponent("cpu-request")
        guard let request = try? String(contentsOf: requestURL, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: requestURL)
        var usage = rusage()
        guard getrusage(RUSAGE_CHILDREN, &usage) == 0 else { return }
        let seconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let sample = CPU(request: request, pid: ProcessInfo.processInfo.processIdentifier, monotonic_seconds: ProcessInfo.processInfo.systemUptime,
            children_cpu_seconds: seconds, history_marker: historyMarker?(), window_visible: visibility?(), app_active: NSApplication.shared.isActive)
        let destination = url.deletingLastPathComponent().appendingPathComponent("workspace-cpu.json")
        writer.async { try? PrivateFiles.write(sample, to: destination) }
    }
    deinit { requests?.cancel() }
}
