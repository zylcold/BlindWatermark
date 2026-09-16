import Foundation

/// 类名短码：把 iOS 类名压成 10 个字符，塞进 60 bit。
///
/// 目标是**让 agent 能反推类名**，不是无损压缩。
/// iOS 类名冗余极高 —— `ViewController` 这 14 个字符几乎每个页面都有，
/// 剥掉它和 App 前缀之后，剩下的「特征词」才是唯一有信息量的部分：
///
/// ```
/// BHProfileViewController  → 剥 ViewController → 剥 BH → profile        → "profile"
/// BHChatListViewController → 剥 ViewController → 剥 BH → chatlist       → "chatlist"
/// BHLiveRoomViewController → 剥 ViewController → 剥 BH → liveroom       → "liveroom"
/// BHUserProfileEditViewController → …… → userprofileedit                → "userprofil"
/// ```
///
/// 允许撞名：拿到 `chatlist` 的 agent 只要在仓库里 `grep -rin "class.*chatlist"` 就能定位，
/// 真撞了也是拿到 2~3 个候选再结合截图内容判断 —— 比拿到一个纯数字 `3` 强得多。
///
/// 长度选 10：4 个字符时 1000 个页面撞名概率高达 23%（生日问题），10 个字符降到可以忽略，
/// 且大多数类名剥掉冗余词缀后本来就只剩 10 个字符上下，等于基本无损。
///
/// **算法必须与解码端严格一致**，改动等于让所有历史截图失效，所以这里只有这一份实现。
public enum PageNameCodec {
    /// 短码长度（字符数）。10 × 6 bit = 60 bit
    public static let codeLength = 10

    /// 37 个符号，每个占 6 bit。最后一个是补位符。
    public static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789_")
    static let padCharacter: Character = "_"

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

    /// 类名 → 短码。不足 10 字符的尾部补位符会被去掉，保证
    /// `decode(encode(code(for: name))) == code(for: name)` —— 否则和注册表比较时必然失配。
    /// 补位符 `_` 不属于归一化字符集，所以去掉不会产生歧义。
    public static func code(for className: String) -> String {
        let stem = normalizedStem(className)
        var characters = Array(stem.prefix(codeLength))
        while characters.count < codeLength {
            characters.append(padCharacter)
        }
        while characters.last == padCharacter {
            characters.removeLast()
        }
        return String(characters)
    }

    /// 短码 → 60 bit
    public static func encode(_ code: String) -> UInt64 {
        var value: UInt64 = 0
        var characters = Array(code.prefix(codeLength))
        while characters.count < codeLength {
            characters.append(padCharacter)
        }
        for (position, character) in characters.enumerated() {
            let index = alphabet.firstIndex(of: character) ?? alphabet.count - 1
            value |= UInt64(index) << (6 * UInt64(position))
        }
        return value
    }

    /// 60 bit → 短码。去掉尾部补位符。
    public static func decode(_ value: UInt64) -> String {
        var characters: [Character] = []
        for position in 0..<codeLength {
            let index = Int((value >> (6 * UInt64(position))) & 0x3F)
            characters.append(index < alphabet.count ? alphabet[index] : padCharacter)
        }
        while characters.last == padCharacter {
            characters.removeLast()
        }
        return String(characters)
    }

    /// 给 agent 用的 grep 提示。短码本身就是归一化后的前缀，直接搜即可。
    public static func grepHint(forCode code: String) -> String {
        code.isEmpty
            ? "短码为空，页面类名可能不含字母数字"
            : "grep -rin \"class.*\(code)\" --include='*.swift'"
    }
}
