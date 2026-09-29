Pod::Spec.new do |s|
  s.name             = 'BlindWatermark'
  s.version          = '3.2.0'
  s.summary          = '常驻屏上低幅度盲水印，截图可解码溯源（设备 / 时间 / 页面）'
  s.description      = <<-DESC
    v6 离线截图水印：211 bit 字段通过 BCH(511,211,t40) 和整体偶校验编码，
    使用平滑色度载波、两份交织副本与独立同步列。CRC24 是完整性自检，不是验签。
    3.0.0 删除历史协议兼容，旧截图需要旧版本解码工具。无第三方运行时依赖。
  DESC
  s.homepage         = 'https://github.com/zylcold/BlindWatermark'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'lovelink' => 'dev@example.com' }
  s.source           = { :git => 'https://github.com/zylcold/BlindWatermark.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  # CocoaPods 下三个 target 拆成三个独立 podspec，模块名与 SPM 保持一致：
  #   BlindWatermarkCore    — 编解码核心
  #   BlindWatermarkAutoLoad — ObjC +load 自动挂载
  #   BlindWatermark        — Swift UI 层（本 podspec）
  # 本地联调：pod 'BlindWatermark', :path => '.'
  s.source_files = 'Sources/BlindWatermark/**/*.swift'

  s.dependency 'BlindWatermarkCore',     '~> 3.2.0'
  s.dependency 'BlindWatermarkAutoLoad', '~> 3.2.0'

  s.frameworks = 'UIKit', 'CoreGraphics'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
