import Foundation

@MainActor
final class WindowStateStore {
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
