import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'model_manager.dart';
import 'npz_reader.dart';
import 'phonemizer.dart';
import 'text_cleaner.dart';
import 'text_preprocessor.dart';

/// Voice names available in KittenTTS
const List<String> kittenVoices = [
  'Bella',
  'Jasper',
  'Luna',
  'Bruno',
  'Rosie',
  'Hugo',
  'Kiki',
  'Leo',
];

/// Map of voice names to their embedding keys.
const Map<String, String> _voiceToEmbeddingKey = {
  'Bella': 'expr-voice-2-f',
  'Jasper': 'expr-voice-2-m',
  'Luna': 'expr-voice-3-f',
  'Bruno': 'expr-voice-3-m',
  'Rosie': 'expr-voice-4-f',
  'Hugo': 'expr-voice-4-m',
  'Kiki': 'expr-voice-5-f',
  'Leo': 'expr-voice-5-m',
};

const Map<String, double> _speedPriors = {
  'expr-voice-2-f': 0.8,
  'expr-voice-2-m': 0.8,
  'expr-voice-3-m': 0.8,
  'expr-voice-3-f': 0.8,
  'expr-voice-4-m': 0.9,
  'expr-voice-4-f': 0.8,
  'expr-voice-5-m': 0.8,
  'expr-voice-5-f': 0.8,
};

/// KittenTTS - High-quality offline text-to-speech for Flutter.
///
/// Uses the KittenML v0.8 ONNX model with espeak-ng phonemization.
/// Generated audio is PCM Float32 at 24 kHz.
///
/// ```dart
/// final tts = KittenTTS(variant: KittenModelVariant.mini);
/// await tts.initialize();
/// final audio = await tts.generate('Hello world', voice: 'Jasper');
/// // audio is Float32List PCM at 24 000 Hz
/// ```
class KittenTTS {
  final ModelManager _modelManager;

  KittenTTS({KittenModelVariant variant = KittenModelVariant.nano})
    : _modelManager = ModelManager(variant: variant);

  /// Creates a [KittenTTS] instance from a model name string.
  ///
  /// [model] is case-insensitive and must be one of `'nano'`, `'micro'`, or `'mini'`.
  /// Useful when the model name is stored as a string in config or preferences.
  KittenTTS.fromName(String model)
    : _modelManager = ModelManager(variant: KittenModelVariant.fromName(model));
  final Phonemizer _phonemizer = Phonemizer();
  final TextPreprocessor _preprocessor = TextPreprocessor();
  final TextCleaner _cleaner = TextCleaner();

  OrtSession? _session;
  NpzReader? _voices;
  bool _initialized = false;

  bool get isInitialized => _initialized;

  /// Output sample rate (always 24 000 Hz).
  int get sampleRate => 24000;

  /// Names of available voices.
  List<String> get availableVoices => List.unmodifiable(kittenVoices);

  /// Initialize the TTS engine.
  ///
  /// Downloads model files (~35 MB total) on first run and caches them.
  /// [onProgress] reports `(0.0–1.0, status message)`.
  /// [intraOpNumThreads] limits the number of threads ONNX Runtime uses for
  /// inference within a single operator (e.g. matrix multiply). Defaults to
  /// all available cores when `null`. Set to 2 on mobile to leave CPU headroom
  /// for the UI thread.
  Future<void> initialize({
    void Function(double progress, String status)? onProgress,
    int? intraOpNumThreads,
  }) async {
    if (_initialized) return;

    onProgress?.call(0.0, 'Preparing TTS engine...');

    // 1. Download model + voices + espeak data
    await _modelManager.download(onProgress: onProgress);

    // 2. Initialize espeak-ng phonemizer
    onProgress?.call(0.95, 'Initializing phonemizer...');
    _phonemizer.initialize(_modelManager.modelDir);

    // 3. Load ONNX session
    onProgress?.call(0.97, 'Loading ONNX model...');
    final ort = OnnxRuntime();
    // Select execution providers based on platform for hardware acceleration.
    // CoreML delegates to the Apple Neural Engine / GPU on iOS & macOS.
    // NNAPI delegates to the NPU/GPU on Android.
    // CPU is always appended as fallback for unsupported ops.
    List<OrtProvider> providers;
    if (!kIsWeb && (Platform.isIOS || Platform.isMacOS)) {
      providers = [OrtProvider.CORE_ML, OrtProvider.CPU];
    } else if (!kIsWeb && Platform.isAndroid) {
      providers = [OrtProvider.NNAPI, OrtProvider.CPU];
    } else {
      providers = [OrtProvider.CPU];
    }
    final sessionOptions = OrtSessionOptions(
      intraOpNumThreads: intraOpNumThreads,
      providers: providers,
    );
    try {
      _session = await ort.createSession(
        _modelManager.modelPath,
        options: sessionOptions,
      );
    } catch (e) {
      // Hardware accelerator failed (e.g. CoreML/NNAPI incompatible with model).
      // Retry with CPU-only.
      debugPrint(
        '[KittenTTS] Hardware accelerated session not supported or failed, fallback with CPU only.',
      );
      final cpuOptions = OrtSessionOptions(
        intraOpNumThreads: intraOpNumThreads,
      );
      _session = await ort.createSession(
        _modelManager.modelPath,
        options: cpuOptions,
      );
    }

    // 4. Load voice embeddings
    _voices = NpzReader.fromFile(_modelManager.voicesPath);
    debugPrint('[KittenTTS] voices keys: ${_voices!.keys}');

    _initialized = true;
    onProgress?.call(1.0, 'Ready');
  }

