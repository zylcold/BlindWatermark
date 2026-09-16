#if canImport(UIKit)
import UIKit
import BlindWatermarkCore
import BlindWatermarkAutoLoad

/// 屏上盲水印入口。
///
/// 常驻覆盖 App 全部界面，截图必然带水印，事后用 `bwdecode` 从截图还原 payload 溯源。
public enum Watermark {

    /// 手动接入：立刻设置 payload，并挂载到当前所有 scene（后续新 scene 自动挂载）。
    ///
    ///     Watermark.install(payload: serverIssuedPayload)
    public static func install(payload: UInt32, payloadBits: Int = 32, delta: UInt8 = 6) {
        WatermarkState.shared.configure(
            payload: payload,
            payloadBits: payloadBits,
            delta: delta
        )
        WatermarkState.shared.start()
    }

    /// 零接入模式下的 payload 来源。默认用 `identifierForVendor` + 时间桶拼一个 32 位值。
    ///
    /// 生产环境应当换掉：payload 需要服务端下发并签名，客户端不要持有明文映射表。
    public static var payloadProvider: (() -> UInt32)? {
        get { WatermarkState.shared.payloadProvider }
        set { WatermarkState.shared.payloadProvider = newValue }
    }
}

/// 内部状态，全局只有一份。
final class WatermarkState {
    static let shared = WatermarkState()

    struct Config {
        var payload: UInt32
        var payloadBits: Int
        var delta: UInt8
    }

    var payloadProvider: (() -> UInt32)?

    private var config: Config?
    private var windows: [ObjectIdentifier: WatermarkWindow] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    func configure(payload: UInt32, payloadBits: Int, delta: UInt8) {
        config = Config(payload: payload, payloadBits: payloadBits, delta: delta)
    }

    /// 幂等。首次调用注册通知，之后只刷新图案。
    func start() {
        // 建立对 ObjC 自动加载目标的符号引用，否则静态链接会丢掉它的 +load
        LLBlindWatermarkAutoLoadEnable()

        if started {
            refreshPatterns()
            return
        }
        started = true

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: UIWindowScene.didActivateNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let scene = note.object as? UIWindowScene else { return }
            self?.attach(to: scene)
        })
        observerTokens.append(center.addObserver(
            forName: UIScene.didDisconnectNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let scene = note.object as? UIScene else { return }
            self?.windows.removeValue(forKey: ObjectIdentifier(scene))
        })
        // 时间桶会变，回前台时按新 payload 重画
        observerTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshPatterns()
        })

        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene {
                attach(to: windowScene)
            }
        }
        refreshPatterns()
    }

    // MARK: - 内部

    private func attach(to scene: UIWindowScene) {
        let key = ObjectIdentifier(scene)
        guard windows[key] == nil else { return }
        guard let pattern = makePattern(scale: scene.traitCollection.displayScale) else { return }
        windows[key] = WatermarkWindow(scene: scene, pattern: pattern)
    }

    private func refreshPatterns() {
        for window in windows.values {
            guard let scene = window.windowScene else { continue }
            // ponytail: 仅在 App 激活时重画，displayScale 中途变化（外接屏）不处理；
            // 真接了 iPad 外接屏再监听 traitCollectionDidChange。
            if let pattern = makePattern(scale: scene.traitCollection.displayScale) {
                window.update(pattern: pattern)
            }
        }
    }

    private func effectiveConfig() -> Config {
        if let config { return config }
        let payload = payloadProvider?() ?? WatermarkDefaultPayload.current()
        return Config(payload: payload, payloadBits: 32, delta: 6)
    }

    private func makePattern(scale: CGFloat) -> UIImage? {
        let config = effectiveConfig()
        let tile = BlockCodec.makeTile(
            payload: config.payload,
            payloadBits: config.payloadBits,
            alpha: config.delta
        )
        guard let cgImage = tile.makeCGImage() else { return nil }
        // scale 与屏幕一致，tile 才是 256 **设备像素**，块大小恒定 16 设备像素
        return UIImage(cgImage: cgImage, scale: max(1, scale), orientation: .up)
    }
}

/// 默认 payload：16 位设备哈希 + 16 位时间桶。
/// ponytail: 32 位只够 POC，且无签名可被伪造。上生产换成服务端下发 + 校验。
enum WatermarkDefaultPayload {
    /// 时间桶粒度（秒），决定溯源精度上限
    static let bucketSeconds: TimeInterval = 600

    static func current() -> UInt32 {
        (deviceHash() << 16) | timeBucket()
    }

    static func deviceHash() -> UInt32 {
        let seed = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-vendor"
        return fnv1a(seed) & 0xFFFF
    }

    static func timeBucket() -> UInt32 {
        UInt32(Date().timeIntervalSince1970 / bucketSeconds) & 0xFFFF
    }

    static func fnv1a(_ string: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }
}

#endif
