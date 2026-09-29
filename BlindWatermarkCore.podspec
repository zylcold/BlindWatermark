Pod::Spec.new do |s|
  s.name             = 'BlindWatermarkCore'
  s.version          = '3.1.0'
  s.summary          = '盲水印编解码核心（跨平台，无 UI 依赖）'
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

  s.source_files = 'Sources/BlindWatermarkCore/**/*.swift'

  s.frameworks = 'CoreGraphics'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