  // ──────────────────────────────────────────────────────────────────
  // Public API
  // ──────────────────────────────────────────────────────────────────

  /// Generate speech audio from [text].
  ///
  /// Returns PCM Float32 samples at [sampleRate] Hz.
  /// Long texts are automatically chunked at sentence boundaries.
  Future<Float32List> generate(
    String text, {
    String voice = 'Jasper',
    double speed = 1.0,
  }) async {
    _assertReady();

    final chunks = _splitIntoChunks(text);
    final parts = <Float32List>[];

    for (final chunk in chunks) {
      final audio = await _generateChunk(chunk, voice: voice, speed: speed);
      if (audio.isNotEmpty) parts.add(audio);
    }

    if (parts.isEmpty) return Float32List(0);
    if (parts.length == 1) return parts.first;

    final total = parts.fold<int>(0, (s, a) => s + a.length);
    final out = Float32List(total);
    var off = 0;
    for (final p in parts) {
      out.setAll(off, p);
      off += p.length;
    }
    return out;
  }

  /// Generate speech for a single short chunk (≤ 400 chars).
  ///
  /// Useful for streaming / pre-buffering individual pieces.
  Future<Float32List> generateChunk(
    String text, {
    String voice = 'Jasper',
    double speed = 1.0,
  }) {
    _assertReady();
    return _generateChunk(text, voice: voice, speed: speed);
  }

  /// Split [text] into sentence-aligned chunks suitable for [generateChunk].
  List<String> splitText(String text, {int maxLen = 200}) =>
      _splitIntoChunks(text, maxLen: maxLen);

  /// Release native resources. The instance cannot be used afterwards.
  Future<void> dispose() async {
    _phonemizer.dispose();
    await _session?.close();
    _session = null;
    _initialized = false;
  }

  // ──────────────────────────────────────────────────────────────────
  // Internal
  // ──────────────────────────────────────────────────────────────────

  static const int _maxTokens = 500;

