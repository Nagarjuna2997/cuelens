import Foundation
import Observation

enum ResourceCondition: String {
    case normal = "Normal"
    case constrained = "Under pressure"
    case critical = "Critical"

    static func evaluate(thermal: ProcessInfo.ThermalState, memory: DispatchSource.MemoryPressureEvent) -> Self {
        if thermal == .critical || memory.contains(.critical) { return .critical }
        if thermal == .serious || memory.contains(.warning) { return .constrained }
        return .normal
    }

    var reducesWork: Bool { self != .normal }
}

@MainActor
@Observable
final class Resources {
    private(set) var condition = ResourceCondition.normal
    private(set) var memoryMB: Double?
    private(set) var cpuPercent: Double?
    private(set) var thermal = ProcessInfo.processInfo.thermalState
    var onConditionChange: ((ResourceCondition) -> Void)?

    @ObservationIgnored private var pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var memoryEvent = DispatchSource.MemoryPressureEvent.normal
    @ObservationIgnored private var previous: (elapsed: Double, cpu: Double)?

    init() {
        pressure.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.memoryEvent = self.pressure.data
                self.refreshCondition()
            }
        }
        pressure.resume()
        observer = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { self?.refreshCondition() }
        }
        refreshCondition()
    }

    func sample() {
        var memory = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &memory) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        memoryMB = result == KERN_SUCCESS ? Double(memory.phys_footprint) / 1_048_576 : nil

        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
            let cpu = user + system
            let elapsed = ProcessInfo.processInfo.systemUptime
            if let previous, elapsed - previous.elapsed > 0.25 {
                cpuPercent = max(0, (cpu - previous.cpu) * 100 / (elapsed - previous.elapsed))
            }
            previous = (elapsed, cpu)
        }
    }

    private func refreshCondition() {
        thermal = ProcessInfo.processInfo.thermalState
        let new = ResourceCondition.evaluate(thermal: thermal, memory: memoryEvent)
        guard new != condition else { return }
        condition = new
        onConditionChange?(new)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        pressure.cancel()
    }
}
