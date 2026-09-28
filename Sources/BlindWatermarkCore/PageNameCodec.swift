import Foundation

/// v6 页面短码只保留归一化后的前八个字符。
public enum PageNameCodec {
    /// 短码长度（字符数）。截断可能碰撞，不能将短码当唯一类名。
    public static let codeLength = 8
    /// 按长度降序：先剥长的，避免 `ViewController` 只剥掉 `Controller` 留下 `BHProfileView`。
    /// 只剥**词尾**，且剥完不能为空。
    public static let suffixLadder = [
        "ViewController", "ViewModel", "Presenter", "Interactor",
        "Controller", "View", "Page", "Screen", "Scene", "Cell", "Item", "Model", "VC",
    ]

    /// 已知 App / 模块前缀。剥完不能为空。
    public static let knownPrefixes = ["BH", "JY", "LL", "HW", "XQ"]

    /// 归一化：取最后一段类名 → 剥后缀（最多两层）→ 剥前缀 → 小写 → 只留字母数字。
    public static func normalizedStem(_ className: String) -> String {
        var name = className.split(separator: ".").last.map(String.init) ?? className

        var strippedSuffixes = 0
        var changed = true
        while changed, strippedSuffixes < 2 {
            changed = false
            for suffix in suffixLadder where name.count > suffix.count && name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
                strippedSuffixes += 1
                changed = true
                break
            }
        }

        for prefix in knownPrefixes where name.count > prefix.count && name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }

        return name.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// 类名 → 短码。不足 `length` 的尾部补位符会被去掉，保证
    /// `decode(encode(code(for: name))) == code(for: name)` —— 保证接入与解码端使用相同的规范形式。
    /// 补位符 `_` 不属于归一化字符集，所以去掉不会产生歧义。
    public static func code(for className: String, length: Int = codeLength) -> String {
        String(normalizedStem(className).prefix(max(0, length)))
    }
}
