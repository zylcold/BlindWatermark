Pod::Spec.new do |s|
  s.name             = 'BlindWatermark'
  s.version          = '0.1.0'
  s.summary          = '常驻屏上不可见盲水印，截图可解码溯源（设备 / 时间 / 页面）'
  s.description      = <<-DESC
    覆盖 App 全部界面的低幅度色度扰动层，肉眼不可见，截图必然被带上。
    每两个相邻的 8x8 像素块成对差分编码 1 bit，解码只看差值的符号与显著度（z 值），
    与底色无关，抗 JPEG。载荷 256 bit：uid + Unix 秒 + 页面短码 + 96 bit HMAC。
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

  s.dependency 'BlindWatermarkCore',     '~> 0.1.0'
  s.dependency 'BlindWatermarkAutoLoad', '~> 0.1.0'

  s.frameworks = 'UIKit', 'CoreGraphics'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
