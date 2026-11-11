require 'digest'
require 'fileutils'
require 'tmpdir'

# Local path pods do not run prepare_command. Install the pinned SDK while the
# podspec is evaluated, before CocoaPods resolves vendored frameworks.
framework = File.join(__dir__, 'Frameworks', 'NodeMobile.xcframework')
unless File.directory?(framework)
  Dir.mktmpdir('lume-node') do |dir|
    archive = File.join(dir, 'node.zip')
    url = 'https://github.com/digidem/nodejs-mobile/releases/download/v24.20.0-0/nodejs-mobile-ios-lite-24.20.0-0.zip'
    raise 'Node SDK download failed' unless system('curl', '-fL', '--retry', '3', '-o', archive, url)
    expected = '991283d8579eee225142da2bf4a897dd7d831e8b5a496a1f247fca665bc1d705'
    raise 'Node SDK SHA256 mismatch' unless Digest::SHA256.file(archive).hexdigest == expected
    raise 'Node SDK unzip failed' unless system('unzip', '-q', archive, '-d', dir)
    source = Dir.glob(File.join(dir, '**', 'NodeMobile.xcframework')).first
    raise 'Node SDK framework missing' unless source
    FileUtils.mkdir_p(File.dirname(framework))
    FileUtils.cp_r(source, framework)
  end
end

Pod::Spec.new do |s|
  s.name = 'lume_cat_node'
  s.version = '1.0.0'
  s.summary = 'LumeBox CatPaw Node host'
  s.homepage = 'https://github.com/teng662858/LumeBox'
  s.license = { :type => 'MIT' }
  s.author = { 'LumeBox' => 'LumeBox' }
  s.source = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.vendored_frameworks = 'Frameworks/NodeMobile.xcframework'
  s.dependency 'Flutter'
  s.platform = :ios, '18.0'
  s.frameworks = 'Security'
  s.static_framework = true
  # Keep the pinned XCFramework's headers visible while CocoaPods prepares its
  # intermediate slice. The SDK ships separate device and arm64 simulator slices.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*]' => '$(inherited) "$(PODS_TARGET_SRCROOT)/Frameworks/NodeMobile.xcframework/ios-arm64"',
    'FRAMEWORK_SEARCH_PATHS[sdk=iphonesimulator*]' => '$(inherited) "$(PODS_TARGET_SRCROOT)/Frameworks/NodeMobile.xcframework/ios-arm64-simulator"',
  }
end
