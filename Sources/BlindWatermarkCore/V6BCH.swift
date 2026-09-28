import Foundation

/// BCH(511,211,t=40) over GF(512), primitive polynomial x^9+x^4+1.
/// 300 parity bits precede 211 information bits; bit 511 is overall even parity.
/// Roots alpha^1...alpha^80 fix the generator; tests pin its golden codeword.
public enum V6BCH {
    public static let codewordBits = 512
    public static let bchBits = 511
    public static let messageBits = 211
    public static let parityBits = 300
    public static let correctionLimit = 40
    public static let messageByteCount = 27
    public static let codewordByteCount = 64

    /// Decode diagnostics. A nil result means the BCH check could not produce a
    /// codeword whose systematic re-encoding matches the corrected bits.
    public struct Decoded: Equatable {
        public let messageBytes: [UInt8]
        public let codewordBytes: [UInt8]
        public let correctedBits: Int
    }

    private static let generator: [Bool] = {
        var roots = Set<Int>()
        for root in 1...(2 * correctionLimit) {
            var value = root
            repeat {
                roots.insert(value)
                value = value * 2 % bchBits
            } while value != root
        }
        var polynomial = [1]
        for root in roots.sorted() {
            var next = [Int](repeating: 0, count: polynomial.count + 1)
            for index in polynomial.indices {
                next[index] ^= gfMultiply(polynomial[index], gfExp(root))
                next[index + 1] ^= polynomial[index]
            }
            polynomial = next
        }
        precondition(polynomial.count == parityBits + 1 && polynomial.allSatisfy { $0 == 0 || $0 == 1 })
        return polynomial.map { $0 != 0 }
    }()
    private static let gfTables: (exp: [Int], log: [Int]) = {
        var exp = [Int](repeating: 0, count: 1022)
        var log = [Int](repeating: -1, count: 512)
        var value = 1
        for index in 0..<511 {
            exp[index] = value
            log[value] = index
            value <<= 1
            if (value & 0x200) != 0 { value ^= 0x211 }
        }
        for index in 511..<1022 { exp[index] = exp[index - 511] }
        return (exp, log)
    }()

    public static func encode(messageBytes: [UInt8]) -> [UInt8] {
        precondition(messageBytes.count == messageByteCount, "v6 BCH message must be 27 bytes")
        precondition(messageBytes[messageByteCount - 1] & 0xF8 == 0, "v6 message bits 211...215 must be zero padding")
        var work = [Bool](repeating: false, count: bchBits)
        for index in 0..<messageBits {
            work[parityBits + index] = bit(messageBytes, at: index)
        }

        // Polynomial long division. `work[degree]` is the coefficient of x^degree.
        if bchBits > parityBits {
            for pivot in stride(from: bchBits - 1, through: parityBits, by: -1) where work[pivot] {
                let shift = pivot - parityBits
                for offset in 0...parityBits where generator[offset] {
                    work[shift + offset].toggle()
                }
            }
        }

        var codeword = [Bool](repeating: false, count: codewordBits)
        for index in 0..<parityBits { codeword[index] = work[index] }
        for index in 0..<messageBits { codeword[parityBits + index] = bit(messageBytes, at: index) }
        codeword[511] = codeword[0..<511].reduce(false) { $0 != $1 }
        return pack(codeword)
    }

    /// Correct up to forty errors in the BCH portion. The extension parity bit is
    /// corrected separately after BCH recovery, so a single flipped extension bit
    /// remains recoverable without spending a BCH error budget.
    public static func decode(codewordBytes: [UInt8]) -> Decoded? {
        guard codewordBytes.count == codewordByteCount else { return nil }
        let received = unpack(codewordBytes, count: codewordBits)
        let bchReceived = Array(received.prefix(bchBits))
        guard let bch = decodeBCH(bchReceived) else { return nil }
        let corrected = bch.bits
        let expectedParity = corrected.reduce(false) { $0 != $1 }
        var correctedBits = bch.correctedBits
        if received[511] != expectedParity { correctedBits += 1 }

        var full = corrected
        full.append(expectedParity)
        let message = pack(Array(corrected[parityBits..<bchBits]))
        // Re-encoding is a cheap, unambiguous guard against a false locator.
        let codeword = pack(full)
        guard encode(messageBytes: message) == codeword else { return nil }
        return Decoded(messageBytes: message, codewordBytes: codeword, correctedBits: correctedBits)
    }

