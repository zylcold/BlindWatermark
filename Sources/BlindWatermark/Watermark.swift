#if canImport(UIKit)
import UIKit
import BlindWatermarkCore
import BlindWatermarkAutoLoad

public typealias WatermarkPayload = BlindWatermarkCore.WatermarkPayload
public typealias WatermarkPlane = BlindWatermarkCore.WatermarkPlane

/// 「抗微信压缩」档：顶部/底部 1pt 可见亮度条码。
/// v6 色度盲水印在缩放+强压缩链路会丢，条码专补这条链路；裁切即失效，两层互补。
public enum WatermarkStripMode: Equatable {
    /// 关闭条码，只保留 v6 色度盲水印。
    case off
    /// 顶部+底部各一条 1pt 条码（默认）。
    case topAndBottom
}

/// 所有入口仅渲染 v6；完整字段由类型校验，不能传任意 bit 布局。
public enum Watermark {
    public static let defaultWindowLevel: UIWindow.Level = .alert + 1

    /// - Parameter strip: 抗微信压缩条码，默认 `.topAndBottom`（开启）。传 `.off` 关闭。
    public static func install(payload: WatermarkPayload, delta: UInt8 = V6Codec.defaultDelta,
                               plane: WatermarkPlane = .chroma,
                               windowLevel: UIWindow.Level = defaultWindowLevel,
                               strip: WatermarkStripMode = .topAndBottom) {
        precondition(Thread.isMainThread, "Watermark UI must be configured on the main thread")
        precondition(delta >= 2)
        WatermarkState.shared.config = .init(payload: payload, delta: delta, plane: plane,
                                              windowLevel: windowLevel, strip: strip)
        WatermarkState.shared.start()
    }

    public static func update(payload: WatermarkPayload) {
        precondition(Thread.isMainThread, "Watermark UI must be configured on the main thread")
        var config = WatermarkState.shared.effectiveConfig()
        config.payload = payload
        WatermarkState.shared.config = config
        WatermarkState.shared.refreshPatterns()
    }

    /// 无显式 install 时，每次回前台与换页刷新从这个类型化入口取载荷。
    public static var payloadProvider: (() -> WatermarkPayload)? {
        get { WatermarkState.shared.payloadProvider }
        set {
            precondition(Thread.isMainThread)
            WatermarkState.shared.payloadProvider = newValue
        }
    }
}

final class WatermarkState {
    static let shared = WatermarkState()
    struct Config {
        var payload: WatermarkPayload
        var delta: UInt8 = V6Codec.defaultDelta
        var plane: WatermarkPlane = .chroma
        var windowLevel: UIWindow.Level = Watermark.defaultWindowLevel
        /// 抗微信压缩条码，默认开启。
        var strip: WatermarkStripMode = .topAndBottom
    }
    var config: Config?
    var payloadProvider: (() -> WatermarkPayload)?
    private var windows: [ObjectIdentifier: WatermarkWindow] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    private var started = false
    private init() {}

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
        // 载荷里的时间戳会变，回前台时按新 payload 重画
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
        let window = WatermarkWindow(scene: scene, pattern: pattern, level: effectiveConfig().windowLevel)
        windows[key] = window
        window.setStripEnabled(effectiveConfig().strip != .off)
        refreshStrips(for: window, scene: scene)
    }

    func refreshPatterns() {
        for window in windows.values {
            guard let scene = window.windowScene else { continue }
            window.windowLevel = effectiveConfig().windowLevel
            window.setStripEnabled(effectiveConfig().strip != .off)
            if let pattern = makePattern(scale: scene.traitCollection.displayScale) {
                window.update(pattern: pattern)
            }
            refreshStrips(for: window, scene: scene)
        }
    }

    /// 生成并挂载顶部/底部条码位图。块宽按 pt 自适应，保证 ≥ minBlocks 块。
    private func refreshStrips(for window: WatermarkWindow, scene: UIWindowScene) {
        guard effectiveConfig().strip != .off else {
            window.updateStrips(top: nil, bottom: nil)
            return
        }
        let scale = max(1, scene.traitCollection.displayScale)
        let widthPx = Int(scene.coordinateSpace.bounds.width * scale)
        guard widthPx >= StripWatermark.minBlocks * 6 else { return }
        // 块宽 pt：至少 minBlocks 块，不小于 4pt（太窄抗不住 JPEG）
        let widthPt = Int(scene.coordinateSpace.bounds.width)
        let blockPt = max(4, widthPt / StripWatermark.minBlocks)
        let blockPx = Double(blockPt) * Double(scale)
        let stripPx = max(1, Int(scale))
        let bits = StripWatermark.bits(payload: effectiveConfig().payload)
        var image = RGBAImage(width: widthPx, height: stripPx)
        StripWatermark.render(into: &image, bits: bits, blockWidthPx: blockPx,
                              stripHeightPx: stripPx, edge: .top)
        guard let cg = image.makeCGImage() else { return }
        let ui = UIImage(cgImage: cg, scale: CGFloat(scale), orientation: .up)
        window.updateStrips(top: ui, bottom: ui)
    }

    func effectiveConfig() -> Config {
        config ?? Config(payload: payloadProvider?() ?? WatermarkDefaultPayload.current())
    }

    private func makePattern(scale: CGFloat) -> UIImage? {
        let config = effectiveConfig()
        let tile = V6Codec.makeTile(payload: config.payload, delta: config.delta, plane: config.plane)
        guard let image = tile.makeCGImage() else { return nil }
        return UIImage(cgImage: image, scale: max(1, scale), orientation: .up)
    }
}

/// 零接入用 IDFV 哈希跑通链路；该 uid 不可逆，也不是身份凭据。
enum WatermarkDefaultPayload {
    static func current() -> WatermarkPayload {
        let seed = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-vendor"
        var hash: UInt32 = 0x811C_9DC5
        for byte in seed.utf8 { hash = (hash ^ UInt32(byte)) &* 0x0100_0193 }
        let now = UInt64(max(Double(WatermarkPayload.timestampEpoch), Date().timeIntervalSince1970))
        return WatermarkPayload(uid: hash, timestamp: now, buildTime: WatermarkPayload.timestampEpoch,
                                pageClassName: "")!
    }
}
#endif
