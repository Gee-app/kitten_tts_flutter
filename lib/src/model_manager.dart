import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// KittenTTS v0.8 model size variants.
enum KittenModelVariant {
  /// nano int8 — ~25 MB, 15M params
  nano,

  /// nano fp32 — ~56 MB, 15M params, full precision
  nanoFp32,

  /// micro — ~40 MB, improved quality over nano
  micro,

  /// mini — ~78 MB, highest quality, 248K downloads
  mini;

  /// Parses a case-insensitive model name string into a [KittenModelVariant].
  ///
  /// Accepts `'nano'`, `'nano_fp32'`, `'micro'`, or `'mini'`.
  /// Throws [ArgumentError] for unrecognised values.
  static KittenModelVariant fromName(String name) {
    switch (name.toLowerCase().trim()) {
      case 'nano':
        return KittenModelVariant.nano;
      case 'nano_fp32':
        return KittenModelVariant.nanoFp32;
      case 'micro':
        return KittenModelVariant.micro;
      case 'mini':
        return KittenModelVariant.mini;
      default:
        throw ArgumentError.value(
          name,
          'name',
          'Unknown KittenModelVariant. Use nano, nano_fp32, micro, or mini.',
        );
    }
  }
}

extension _KittenModelVariantInfo on KittenModelVariant {
  String get hfRepo {
    switch (this) {
      case KittenModelVariant.nano:
        return 'KittenML/kitten-tts-nano-0.8-int8';
      case KittenModelVariant.nanoFp32:
        return 'KittenML/kitten-tts-nano-0.8-fp32';
      case KittenModelVariant.micro:
        return 'KittenML/kitten-tts-micro-0.8';
      case KittenModelVariant.mini:
        return 'KittenML/kitten-tts-mini-0.8';
    }
  }

  String get onnxFileName {
    switch (this) {
      case KittenModelVariant.nano:
        return 'kitten_tts_nano_v0_8.onnx';
      case KittenModelVariant.nanoFp32:
        return 'kitten_tts_nano_v0_8.onnx';
      case KittenModelVariant.micro:
        return 'kitten_tts_micro_v0_8.onnx';
      case KittenModelVariant.mini:
        return 'kitten_tts_mini_v0_8.onnx';
    }
  }

  String get dirName => hfRepo.split('/').last;

  String get hfBase => 'https://huggingface.co/$hfRepo/resolve/main';
}

/// Downloads and manages KittenTTS model files from HuggingFace.
class ModelManager {
  static const _readyMarker = '.ready';

  final KittenModelVariant variant;

  ModelManager({this.variant = KittenModelVariant.nano});

  String? _modelDir;

  String get modelDir => _modelDir ?? '';
  String get modelPath => p.join(modelDir, variant.onnxFileName);
  String get voicesPath => p.join(modelDir, 'voices.npz');
  String get espeakDataPath => p.join(modelDir, 'espeak-ng-data');

  Future<bool> isReady() async {
    final dir = await _getModelDir();
    return File(p.join(dir.path, _readyMarker)).existsSync();
  }

  Future<void> download({
    void Function(double progress, String status)? onProgress,
  }) async {
    final dir = await _getModelDir();
    _modelDir = dir.path;

    final marker = File(p.join(dir.path, _readyMarker));
    if (marker.existsSync()) {
      debugPrint('[ModelManager] Already downloaded at ${dir.path}');
      onProgress?.call(1.0, 'Ready');
      return;
    }

    // Download model ONNX file
    await _downloadIfMissing(
      fileName: variant.onnxFileName,
      url: '${variant.hfBase}/${variant.onnxFileName}',
      dir: dir.path,
      progressBase: 0.0,
      progressRange: 0.5,
      onProgress: onProgress,
    );

    // Download voices NPZ file
    await _downloadIfMissing(
      fileName: 'voices.npz',
      url: '${variant.hfBase}/voices.npz',
      dir: dir.path,
      progressBase: 0.5,
      progressRange: 0.15,
      onProgress: onProgress,
    );

    // Download and extract espeak-ng data (~7 MB)
    await _ensureEspeakData(dir.path, onProgress);

    await marker.create();
    onProgress?.call(1.0, 'Ready');
    debugPrint('[ModelManager] All files ready at ${dir.path}');
  }