  Future<Float32List> _generateChunk(
    String text, {
    required String voice,
    required double speed,
  }) async {
    // ── Text cleaning ──
    final clean = _preprocessor.process(text);
    final withPunct = _addTrailingPunctuation(clean);
    debugPrint('[KittenTTS] cleaned: "${_trunc(withPunct)}"');

    // ── Phonemization ──
    final phonemes = _phonemizer.phonemize(withPunct);
    debugPrint('[KittenTTS] phonemes: "${_trunc(phonemes)}"');

    // ── Token mapping ──
    final tokens = _cleaner.encodeWithBoundary(phonemes);
    debugPrint('[KittenTTS] tokens: ${tokens.length}');

    // ── Guard: split if tokens exceed model capacity ──
    if (tokens.length > _maxTokens) {
      debugPrint(
        '[KittenTTS] Token count ${tokens.length} exceeds $_maxTokens, '
        'splitting chunk further',
      );
      final mid = text.length ~/ 2;
      int splitAt = text.indexOf(RegExp(r'[.!?,;:\s]'), mid);
      if (splitAt < 0 || splitAt == text.length - 1) splitAt = mid;
      final firstHalf = text.substring(0, splitAt).trim();
      final secondHalf = text.substring(splitAt).trim();

      final parts = <Float32List>[];
      if (firstHalf.isNotEmpty) {
        parts.add(await _generateChunk(firstHalf, voice: voice, speed: speed));
      }
      if (secondHalf.isNotEmpty) {
        parts.add(await _generateChunk(secondHalf, voice: voice, speed: speed));
      }
      if (parts.isEmpty) return Float32List(0);
      if (parts.length == 1) return parts.first;

      final total = parts.fold<int>(0, (s, a) => s + a.length);
      final out = Float32List(total);
      var off = 0;
      for (final p in parts) {
        out.setAll(off, p);
        off += p.length;
      }
      return out;
    }

    // ── Voice embedding ──
    final embKey = _voiceToEmbeddingKey[voice] ?? 'expr-voice-2-m';
    final embArray = _voices![embKey];
    if (embArray == null) {
      throw StateError(
        'Voice "$voice" ($embKey) not found in voices.npz. '
        'Available: ${_voices!.keys}',
      );
    }
    final refIdx = text.length.clamp(0, embArray.length - 1);
    final style = embArray.row(refIdx);

    final prior = _speedPriors[embKey] ?? 1.0;
    final effectiveSpeed = speed * prior;

    // ── ONNX inference ──
    final inputIds = await OrtValue.fromList(Int64List.fromList(tokens), [
      1,
      tokens.length,
    ]);
    final styleTensor = await OrtValue.fromList(style.toList(), [
      1,
      style.length,
    ]);
    final speedTensor = await OrtValue.fromList([effectiveSpeed], [1]);

    final outputs = await _session!.run({
      'input_ids': inputIds,
      'style': styleTensor,
      'speed': speedTensor,
    });

    // Dispose inputs
    await inputIds.dispose();
    await styleTensor.dispose();
    await speedTensor.dispose();

    // Find the audio output tensor (largest)
    OrtValue? audioOut;
    int audioLen = 0;
    for (final entry in outputs.entries) {
      final len = entry.value.shape.fold<int>(1, (a, b) => a * b);
      if (len > audioLen) {
        audioLen = len;
        audioOut = entry.value;
      }
    }

    if (audioOut == null) return Float32List(0);

    final rawList = await audioOut.asFlattenedList();

    // Dispose all output tensors
    for (final v in outputs.values) {
      await v.dispose();
    }

    Float32List audio;
    if (rawList is List<double>) {
      audio = Float32List.fromList(rawList.cast<double>());
    } else {
      audio = Float32List.fromList(
        rawList.map((e) => (e as num).toDouble()).toList(),
      );
    }

    // Trim trailing silence (matches Python implementation)
    if (audio.length > 5000) {
      audio = Float32List.sublistView(audio, 0, audio.length - 5000);
    }

    debugPrint(
      '[KittenTTS] generated ${audio.length} samples '
      '(${(audio.length / sampleRate).toStringAsFixed(1)}s)',
    );
    return audio;
  }

  // ── Helpers ──

  List<String> _splitIntoChunks(String text, {int maxLen = 200}) {
    final sentences = text.split(RegExp(r'(?<=[.!?])\s+'));
    final chunks = <String>[];
    final buf = StringBuffer();

    for (final s in sentences) {
      final trimmed = s.trim();
      if (trimmed.isEmpty) continue;
      if (buf.length + trimmed.length + 1 > maxLen && buf.isNotEmpty) {
        chunks.add(_addTrailingPunctuation(buf.toString().trim()));
        buf.clear();
      }
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(trimmed);
    }
    if (buf.isNotEmpty) {
      chunks.add(_addTrailingPunctuation(buf.toString().trim()));
    }
    return chunks.isEmpty ? [_addTrailingPunctuation(text.trim())] : chunks;
  }

  static String _addTrailingPunctuation(String t) {
    t = t.trim();
    if (t.isEmpty) return t;
    return '.!?,;:'.contains(t[t.length - 1]) ? t : '$t,';
  }

  static String _trunc(String s, [int n = 60]) =>
      s.length <= n ? s : '${s.substring(0, n)}…';

  void _assertReady() {
    if (!_initialized) {
      throw StateError('KittenTTS not initialized. Call initialize() first.');
    }
  }
}