    // MARK: - Binary BCH decoder

    private struct BCHDecoded {
        let bits: [Bool]
        let correctedBits: Int
    }

    private static func decodeBCH(_ input: [Bool]) -> BCHDecoded? {
        let syndromeValues = syndromes(for: input)
        if syndromeValues.allSatisfy({ $0 == 0 }) {
            return BCHDecoded(bits: input, correctedBits: 0)
        }

        guard let locator = berlekampMassey(syndromeValues), locator.count > 1 else { return nil }
        let degree = locator.count - 1
        guard degree <= correctionLimit else { return nil }

        var positions = [Int]()
        positions.reserveCapacity(degree)
        for errorDegree in 0..<bchBits {
            // A coefficient at x^errorDegree contributes alpha^(j*errorDegree)
            // to syndrome j; its locator root is alpha^(-errorDegree).
            let x = errorDegree == 0 ? 1 : gfExp((511 - errorDegree) % 511)
            var value = 0
            var power = 1
            for coefficient in locator {
                value ^= gfMultiply(coefficient, power)
                power = gfMultiply(power, x)
            }
            if value == 0 { positions.append(errorDegree) }
        }
        guard positions.count == degree else { return nil }

        var corrected = input
        for position in positions { corrected[position].toggle() }
        guard syndromes(for: corrected).allSatisfy({ $0 == 0 }) else { return nil }
        return BCHDecoded(bits: corrected, correctedBits: positions.count)
    }

    /// Syndromes S_1...S_80. The bit array is in polynomial degree order.
    private static func syndromes(for bits: [Bool]) -> [Int] {
        (1...(2 * correctionLimit)).map { order in
            var value = 0
            for degree in 0..<bits.count where bits[degree] {
                value ^= gfExp((order * degree) % 511)
            }
            return value
        }
    }

    /// Berlekamp-Massey over GF(512), returning coefficients in ascending powers
    /// of x (`[1, lambda1, ...]`).
    private static func berlekampMassey(_ syndromes: [Int]) -> [Int]? {
        var connection = [Int](repeating: 0, count: 2 * correctionLimit + 1)
        var backup = [Int](repeating: 0, count: 2 * correctionLimit + 1)
        connection[0] = 1
        backup[0] = 1
        var length = 0
        var shift = 1
        var scale = 1

        for index in 0..<syndromes.count {
            var discrepancy = syndromes[index]
            if length > 0 {
                for coefficient in 1...length {
                    discrepancy ^= gfMultiply(connection[coefficient], syndromes[index - coefficient])
                }
            }
            if discrepancy == 0 {
                shift += 1
                continue
            }

            let previous = connection
            let factor = gfMultiply(discrepancy, gfInverse(scale))
            for coefficient in 0..<(connection.count - shift) where backup[coefficient] != 0 {
                connection[coefficient + shift] ^= gfMultiply(factor, backup[coefficient])
            }

            if 2 * length <= index {
                length = index + 1 - length
                backup = previous
                scale = discrepancy
                shift = 1
            } else {
                shift += 1
            }
            guard length <= correctionLimit else { return nil }
        }
        return Array(connection[0...length])
    }

    private static func gfExp(_ exponent: Int) -> Int {
        gfTables.exp[(exponent % 511 + 511) % 511]
    }

    private static func gfMultiply(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs != 0, rhs != 0 else { return 0 }
        return gfExp(gfTables.log[lhs] + gfTables.log[rhs])
    }

    private static func gfInverse(_ value: Int) -> Int {
        precondition(value != 0)
        return gfExp(511 - gfTables.log[value])
    }

    private static func bit(_ bytes: [UInt8], at index: Int) -> Bool {
        bytes[index >> 3] & (1 << UInt8(index & 7)) != 0
    }

    private static func pack(_ bits: [Bool]) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (index, value) in bits.enumerated() where value {
            bytes[index >> 3] |= 1 << UInt8(index & 7)
        }
        return bytes
    }

    private static func unpack(_ bytes: [UInt8], count: Int) -> [Bool] {
        (0..<count).map { bytes[$0 >> 3] & (1 << UInt8($0 & 7)) != 0 }
    }
}
