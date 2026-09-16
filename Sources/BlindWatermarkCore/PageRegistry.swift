import Foundation

/// 页面注册表：`pageIndex → 类名` 的唯一权威映射。
///
/// 水印里只能放 16 bit 的页面索引，类名要靠这张表还原。
/// 接入端生成 JSON，解码端 `bwdecode --pages` 加载同一份 —— **两边必须是同一张表**，
/// 表换了版本，旧截图解出的索引就对不上，所以建议带版本号进 git。
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

    /// 索引越界返回 nil —— 拿到 nil 说明注册表和截图不是同一版本，别硬猜类名。
    public func name(for index: Int) -> String? {
        guard names.indices.contains(index) else { return nil }
        return names[index]
    }

    /// 反查：类名 → 索引。接入端生成载荷时用；不存在就追加并返回新索引，
    /// 这样页面出现顺序天然决定索引，不需要提前登记。
    public mutating func index(for name: String) -> Int {
        if let found = names.firstIndex(of: name) { return found }
        names.append(name)
        return names.count - 1
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
