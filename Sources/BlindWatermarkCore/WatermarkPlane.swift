import Foundation

public enum WatermarkPlane: String, CaseIterable {
    /// 亮度实验通道，需要独立的可见性验收。
    case luma
    /// 默认蓝黄对色通道；伴色只能减小亮度残差，不能保证不可见。
    case chroma
}