  Future<void> _downloadIfMissing({
    required String fileName,
    required String url,
    required String dir,
    required double progressBase,
    required double progressRange,
    void Function(double, String)? onProgress,
  }) async {
    final filePath = p.join(dir, fileName);
    if (File(filePath).existsSync()) {
      debugPrint('[ModelManager] $fileName already exists');
      return;
    }

    onProgress?.call(progressBase, 'Downloading $fileName...');
    debugPrint('[ModelManager] Downloading $url');

    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url))
        ..followRedirects = true
        ..maxRedirects = 5;
      final response = await client.send(request);
      if (response.statusCode != 200) {
        throw Exception(
          'Download $fileName failed: HTTP ${response.statusCode}',
        );
      }

      final total = response.contentLength ?? 0;
      final file = File(filePath);
      final sink = file.openWrite();
      var received = 0;

      await for (final chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        if (total > 0) {
          final fileProgress = received / total;
          final overall = progressBase + fileProgress * progressRange;
          onProgress?.call(
            overall,
            'Downloading $fileName... ${(fileProgress * 100).toStringAsFixed(0)}%',
          );
        }
      }
      await sink.close();
    } finally {
      client.close();
    }
  }

  Future<void> _ensureEspeakData(
    String baseDir,
    void Function(double, String)? onProgress,
  ) async {
    final espeakDir = Directory(p.join(baseDir, 'espeak-ng-data'));
    if (espeakDir.existsSync() && espeakDir.listSync().isNotEmpty) {
      debugPrint('[ModelManager] espeak-ng-data already exists');
      return;
    }

    onProgress?.call(0.7, 'Downloading espeak-ng data...');
    const espeakUrl =
        'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/espeak-ng-data.tar.bz2';

    final client = http.Client();
    Uint8List archiveBytes;
    try {
      final request = http.Request('GET', Uri.parse(espeakUrl))
        ..followRedirects = true
        ..maxRedirects = 5;
      final response = await client.send(request);
      final chunks = <int>[];
      final total = response.contentLength ?? 0;
      var received = 0;
      await for (final chunk in response.stream) {
        chunks.addAll(chunk);
        received += chunk.length;
        if (total > 0) {
          onProgress?.call(
            0.7 + (received / total) * 0.15,
            'Downloading espeak-ng data... ${(received / total * 100).toStringAsFixed(0)}%',
          );
        }
      }
      archiveBytes = Uint8List.fromList(chunks);
    } finally {
      client.close();
    }

    onProgress?.call(0.9, 'Extracting espeak-ng data...');
    await compute(_extractArchive, _ExtractParams(archiveBytes, baseDir));
    debugPrint('[ModelManager] espeak-ng-data extracted');
  }

  Future<Directory> _getModelDir() async {
    final appDir = await getApplicationSupportDirectory();
    final dir = Directory(p.join(appDir.path, 'kitten_tts', variant.dirName));
    if (!dir.existsSync()) await dir.create(recursive: true);
    _modelDir = dir.path;
    return dir;
  }
}

class _ExtractParams {
  final Uint8List data;
  final String targetDir;
  const _ExtractParams(this.data, this.targetDir);
}

Future<void> _extractArchive(_ExtractParams params) async {
  final decompressed = BZip2Decoder().decodeBytes(params.data);
  final archive = TarDecoder().decodeBytes(decompressed);

  for (final file in archive) {
    if (file.name.isEmpty) continue;
    final filePath = p.join(params.targetDir, file.name);
    if (file.isFile) {
      final outFile = File(filePath);
      await outFile.create(recursive: true);
      await outFile.writeAsBytes(file.content as List<int>);
    } else {
      await Directory(filePath).create(recursive: true);
    }
  }
}
