Pod::Spec.new do |s|
  s.name             = 'BlindWatermarkCore'
  s.version          = '1.0.0'
  s.summary          = '盲水印编解码核心（跨平台，无 UI 依赖）'
  s.description      = <<-DESC
    覆盖 App 全部界面的低幅度色度扰动层，肉眼不可见，截图必然被带上。
    每两个相邻的 8x8 像素块成对差分编码 1 bit，解码只看差值的符号与显著度（z 值），
    与底色无关，抗 JPEG。载荷 256 bit：uid + Unix 秒 + 页面短码 + 96 bit HMAC。
    含页面短码编解码、载荷布局与 MAC 校验，无 UI 依赖，macOS 上也能跑。
  DESC
  s.homepage         = 'https://github.com/zylcold/BlindWatermark'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'lovelink' => 'dev@example.com' }
  s.source           = { :git => 'https://github.com/zylcold/BlindWatermark.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  s.source_files = 'Sources/BlindWatermarkCore/**/*.swift'

  s.frameworks = 'CoreGraphics'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
