Pod::Spec.new do |s|
  s.name             = 'flutter_kitten_tts'
  s.version          = '0.0.4'
  s.summary          = 'KittenTTS v0.8 - Offline text-to-speech for Flutter.'
  s.description      = <<-DESC
High-quality offline text-to-speech using the KittenML v0.8 ONNX model with espeak-ng phonemization.
                       DESC
  s.homepage         = 'https://github.com/ikeoffiah/kitten_tts_flutter'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'KittenTTS' => 'dev@example.com' }
  s.source           = { :path => '.' }

  espeak_dir = 'kitten_tts_flutter/Sources/espeak_ng'

  s.source_files = [
    'kitten_tts_flutter/Sources/kitten_tts_flutter/**/*.swift',
    "#{espeak_dir}/**/*.c",
    "#{espeak_dir}/**/*.h",
  ]

  # Only expose the bridge header to avoid duplicate header conflicts
  s.public_header_files = ["#{espeak_dir}/include/espeak_bridge.h"]

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'HEADER_SEARCH_PATHS' => [
      "$(PODS_TARGET_SRCROOT)/#{espeak_dir}/include",
      "$(PODS_TARGET_SRCROOT)/#{espeak_dir}/include/espeak-ng",
      "$(PODS_TARGET_SRCROOT)/#{espeak_dir}",
      "$(PODS_TARGET_SRCROOT)/#{espeak_dir}/ucd-include",
      "$(PODS_TARGET_SRCROOT)/#{espeak_dir}/include/ucd",
    ].join(' '),
    'GCC_PREPROCESSOR_DEFINITIONS' => [
      'HAVE_STDINT_H=1',
      'HAVE_MKSTEMP=1',
      'USE_ASYNC=0',
      'USE_KLATT=1',
      'USE_LIBPCAUDIO=0',
      'USE_LIBSONIC=0',
      'USE_MBROLA=0',
      'USE_SPEECHPLAYER=0',
      'PACKAGE_VERSION=\"1.52.0\"',
    ].join(' '),
    'OTHER_CFLAGS' => "-w -include $(PODS_TARGET_SRCROOT)/#{espeak_dir}/config.h",
  }

  s.dependency 'Flutter'
  s.platform = :ios, '16.0'
  s.swift_version = '5.0'

  # ── espeak-ng FFI symbol visibility ──────────────────────────────────────────
  #
  # The Dart side uses DynamicLibrary.process() → dlsym(RTLD_DEFAULT, ...) to
  # find espeak_* C symbols at runtime.  Two problems arise when this plugin is
  # consumed as a static framework (use_frameworks! :linkage => :static):
  #
  # 1. Dead code elimination at link time: the linker only pulls .o files from a
  #    static archive when they resolve an *undefined* symbol.  Since no
  #    Swift/ObjC code calls espeak_*, those objects are silently dropped.
  #    Fix: -Wl,-u,_espeak_<sym> marks each symbol as a required undefined,
  #    forcing the linker to include the corresponding object from the archive.
  #
  # 2. Strip phase: after linking, Xcode's strip tool removes symbols from the
  #    final binary.  With the default STRIP_STYLE=all, even globally-visible
  #    C symbols can be removed, making dlsym fail at runtime.
  #    Fix: host app sets STRIP_STYLE=non-global in Release/Profile so the
  #    strip tool preserves all external-linkage (global) C symbols.
  #    (See the Podfile example in the plugin README.)
  #
  # NOTE: We intentionally do NOT use -Wl,-exported_symbol here.  That flag
  # switches Apple's linker into explicit-export mode which, in Flutter Debug
  # builds, hides the Dart entry-point symbols and causes SIGABRT on launch.
  # STRIP_STYLE=non-global achieves the same result without that side-effect.
  s.user_target_xcconfig = {
    'OTHER_LDFLAGS' => [
      # Force-link the espeak objects from the static archive (stage 1 fix).
      # Stage 2 (strip) is handled by STRIP_STYLE=non-global in the host Podfile.
      '-Wl,-u,_espeak_Initialize',
      '-Wl,-u,_espeak_SetVoiceByName',
      '-Wl,-u,_espeak_TextToPhonemes',
      '-Wl,-u,_espeak_Terminate',
      '-Wl,-u,_espeak_Info',
    ].join(' '),
  }
end
