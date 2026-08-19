// MemoryReport.swift — the memory instrumentation the whole plan hinges on.
//
// The competitive bet is footprint: fit under the per-app jetsam ceiling on a
// 6 GB device where rivals need 8 GB. To know where we stand we must measure the
// number iOS ACTUALLY kills on — and that number is NOT `resident_size`.
//
//  * iOS jetsam is driven by `phys_footprint` (task_vm_info) — dirty + swapped
//    + IOKit-mapped pages the process is charged for. Measuring resident_size
//    (a common mistake) under-reports and hides the real headroom.
//  * `os_proc_available_memory()` (iOS 13+) returns the bytes remaining before
//    THIS app hits its own jetsam limit — the exact margin we care about, with
//    no need to hardcode a per-model table.
//
// Every stage (launch → Init → BootGame → in-game) logs a sample to a file, so a
// single on-device session captures the whole footprint curve at once — no
// wasted device time. On desktop/x86 the same call sites give an indicative
// number (different allocator + 4 KB vs iOS 16 KB pages, no jetsam), which is
// enough to validate that a memory lever moved the needle before we confirm the
// exact figure on hardware.

import Foundation
import Observation

struct MemorySample: Identifiable, Sendable {
    let id = UUID()
    let stage: String
    let date: Date
    /// The value iOS jetsam charges the app for (MB). This is the one that matters.
    let physFootprintMB: Double
    /// Bytes remaining before THIS app is jetsam-eligible, MB. 0 = unavailable
    /// (not foreground, or pre-iOS 13). Higher is safer.
    let availableBeforeJetsamMB: Double
    /// Plain resident set (MB) — kept only for cross-referencing desktop tools.
    let residentMB: Double

    var line: String {
        String(format: "%@  footprint=%.1f MB  avail_before_jetsam=%@  resident=%.1f MB",
                stage, physFootprintMB,
                availableBeforeJetsamMB > 0 ? String(format: "%.1f MB", availableBeforeJetsamMB) : "n/a",
                residentMB)
    }
}

@Observable
final class MemoryReport: @unchecked Sendable {
    static let shared = MemoryReport()

    private(set) var samples: [MemorySample] = []
    /// The most recent sample, for a live on-screen readout.
    private(set) var latest: MemorySample?

    private let logName = "ips3_mem.txt"
    private init() {}

    // MARK: - Public API

    /// Take a labelled sample, publish it, and append it to the on-device log.
    @discardableResult
    func log(_ stage: String) -> MemorySample {
        let s = MemorySample(
            stage: stage,
            date: Date(),
            physFootprintMB: Double(Self.physFootprintBytes()) / 1_048_576.0,
            availableBeforeJetsamMB: Double(Self.availableBeforeJetsamBytes()) / 1_048_576.0,
            residentMB: Double(Self.residentBytes()) / 1_048_576.0)
        samples.append(s)
        latest = s
        appendToLog(s)
        NSLog("[iPS3 Mem] %@", s.line)
        return s
    }

    /// Sample WITHOUT writing to the log — for a live on-screen readout that
    /// updates on a timer. Only labelled stage transitions belong in the file.
    func refresh() {
        latest = MemorySample(
            stage: "live",
            date: Date(),
            physFootprintMB: Double(Self.physFootprintBytes()) / 1_048_576.0,
            availableBeforeJetsamMB: Double(Self.availableBeforeJetsamBytes()) / 1_048_576.0,
            residentMB: Double(Self.residentBytes()) / 1_048_576.0)
    }

    /// A one-line summary for a compact on-screen overlay.
    var readout: String {
        guard let s = latest else { return "mem: —" }
        if s.availableBeforeJetsamMB > 0 {
            return String(format: "mem %.0f MB · %.0f MB free before kill",
                          s.physFootprintMB, s.availableBeforeJetsamMB)
        }
        return String(format: "mem %.0f MB", s.physFootprintMB)
    }

    // MARK: - Virtual-address probe (is extended-virtual-addressing effective?)

    struct VAProbe: Sendable {
        let maxReservableGiB: Double
        /// Coarse verdict for the log line.
        let verdict: String
    }

    /// The core reserves tens of GiB of virtual address at load (its biggest
    /// single region is ~32 GiB). Without the extended-virtual-addressing
    /// entitlement TAKING EFFECT, iOS caps the process's address space (~4 GiB
    /// here) and those reservations fall back to a tiny size — Init still runs,
    /// but no game can boot. Declaring the entitlement is not the same as it
    /// being honoured by the signer, so we do not read the plist: we MEASURE the
    /// largest PROT_NONE / MAP_NORESERVE reservation the process can actually
    /// make. That empirical ceiling is the real gate.
    static func probeReservableVA() -> VAProbe {
        let gib: UInt64 = 1 << 30
        let sizes: [UInt64] = [1, 2, 4, 8, 12, 16, 24, 32, 48, 64].map { $0 * gib }
        var best: UInt64 = 0
        for s in sizes {
            let p = mmap(nil, Int(s), PROT_NONE, MAP_ANON | MAP_PRIVATE | MAP_NORESERVE, -1, 0)
            if p == MAP_FAILED { break }         // once one size fails, larger ones will too
            best = s
            munmap(p, Int(s))
        }
        let gibValue = Double(best) / Double(gib)
        let verdict: String
        switch best {
        case let b where b >= 32 * gib: verdict = "extended-VA EFFECTIVE (full reservation possible)"
        case let b where b >= 8 * gib:  verdict = "PARTIAL — larger than default cap but under the 32 GiB the core wants"
        default:                        verdict = "CAPPED — extended-VA NOT effective; games cannot boot"
        }
        return VAProbe(maxReservableGiB: gibValue, verdict: verdict)
    }

    /// Run the VA probe once and write the verdict to the log. Idempotent.
    private var didProbeVA = false
    func logVAProbe() {
        guard !didProbeVA else { return }
        didProbeVA = true
        let p = Self.probeReservableVA()
        let line = String(format: "va-probe: max_reservable=%.0f GiB — %@", p.maxReservableGiB, p.verdict)
        NSLog("[iPS3 Mem] %@", line)
        let stamp = ISO8601DateFormatter().string(from: Date())
        let entry = "\(stamp)  \(line)\n"
        if let data = entry.data(using: .utf8) {
            let url = logURL
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? ("iPS3 memory log\n" + entry).data(using: .utf8)?.write(to: url)
            }
        }
    }

    // MARK: - Raw metrics

    /// `phys_footprint` from task_vm_info — the jetsam accounting value.
    static func physFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }

    /// Bytes left before this app hits its own jetsam limit (iOS 13+).
    static func availableBeforeJetsamBytes() -> UInt64 {
        // os_proc_available_memory() returns 0 when unavailable; guard on that.
        let avail = os_proc_available_memory()
        return avail > 0 ? UInt64(avail) : 0
    }

    /// Classic resident_size — for lining up against desktop reference readings only.
    static func residentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    // MARK: - Log file

    private var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(logName)
    }

    private func appendToLog(_ s: MemorySample) {
        let stamp = ISO8601DateFormatter().string(from: s.date)
        let entry = "\(stamp)  \(s.line)\n"
        guard let data = entry.data(using: .utf8) else { return }
        let url = logURL
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            let header = "iPS3 memory log\n"
            try? (header + entry).data(using: .utf8)?.write(to: url)
        }
    }
}
