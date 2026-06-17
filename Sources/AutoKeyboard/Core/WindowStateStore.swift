import Foundation

@MainActor
protocol WindowStateStoring: AnyObject {
    func record(_ key: WindowKey, sourceID: String)
    func lookup(_ key: WindowKey) -> String?
    func clear()
}

@MainActor
final class WindowStateStore: WindowStateStoring {
    private var map: [WindowKey: String] = [:]
    private var order: [WindowKey] = []
    private let capacity = 500

    func record(_ key: WindowKey, sourceID: String) {
        if map[key] == nil {
            order.append(key)
            if order.count > capacity {
                let evicted = order.removeFirst()
                map[evicted] = nil
            }
        }
        map[key] = sourceID
    }

    func lookup(_ key: WindowKey) -> String? {
        map[key]
    }

    func clear() {
        map.removeAll()
        order.removeAll()
    }
}
