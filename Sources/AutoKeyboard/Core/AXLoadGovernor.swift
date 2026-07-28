import Foundation
import os

/// 单次 AX 快照的实际开销度量。
///
/// `axReads` 统计真实发出的跨进程属性读取次数，`elapsed` 统计这些同步 IPC
/// 占用主线程的时间——极复杂页面上正是这两项把系统拖卡。
struct AXLoadSample: Equatable {
    var axReads: Int
    var elapsed: TimeInterval
    /// 是否因触发紧急熔断而提前中止遍历。
    var emergencyAborted: Bool = false

    static let zero = AXLoadSample(axReads: 0, elapsed: 0)

    func isOverloaded(limits: SmartLoadGuardSettings) -> Bool {
        elapsed >= limits.maxElapsedSeconds || axReads >= limits.maxAXReads
    }

    static func elapsed(since start: ContinuousClock.Instant) -> TimeInterval {
        let components = (ContinuousClock.now - start).components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}

/// AX 采样力度。`minimal` 只读光标文本与祖先链（读取次数有硬上限），
/// 跳过焦点区域与窗口正文的树遍历。
enum AXSamplingMode: Equatable {
    case full
    case minimal
}

/// 累计一次快照里发出的 AX 读取次数，并在遍历中实时检测是否触发紧急熔断。
@MainActor
final class AXReadMeter {
    private(set) var reads = 0
    private let startedAt: ContinuousClock.Instant
    private let emergencyReadLimit: Int
    private let emergencyTimeLimit: TimeInterval

    init(
        emergencyReadLimit: Int = 50,
        emergencyTimeLimit: TimeInterval = 0.1
    ) {
        self.startedAt = ContinuousClock.now
        self.emergencyReadLimit = emergencyReadLimit
        self.emergencyTimeLimit = emergencyTimeLimit
    }

    func add(_ count: Int = 1) {
        reads += count
    }

    /// 检查是否应立即中止遍历（紧急刹车）。
    /// 在遍历循环中定期调用，避免畸形 AX 树拖垮主线程。
    func shouldAbort() -> Bool {
        if reads >= emergencyReadLimit {
            return true
        }
        let elapsed = AXLoadSample.elapsed(since: startedAt)
        return elapsed >= emergencyTimeLimit
    }
}

/// 智能模式负载保护：按应用统计 AX 采样开销，连续超限就暂停该应用的智能模式。
///
/// 暂停后该应用只做 `minimal` 采样，`RuleEngine` 把能力降级为 `.overloaded`，
/// 智能判定与组件级学习都不再运行，改走窗口记忆/应用默认；冷却期满后放行一次
/// 完整采样试探，若仍然超限立即再次暂停。
@MainActor
final class AXLoadGovernor: ObservableObject {
    struct SuspendedApp: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let appName: String
        let recheckAt: Date
        let sample: AXLoadSample
    }

    private struct Suspension {
        var appName: String
        var recheckAt: Date
        var sample: AXLoadSample
        var emergencyAborted: Bool
    }

    private let settings: SettingsStore
    private let now: () -> Date
    private var suspensions: [String: Suspension] = [:]
    private var strikes: [String: Int] = [:]
    private let logger = Logger(subsystem: "com.autokeyboard", category: "axload")

    @Published private(set) var suspendedApps: [SuspendedApp] = []

    init(settings: SettingsStore, now: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.now = now
    }

    private var limits: SmartLoadGuardSettings {
        settings.value.smartLoadGuard
    }

    /// 该应用下一次快照应该用多大力度采样。
    func samplingMode(for bundleID: String) -> AXSamplingMode {
        guard limits.enabled, let suspension = suspensions[bundleID] else { return .full }
        // 紧急中止过的应用不再试探，永久保持 minimal
        if suspension.emergencyAborted {
            return .minimal
        }
        return now() < suspension.recheckAt ? .minimal : .full
    }

    /// 是否已被判定为"无法用智能模式识别"。冷却试探期内仍然算暂停中。
    func isSuspended(_ bundleID: String) -> Bool {
        limits.enabled && suspensions[bundleID] != nil
    }

    /// 记录一次**完整采样**的开销。`minimal` 采样天然便宜，不能用来解除暂停。
    func record(_ sample: AXLoadSample, bundleID: String, appName: String) {
        guard limits.enabled, !bundleID.isEmpty else { return }

        // 紧急中止：单次触发立即永久暂停，不再试探
        if sample.emergencyAborted {
            strikes[bundleID] = limits.overloadStrikes
            suspensions[bundleID] = Suspension(
                appName: appName.isEmpty ? bundleID : appName,
                recheckAt: .distantFuture,
                sample: sample,
                emergencyAborted: true
            )
            publish()
            logger.warning("smart mode permanently suspended due to emergency abort bundle=\(bundleID, privacy: .public)")
            return
        }

        guard sample.isOverloaded(limits: limits) else {
            strikes[bundleID] = nil
            if suspensions.removeValue(forKey: bundleID) != nil {
                publish()
                logger.debug("ax load recovered bundle=\(bundleID, privacy: .public)")
            }
            return
        }

        let count = strikes[bundleID, default: 0] + 1
        strikes[bundleID] = count
        logger.debug("ax load overloaded bundle=\(bundleID, privacy: .public) strike=\(count, privacy: .public)")
        guard count >= limits.overloadStrikes else { return }

        // 保留 strikes-1，冷却期后的试探若仍超限可立即再次暂停，不必重新攒满次数。
        strikes[bundleID] = max(0, limits.overloadStrikes - 1)
        suspensions[bundleID] = Suspension(
            appName: appName.isEmpty ? bundleID : appName,
            recheckAt: now().addingTimeInterval(limits.recheckInterval),
            sample: sample,
            emergencyAborted: false
        )
        publish()
        logger.warning("smart mode suspended bundle=\(bundleID, privacy: .public)")
    }

    /// 用户手动恢复某个应用的智能模式（包括紧急中止过的应用）。
    func resume(bundleID: String) {
        strikes[bundleID] = nil
        guard suspensions.removeValue(forKey: bundleID) != nil else { return }
        publish()
        logger.debug("smart mode manually resumed bundle=\(bundleID, privacy: .public)")
    }

    func resumeAll() {
        strikes.removeAll()
        guard !suspensions.isEmpty else { return }
        suspensions.removeAll()
        publish()
    }

    private func publish() {
        suspendedApps = suspensions
            .map { bundleID, suspension in
                SuspendedApp(
                    bundleID: bundleID,
                    appName: suspension.appName,
                    recheckAt: suspension.recheckAt,
                    sample: suspension.sample
                )
            }
            .sorted { $0.appName.localizedCompare($1.appName) == .orderedAscending }
    }
}
