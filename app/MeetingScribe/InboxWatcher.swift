import Foundation

// 前回の確認からサイズが変わっていないファイルを、同期が終わったものとみなして古い順に返す
final class InboxWatcher {
    private let dir: String
    private var sizes: [String: UInt64] = [:]
    private var attempted = Set<String>()

    init(dir: String) {
        self.dir = dir
    }

    // 失敗した取り込みは受け取りフォルダに残るので、同じファイルはアプリの起動中に一度しか返さない
    func nextReadyFile() -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        for name in names where name.hasPrefix(".") && name.hasSuffix(".icloud") {
            let original = String(name.dropFirst().dropLast(".icloud".count))
            try? FileManager.default.startDownloadingUbiquitousItem(at: URL(fileURLWithPath: "\(dir)/\(original)"))
        }
        var current: [String: UInt64] = [:]
        for name in names where !name.hasPrefix(".") {
            let path = "\(dir)/\(name)"
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? UInt64 else { continue }
            current[path] = size
        }
        let previous = sizes
        sizes = current
        let ready = current.filter { previous[$0.key] == $0.value && !attempted.contains($0.key) }.keys
        guard let path = ready.min(by: { (birthDate($0) ?? .distantFuture) < (birthDate($1) ?? .distantFuture) })
        else { return nil }
        attempted.insert(path)
        return path
    }

    private func birthDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.creationDate] as? Date
    }
}
