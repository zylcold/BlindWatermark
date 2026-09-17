import Foundation

/// 页面注册表：`pageIndex → 类名` 的唯一权威映射。
///
/// 水印里放的是**从类名算出来的 4 字符短码**（见 `PageNameCodec`），所以这张表是**可选**的：
/// 没有表也能靠短码 `grep` 定位类名，表只用来在同码多命中时精确去歧义。
///
/// 因为它按「类名归一化」匹配而不是按下标匹配，**表与截图版本不一致也不会失效** ——
/// 这是相对索引方案的关键好处。接入端生成 JSON，解码端 `bwdecode --pages` 加载。
///
/// 文件格式就是字符串数组，索引即数组下标：
///
/// ```json
/// ["BHLoginViewController", "BHProfileViewController", "BHChatListViewController"]
/// ```
public struct PageRegistry: Equatable {
    public private(set) var names: [String]

    public init(names: [String]) {
        self.names = names
    }

    /// 从 JSON 文件加载。顶层是字符串数组。
    public init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.init(data: data)
    }

    public init?(data: Data) {
        guard let array = try? JSONDecoder().decode([String].self, from: data),
              !array.isEmpty else { return nil }
        self.names = array
    }

    /// 短码命中的类名。0 个说明这份表里没有该页面；多个就结合截图内容判断。
    public func matches(code: String) -> [String] {
        guard !code.isEmpty else { return [] }
        return names.filter { PageNameCodec.code(for: $0) == code }
    }

    /// 类名 → 短码的全量对照表，`bwdecode --dump-codes` 用，也方便 agent 一眼扫完。
    public var codeTable: [(code: String, name: String)] {
        names.map { (PageNameCodec.code(for: $0), $0) }
            .sorted { $0.0 < $1.0 }
    }

    /// 登记一个类名（不重复）。接入端可以在启动时把受监控页面都塞进来再落盘。
    public mutating func register(_ name: String) {
        guard !names.contains(name) else { return }
        names.append(name)
    }

    public var jsonData: Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(names)
    }

    /// 落盘。接入端在 Debug 构建里顺手写一份，CI 收集后给解码侧用。
    public func write(to url: URL) throws {
        guard let data = jsonData else {
            throw CocoaError(.coderInvalidValue)
        }
        try data.write(to: url, options: [.atomic])
    }
}
