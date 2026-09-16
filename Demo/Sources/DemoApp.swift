import SwiftUI
import BlindWatermark

/// 模拟器冒烟用的最小宿主。
/// 只做两件事：装一个已知 payload 的水印；铺一张内容混合的界面
/// （浅色渐变 + 文字 + 深色卡片），用来验证解码在真实版式上还成不成立。
@main
struct DemoApp: App {
    init() {
        // 便于在模拟器上扫参数：SIMCTL_CHILD_BW_DELTA=6 xcrun simctl launch ...
        let env = ProcessInfo.processInfo.environment
        let payload = env["BW_PAYLOAD"].flatMap { UInt32($0, radix: 16) } ?? 0xDEAD_BEEF
        if let delta = env["BW_DELTA"].flatMap({ UInt8($0) }) {
            Watermark.install(payload: payload, delta: delta)
        } else {
            Watermark.install(payload: payload)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    private let rows = (1...8).map { "第 \($0) 条会话内容，用来制造文字边缘和对比度" }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.97), Color(white: 0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 16) {
                Text("盲水印冒烟页")
                    .font(.largeTitle.bold())

                Text("payload = 0xDEADBEEF")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(white: 0.08))
                    .frame(height: 120)
                    .overlay(
                        Text("深色卡片：验证黑底区域")
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(rows, id: \.self) { row in
                        Text(row)
                            .font(.subheadline)
                    }
                }
                .padding()
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                Spacer()
            }
            .padding(24)
        }
    }
}
