import CryptoKit
import SwiftUI
import BlindWatermark
import BlindWatermarkCore

/// 模拟器冒烟用的最小宿主。
///
/// 只做两件事：装一个已知 payload 的水印；提供几种差异很大的页面，用来对比
/// 水印在不同内容密度、不同底色上的解码余量。
///
/// `xcrun simctl launch` 时用 `SIMCTL_CHILD_BW_PAGE=<名字>` 直接打开某一页，方便脚本逐页刷。
@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// 演示 256 bit 推荐布局：uid + Unix 秒 + 页面短码 + 标签 + mac。
/// 换页时用 `Watermark.update` 重画图案 —— 相位不变，解码端无感。
enum DemoWatermark {
    static let keyHex = "00112233445566778899aabbccddeeff"
    static let demoUID: UInt32 = 0xDEAD_BEEF
    static let demoTag: UInt32 = 1

    static func install(page: DemoPage) {
        let env = ProcessInfo.processInfo.environment
        let plane = env["BW_PLANE"].flatMap(WatermarkPlane.init(rawValue:)) ?? .chroma
        let payload = self.payload(page: page)
        if let delta = env["BW_DELTA"].flatMap({ UInt8($0) }) {
            Watermark.install(payload: payload, delta: delta, plane: plane)
        } else {
            Watermark.install(payload: payload, plane: plane)
        }
    }

    static func update(page: DemoPage) {
        Watermark.update(payload: payload(page: page))
    }

    private static func payload(page: DemoPage) -> [UInt8] {
        guard let key = SymmetricKey(hex: keyHex) else { fatalError("demo key 不合法") }
        return WatermarkPayload(
            uid: demoUID,
            timestamp: UInt32(max(0, min(Date().timeIntervalSince1970, Double(UInt32.max)))),
            pageClassName: page.className,
            app: demoTag,
            key: key
        ).bytes
    }
}

/// 页面种类。命名即 `BW_PAGE` 的取值。
enum DemoPage: String, CaseIterable, Identifiable {
    /// 近乎纯色的渐变：内容噪声最小，水印余量的上限
    case plain
    /// 纯白背景 + 少量文字：最常见的聊天页
    case white
    /// 文字密集列表：大量文字边缘
    case text
    /// 照片网格：高频细节 + 硬边缘，最接近相册/图片流
    case photo
    /// 深色底 + 深色卡片
    case dark
    /// 上白下黑混排 + 文字 + 一张照片
    case mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return "纯色"
        case .white: return "白底"
        case .text: return "文字"
        case .photo: return "照片"
        case .dark: return "深色"
        case .mixed: return "混排"
        }
    }

    var index: Int { DemoPage.allCases.firstIndex(of: self) ?? 0 }

    /// 模拟真实项目里的 VC 命名，用来演示短码压缩后还剩几个字符可用
    var className: String {
        switch self {
        case .plain: return "BHPlainViewController"
        case .white: return "BHWhiteChatViewController"
        case .text: return "BHTextListViewController"
        case .photo: return "BHPhotoGridViewController"
        case .dark: return "BHDarkModeViewController"
        case .mixed: return "BHMixedFeedViewController"
        }
    }
}

/// 页脚：把打进去的 uid / 页面短码亮出来，方便肉眼核对解码结果
struct PayloadFooter: View {
    let page: DemoPage

    var body: some View {
        Text("uid=0x\(String(format: "%08X", DemoWatermark.demoUID))  \(page.className) → \(PageNameCodec.code(for: page.className))  app=\(DemoWatermark.demoTag)")
            .font(.caption2.monospaced())
            .foregroundStyle(.secondary)
    }
}

struct RootView: View {
    @State private var selection: DemoPage

    init() {
        let requested = ProcessInfo.processInfo.environment["BW_PAGE"].flatMap(DemoPage.init(rawValue:))
        _selection = State(initialValue: requested ?? .plain)
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(DemoPage.allCases) { page in
                PageView(page: page)
                    .tabItem { Text(page.title) }
                    .tag(page)
            }
        }
        .onAppear {
            DemoWatermark.install(page: selection)
            selection = selection   // 触发一次 onChange，确保首屏也带页面短码
        }
        .onChange(of: selection) { page in
            DemoWatermark.update(page: page)
        }
    }
}

struct PageView: View {
    let page: DemoPage

    var body: some View {
        VStack(spacing: 0) {
            switch page {
            case .plain: PlainPage()
            case .white: WhitePage()
            case .text: TextPage()
            case .photo: PhotoPage()
            case .dark: DarkPage()
            case .mixed: MixedPage()
            }
            PayloadFooter(page: page)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - 页面

private struct PlainPage: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.97), Color(white: 0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            Text("纯色渐变页：内容噪声最小")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }
}

private struct WhitePage: View {
    private let messages = [
        "在吗？",
        "在的，你说",
        "周末那个活动还去吗",
        "去，几点集合",
    ]

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                    HStack {
                        if index % 2 == 1 { Spacer() }
                        Text(message)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(index % 2 == 0 ? Color(white: 0.93) : Color.green.opacity(0.28))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        if index % 2 == 0 { Spacer() }
                    }
                }
                Spacer()
            }
            .padding(20)
        }
    }
}

private struct TextPage: View {
    private let rows = (1...14).map { "第 \($0) 条会话内容，用来制造文字边缘和对比度" }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.97), Color(white: 0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                Text("盲水印冒烟页")
                    .font(.largeTitle.bold())
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.self) { row in
                        Text(row).font(.subheadline)
                    }
                }
                .padding()
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                Spacer()
            }
            .padding(20)
        }
    }
}

private struct PhotoPage: View {
    private let columns = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]

    var body: some View {
        ZStack {
            Color(white: 0.12).ignoresSafeArea()
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(0..<18, id: \.self) { index in
                        Image(uiImage: NoiseImage.shared)
                            .resizable()
                            .aspectRatio(1, contentMode: .fill)
                            .frame(height: 120)
                            .clipped()
                            .hueRotation(.degrees(Double(index) * 23))
                    }
                }
                .padding(4)
            }
        }
    }
}

private struct DarkPage: View {
    var body: some View {
        ZStack {
            Color(white: 0.06).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                Text("深色页")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.16))
                    .frame(height: 160)
                    .overlay(Text("深色卡片").foregroundStyle(.white))
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.28))
                    .frame(height: 160)
                    .overlay(Text("浅一点的卡片").foregroundStyle(.white))
                Spacer()
            }
            .padding(24)
        }
    }
}

private struct MixedPage: View {
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Color.white
                Color(white: 0.07)
            }
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("上白下黑混排")
                    .font(.largeTitle.bold())
                Text("上半部分文字压在纯白上，下半部分是深色照片区。")
                    .font(.subheadline)
                Image(uiImage: NoiseImage.shared)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 320)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Spacer()
            }
            .padding(24)
        }
    }
}
