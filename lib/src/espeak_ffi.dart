import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show debugPrint;

typedef _EspeakInitializeC =
    Int32 Function(
      Int32 output,
      Int32 buflength,
      Pointer<Utf8> path,
      Int32 options,
    );
typedef _EspeakInitializeDart =
    int Function(int output, int buflength, Pointer<Utf8> path, int options);

typedef _EspeakSetVoiceByNameC = Int32 Function(Pointer<Utf8> name);
typedef _EspeakSetVoiceByNameDart = int Function(Pointer<Utf8> name);

typedef _EspeakTextToPhonemesC =
    Pointer<Utf8> Function(
      Pointer<Pointer<Void>> textptr,
      Int32 textmode,
      Int32 phonememode,
    );
typedef _EspeakTextToPhonemesDart =
    Pointer<Utf8> Function(
      Pointer<Pointer<Void>> textptr,
      int textmode,
      int phonememode,
    );

typedef _EspeakTerminateC = Int32 Function();
typedef _EspeakTerminateDart = int Function();

/// Low-level FFI wrapper around the espeak-ng C library.
///
/// On iOS/macOS, espeak-ng is statically linked via the plugin podspec,
/// so symbols are looked up from the process itself.
/// On Android/Linux, the shared library is loaded dynamically.
class EspeakFfi {
  DynamicLibrary? _lib;
  _EspeakInitializeDart? _initialize;
  _EspeakSetVoiceByNameDart? _setVoiceByName;
  _EspeakTextToPhonemesDart? _textToPhonemes;
  _EspeakTerminateDart? _terminate;

  bool _loaded = false;
  bool _ready = false;
  bool get isReady => _ready;

  void load() {
    if (_loaded) return;

    debugPrint('[EspeakFfi] load() — platform=${Platform.operatingSystem}');

    if (Platform.isIOS || Platform.isMacOS) {
      _lib = DynamicLibrary.process();
      debugPrint('[EspeakFfi] using DynamicLibrary.process() (static link)');
    } else if (Platform.isAndroid) {
      _lib = DynamicLibrary.open('libespeak-ng.so');
    } else if (Platform.isLinux) {
      _lib = DynamicLibrary.open('libespeak-ng.so.1');
    } else if (Platform.isWindows) {
      _lib = DynamicLibrary.open('espeak-ng.dll');
    } else {
      throw UnsupportedError(
        'espeak-ng not supported on ${Platform.operatingSystem}',
      );
    }

    // ── Probe every symbol individually so diagnostics show ALL missing ones.
    // On iOS/TestFlight the static library may have been stripped of espeak
    // symbols at link time. We want to know which specific symbols are absent.
    const symbols = [
      'espeak_Initialize',
      'espeak_SetVoiceByName',
      'espeak_TextToPhonemes',
      'espeak_Terminate',
      'espeak_Info',
    ];
    final missing = <String>[];
    for (final sym in symbols) {
      try {
        _lib!.lookup<NativeType>(sym);
        debugPrint('[EspeakFfi] ✅ symbol present: $sym');
      } catch (e) {
        debugPrint('[EspeakFfi] ❌ symbol MISSING: $sym — $e');
        missing.add(sym);
      }
    }
    if (missing.isNotEmpty) {
      throw StateError(
        'espeak-ng symbols not found in binary (static link missing). '
        'Missing: ${missing.join(', ')}. '
        'All probed: ${symbols.join(', ')}. '
        'This indicates the espeak-ng object files were stripped at link '
        'time (Release/TestFlight build without -Wl,-u linker flags). '
        'Fix: add -Wl,-u,_<symbol> to the plugin podspec user_target_xcconfig.',
      );
    }

    _initialize = _lib!
        .lookupFunction<_EspeakInitializeC, _EspeakInitializeDart>(
          'espeak_Initialize',
        );
    _setVoiceByName = _lib!
        .lookupFunction<_EspeakSetVoiceByNameC, _EspeakSetVoiceByNameDart>(
          'espeak_SetVoiceByName',
        );
    _textToPhonemes = _lib!
        .lookupFunction<_EspeakTextToPhonemesC, _EspeakTextToPhonemesDart>(
          'espeak_TextToPhonemes',
        );
    _terminate = _lib!.lookupFunction<_EspeakTerminateC, _EspeakTerminateDart>(
      'espeak_Terminate',
    );

    debugPrint('[EspeakFfi] all symbols loaded successfully');
    _loaded = true;
  }

  /// Initialize espeak-ng with the path to the directory containing
  /// the `espeak-ng-data` folder.
  void init(String dataPath) {
    final pathPtr = dataPath.toNativeUtf8();
    try {
      // AUDIO_OUTPUT_RETRIEVAL = 0x0002, DONT_EXIT = 0x8000
      final result = _initialize!(0x0002, 0, pathPtr, 0x8000);
      if (result == -1) {
        throw Exception('espeak_Initialize failed. Check data path: $dataPath');
      }

      final voicePtr = 'en-us'.toNativeUtf8();
      try {
        _setVoiceByName!(voicePtr);
      } finally {
        calloc.free(voicePtr);
      }

      _ready = true;
    } finally {
      calloc.free(pathPtr);
    }
  }

  String phonemize(String text) {
    if (!_ready) throw StateError('EspeakFfi not initialized');

    final textPtr = text.toNativeUtf8();
    final ptrToPtr = calloc<Pointer<Void>>();
    ptrToPtr.value = textPtr.cast<Void>();

    try {
      final buffer = StringBuffer();

      while (true) {
        // textmode = 1 (UTF-8), phonememode = 0x02 (IPA)
        final result = _textToPhonemes!(ptrToPtr, 1, 0x02);
        if (result == nullptr) break;
        final phoneme = result.toDartString();
        if (phoneme.isEmpty) break;
        buffer.write(phoneme);
        buffer.write(' ');
      }

      return buffer.toString().trim();
    } finally {
      calloc.free(ptrToPtr);
      calloc.free(textPtr);
    }
  }

  void dispose() {
    if (_ready) {
      _terminate?.call();
      _ready = false;
    }
  }
}
