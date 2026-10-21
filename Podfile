platform :ios, '16.0'

target 'Fire' do
  use_frameworks!
  # VLC plays everything the provider sends (mkv, ts, hevc, embedded subtitles); Apple's player does not.
  pod 'MobileVLCKit', '~> 3.6'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      c.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    end
  end
end
