#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint rust_myadmin_core.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'rust_myadmin_core'
  s.version          = '0.0.1'
  s.summary          = 'A new Flutter FFI plugin project.'
  s.description      = <<-DESC
A new Flutter FFI plugin project.
                       DESC
  s.homepage         = 'http://example.com'
  # This plugin is built from this repository, not distributed as a pod, and no
  # LICENSE file is shipped next to it. Declaring the type avoids CocoaPods
  # warning about a missing '../LICENSE' reference.
  s.license          = { :type => 'Proprietary', :text => 'Copyright (c) 2026 rust_myadmin contributors' }
  s.author           = { 'Your Company' => 'email@example.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.11'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'

  s.script_phase = {
    :name => 'Build Rust library',
    # First argument is relative path to the `rust` folder, second is name of rust library
    :script => 'sh "$PODS_TARGET_SRCROOT/../cargokit/build_pod.sh" ../../rust rust_myadmin_core',
    :execution_position => :before_compile,
    :input_files => ['${BUILT_PRODUCTS_DIR}/cargokit_phony'],
    # Let XCode know that the static library referenced in -force_load below is
    # created by this build step.
    :output_files => ["${BUILT_PRODUCTS_DIR}/librust_myadmin_core.a"],
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # Flutter.framework does not contain a i386 slice.
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # The Rust static library is force-loaded wholesale. sqlx pulls in the
    # whoami crate, whose macOS backend calls SCDynamicStoreCopyComputerName,
    # so SystemConfiguration must be linked or the final link fails with
    # "Undefined symbols for architecture x86_64".
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/librust_myadmin_core.a -framework SystemConfiguration -framework CoreFoundation -framework Security',
  }

  # These frameworks must also be linked by the *consuming* Runner target,
  # because the force-loaded archive is resolved during that final link.
  # pod_target_xcconfig only affects the pod's own target, so user_target_xcconfig
  # is what actually reaches the app.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '-framework SystemConfiguration -framework CoreFoundation -framework Security',
  }
end