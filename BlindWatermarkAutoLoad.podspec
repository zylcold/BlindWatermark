Pod::Spec.new do |s|
  s.name             = 'BlindWatermarkAutoLoad'
  s.version          = '2.0.0'
  s.summary          = '盲水印 ObjC +load 自动挂载层'
  s.description      = <<-DESC
    提供一个 ObjC +load 方法，宿主零代码挂载水印层。
    需配合 BlindWatermark 使用，使水印层在 App 启动时自动初始化。
  DESC
  s.homepage         = 'https://github.com/zylcold/BlindWatermark'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'lovelink' => 'dev@example.com' }
  s.source           = { :git => 'https://github.com/zylcold/BlindWatermark.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'

  s.source_files     = 'Sources/BlindWatermarkAutoLoad/**/*.{h,m}'
  s.public_header_files = 'Sources/BlindWatermarkAutoLoad/include/**/*.h'

  s.frameworks = 'Foundation'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
  }
end
