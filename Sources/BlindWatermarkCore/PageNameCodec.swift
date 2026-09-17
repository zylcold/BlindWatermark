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
    /// 短码长度（字符数）。15 × 6 bit = 90 bit —— 大多数类名剥掉冗余词缀后 ≤ 15 字符，够用。
    public static let codeLength = 15
    /// 短码占用的字节数（96 bit，其中 90 bit 有效）；高 6 bit 必须为 0，结构自检会查
    public static let codeByteCount = 12

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

    /// 类名 → 短码。不足 `length` 的尾部补位符会被去掉，保证
    /// `decode(encode(code(for: name))) == code(for: name)` —— 否则和注册表比较时必然失配。
    /// 补位符 `_` 不属于归一化字符集，所以去掉不会产生歧义。
    public static func code(for className: String, length: Int = codeLength) -> String {
        let stem = normalizedStem(className)
        var characters = Array(stem.prefix(length))
        while characters.count < length {
            characters.append(padCharacter)
        }
        while characters.last == padCharacter {
            characters.removeLast()
        }
        return String(characters)
    }

    // MARK: - 变长（v4 的 120 bit / 20 字符）

    /// 短码字节数 = ceil(字符数 × 6 / 8)，再向上取到 12 字节（15 字符 → 90 bit → 12 字节）。
    /// 多出来的 6 bit 留 0，结构自检会校验它 —— 等于白拿 6 bit 判别力。
    public static func byteCount(forLength length: Int) -> Int {
        max(codeByteCount, (length * 6 + 7) / 8)
    }

    /// 短码 → 小端字节（每字符 6 bit，低位在前）
    public static func encodeBytes(_ code: String, length: Int = codeLength) -> [UInt8] {
        var characters = Array(code.prefix(length))
        while characters.count < length {
            characters.append(padCharacter)
        }
        var bytes = [UInt8](repeating: 0, count: byteCount(forLength: length))
        for (position, character) in characters.enumerated() {
            let index = alphabet.firstIndex(of: character) ?? alphabet.count - 1
            let bit = 6 * position
            for offset in 0..<6 where index & (1 << offset) != 0 {
                let target = bit + offset
                bytes[target >> 3] |= 1 << UInt8(target & 7)
            }
        }
        return bytes
    }

    /// 小端字节 → 短码。去掉尾部补位符。
    public static func decodeBytes(_ bytes: [UInt8], length: Int = codeLength) -> String {
        var characters: [Character] = []
        for position in 0..<length {
            var index = 0
            for offset in 0..<6 {
                let source = 6 * position + offset
                if source >> 3 < bytes.count, bytes[source >> 3] & (1 << UInt8(source & 7)) != 0 {
                    index |= 1 << offset
                }
            }
            characters.append(index < alphabet.count ? alphabet[index] : padCharacter)
        }
        while characters.last == padCharacter {
            characters.removeLast()
        }
        return String(characters)
    }

    /// 字节里的每个 6-bit 字符是否都落在字母表内（结构自检用），且填充位必须为 0。
    /// 字符表约束约 10 bit 判别力，填充位再给 6 bit：0..<37 合法，37..<64 非法。
    public static func validateBytes(_ bytes: [UInt8], length: Int = codeLength) -> Bool {
        for position in 0..<length {
            var index = 0
            for offset in 0..<6 {
                let source = 6 * position + offset
                if source >> 3 < bytes.count, bytes[source >> 3] & (1 << UInt8(source & 7)) != 0 {
                    index |= 1 << offset
                }
            }
            if index >= alphabet.count { return false }
        }
        // 未被字符用到的比特必须为 0（15 字符只用 90 bit，字段有 96 bit）
        let usedBits = length * 6
        let totalBits = bytes.count * 8
        for bit in usedBits..<totalBits where bytes[bit >> 3] & (1 << UInt8(bit & 7)) != 0 {
            return false
        }
        return true
    }

    /// 给 agent 用的 grep 提示。短码本身就是归一化后的前缀，直接搜即可。
    public static func grepHint(forCode code: String) -> String {
        code.isEmpty
            ? "短码为空，页面类名可能不含字母数字"
            : "grep -rin \"class.*\(code)\" --include='*.swift'"
    }
}