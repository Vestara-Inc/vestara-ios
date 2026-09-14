Pod::Spec.new do |s|
  s.name             = 'VestaraSDK'
  s.version          = '0.1.5'
  s.summary          = 'Native iOS SDK for Vestara crash reporting, remote logging, and mobile RUM.'
  s.description      = <<-DESC
                       Vestara iOS SDK is a lightweight, zero-dependency Swift SDK for crash reporting,
                       remote device logging, and Real User Monitoring (RUM).
                       DESC
  s.homepage         = 'https://www.vestara.dev'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'Ahsan Iqbal' => 'ahsan@vestara.dev' }
  s.source           = { :git => 'https://github.com/Vestara-Inc/vestara-ios.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '14.0'
  s.swift_version    = '5.9'

  s.module_name      = 'VestaraSDK'
  s.source_files     = 'Sources/sdk-ios/**/*.swift', 'Sources/VestaraCSignalState/**/*.{h,c}'
  s.private_header_files = 'Sources/VestaraCSignalState/include/*.h'
  s.preserve_paths   = 'Sources/VestaraCSignalState/include/module.modulemap'
  s.pod_target_xcconfig = {
    'SWIFT_INCLUDE_PATHS' => '$(inherited) "${PODS_TARGET_SRCROOT}/Sources/VestaraCSignalState/include"'
  }

  s.frameworks       = 'Foundation', 'Network'
  s.ios.framework    = 'UIKit'
end
