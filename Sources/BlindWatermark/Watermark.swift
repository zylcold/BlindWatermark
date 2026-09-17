#if canImport(UIKit)
import UIKit
import BlindWatermarkCore
import BlindWatermarkAutoLoad

/// SPM 下 `BlindWatermarkCore` 是另一个模块，接入方只 `import BlindWatermark` 时也得能拿到这个枚举。
public typealias WatermarkPlane = BlindWatermarkCore.WatermarkPlane

/// 屏上盲水印入口。
///
/// 常驻覆盖 App 全部界面，截图必然带水印，事后用 `bwdecode` 从截图还原 payload 溯源。
public enum Watermark {

    /// 手动接入：立刻设置 payload，并挂载到当前所有 scene（后续新 scene 自动挂载）。
    ///
    ///     Watermark.install(payload: serverIssued16Bytes)
    public static func install(
        payload: [UInt8],
        payloadBits: Int? = nil,
        delta: UInt8 = 8,
        plane: WatermarkPlane = .chroma
    ) {
        WatermarkState.shared.configure(
            payload: payload,
            payloadBits: payloadBits ?? payload.count * 8,
            delta: delta,
            plane: plane
        )
        WatermarkState.shared.start()
    }

    /// 换页面时重画图案。相位不变，解码端无感；生成一张 tile 是微秒级，导航时随手调。
    ///
    ///     Watermark.update(payload: WatermarkPayload(uid: uid, timestamp: ts, pageIndex: 3, ...).bytes)
    public static func update(payload: [UInt8], payloadBits: Int? = nil) {
        WatermarkState.shared.configure(
            payload: payload,
            payloadBits: payloadBits ?? payload.count * 8,
            delta: WatermarkState.shared.effectiveConfig().delta,
            plane: WatermarkState.shared.effectiveConfig().plane
        )
        WatermarkState.shared.refreshPatterns()
    }

    /// 32 bit 便捷入口
    public static func install(
        payload: UInt32,
        payloadBits: Int = 32,
        delta: UInt8 = 8,
        plane: WatermarkPlane = .chroma
    ) {
        var bytes = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 { bytes[i] = UInt8((payload >> (8 * UInt32(i))) & 0xFF) }
        install(payload: bytes, payloadBits: payloadBits, delta: delta, plane: plane)
    }

    /// 零接入模式下的 payload 来源。默认用 `identifierForVendor` + 时间桶拼一个 32 位值。
    ///
    /// 生产环境应当换掉：payload 需要服务端下发并签名，客户端不要持有明文映射表。
    public static var payloadProvider: (() -> [UInt8])? {
        get { WatermarkState.shared.payloadProvider }
        set { WatermarkState.shared.payloadProvider = newValue }
    }
}

/// 内部状态，全局只有一份。
final class WatermarkState {
    static let shared = WatermarkState()

    struct Config {
        var payload: [UInt8]
        var payloadBits: Int
        var delta: UInt8
        var plane: WatermarkPlane
    }

    var payloadProvider: (() -> [UInt8])?

    private var config: Config?
    private var windows: [ObjectIdentifier: WatermarkWindow] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    private var started = false

    private init() {}

    func configure(payload: [UInt8], payloadBits: Int, delta: UInt8, plane: WatermarkPlane) {
        config = Config(payload: payload, payloadBits: payloadBits, delta: delta, plane: plane)
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

    func refreshPatterns() {
        for window in windows.values {
            guard let scene = window.windowScene else { continue }
            // ponytail: 仅在 App 激活时重画，displayScale 中途变化（外接屏）不处理；
            // 真接了 iPad 外接屏再监听 traitCollectionDidChange。
            if let pattern = makePattern(scale: scene.traitCollection.displayScale) {
                window.update(pattern: pattern)
            }
        }
    }

    func effectiveConfig() -> Config {
        if let config { return config }
        let payload = payloadProvider?() ?? WatermarkDefaultPayload.currentBytes()
        return Config(payload: payload, payloadBits: min(BlockCodec.maxPayloadBits, payload.count * 8), delta: 8, plane: .chroma)
    }

    private func makePattern(scale: CGFloat) -> UIImage? {
        let config = effectiveConfig()
        let tile = BlockCodec.makeTile(
            payload: config.payload,
            payloadBits: config.payloadBits,
            alpha: config.delta,
            plane: config.plane
        )
        guard let cgImage = tile.makeCGImage() else { return nil }
        // scale 与屏幕一致，tile 才是 256 **设备像素**，块大小恒定 16 设备像素
        return UIImage(cgImage: cgImage, scale: max(1, scale), orientation: .up)
    }
}

/// 默认 payload：uid 位填设备哈希，时间戳填当前 Unix 秒，页面/标签留 0，mac 留 0。
/// ponytail: 无签名可被伪造。上生产换成服务端下发的 WatermarkPayload。
enum WatermarkDefaultPayload {
    static func currentBytes() -> [UInt8] {
        WatermarkPayload(
            uid: deviceHash(),
            timestamp: UInt32(max(0, min(Date().timeIntervalSince1970, Double(UInt32.max)))),
            pageIndex: 0,
            appTag: 0,
            mac: 0
        ).bytes
    }

    static func deviceHash() -> UInt32 {
        let seed = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-vendor"
        return fnv1a(seed)
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
