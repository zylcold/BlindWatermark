Pod::Spec.new do |s|
  s.name             = 'BlindWatermark'
  s.version          = '0.1.0'
  s.summary          = '常驻屏上不可见盲水印，截图可解码溯源'
  s.description      = <<-DESC
    覆盖 App 全部界面的低幅度亮度扰动层，肉眼不可见，截图必然被带上。
    每 16x16 像素块成对差分编码 1 bit，解码只看亮度差的符号，与底色无关，抗 JPEG。
  DESC
  s.homepage         = 'https://example.com/BlindWatermark'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'lovelink' => 'dev@example.com' }
  s.source           = { :git => 'https://example.com/BlindWatermark.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version         = '5.9'

  # 本地联调：pod 'BlindWatermark', :path => '/Users/zhuyunlong/DevSource/BlindWatermark'
  s.source_files = [
    'Sources/BlindWatermarkCore/**/*.swift',
    'Sources/BlindWatermark/**/*.swift',
    'Sources/BlindWatermarkAutoLoad/**/*.{h,m}',
  ]
  s.frameworks = 'UIKit', 'CoreGraphics'

  s.pod_target_xcconfig = {
    # 水印层与业务无耦合，但 ObjC 自动加载目标文件需要被链接进来
    'DEFINES_MODULE' => 'YES',
  }
end
