Pod::Spec.new do |s|
  s.name             = 'BlindWatermarkCore'
  s.version          = '0.1.0'
  s.summary          = '盲水印编解码核心（跨平台，无 UI 依赖）'
  s.description      = <<-DESC
    覆盖 App 全部界面的低幅度亮度扰动层核心编解码逻辑。
    每 16x16 像素块成对差分编码 1 bit，解码只看亮度差的符号，与底色无关，抗 JPEG。
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
