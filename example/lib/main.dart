import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_kitten_tts/flutter_kitten_tts.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const KittenTTSDemo());
}

class KittenTTSDemo extends StatelessWidget {
  const KittenTTSDemo({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'KittenTTS Demo',
      theme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.deepPurple,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const TTSScreen(),
    );
  }
}

class TTSScreen extends StatefulWidget {
  const TTSScreen({super.key});

  @override
  State<TTSScreen> createState() => _TTSScreenState();
}

class _TTSScreenState extends State<TTSScreen> {
  final KittenTTS _tts = KittenTTS(variant: KittenModelVariant.mini);
  final TextEditingController _textCtrl = TextEditingController(
    text:
        'Hello! This is KittenTTS, a high-quality offline text-to-speech engine. '
        'It runs entirely on your device, no internet required.',
  );

  String _selectedVoice = 'Jasper';
  double _speed = 1.0;
  double _downloadProgress = 0;
  String _status = 'Not initialized';
  bool _isGenerating = false;
  Float32List? _lastAudio;

  @override
  void initState() {
    super.initState();
    _initTTS();
  }

  Future<void> _initTTS() async {
    try {
      await _tts.initialize(
        onProgress: (progress, status) {
          if (mounted) {
            setState(() {
              _downloadProgress = progress;
              _status = status;
            });
          }
        },
      );
      if (mounted) setState(() => _status = 'Ready');
    } catch (e) {
      if (mounted) setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _generate() async {
    if (!_tts.isInitialized || _isGenerating) return;

    setState(() {
      _isGenerating = true;
      _status = 'Generating...';
    });

    try {
      final audio = await _tts.generate(
        _textCtrl.text,
        voice: _selectedVoice,
        speed: _speed,
      );

      setState(() {
        _lastAudio = audio;
        _status =
            'Generated ${audio.length} samples '
            '(${(audio.length / _tts.sampleRate).toStringAsFixed(1)}s)';
        _isGenerating = false;
      });
    } catch (e) {
      setState(() {
        _status = 'Error: $e';
        _isGenerating = false;
      });
    }
  }

  Future<void> _saveWav() async {
    if (_lastAudio == null) return;

    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/kitten_tts_output.wav';

    final wavBytes = _encodeWav(_lastAudio!, _tts.sampleRate);
    await File(path).writeAsBytes(wavBytes);

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Saved to $path')));
    }
  }

  Uint8List _encodeWav(Float32List samples, int sampleRate) {
    final numChannels = 1;
    final bitsPerSample = 16;
    final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
    final blockAlign = numChannels * bitsPerSample ~/ 8;

    final pcm16 = Int16List(samples.length);
    for (var i = 0; i < samples.length; i++) {
      final s = (samples[i] * 32767).round().clamp(-32768, 32767);
      pcm16[i] = s;
    }

    final dataSize = pcm16.lengthInBytes;
    final fileSize = 36 + dataSize;
    final buffer = ByteData(44 + dataSize);

    void writeStr(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    buffer.setUint32(4, fileSize, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, numChannels, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, blockAlign, Endian.little);
    buffer.setUint16(34, bitsPerSample, Endian.little);
    writeStr(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    final pcmBytes = pcm16.buffer.asUint8List();
    for (var i = 0; i < pcmBytes.length; i++) {
      buffer.setUint8(44 + i, pcmBytes[i]);
    }

    return buffer.buffer.asUint8List();
  }

  @override
  void dispose() {
    _tts.dispose();
    _textCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('KittenTTS Demo'), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Status',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 8),
                    if (!_tts.isInitialized && _downloadProgress < 1.0) ...[
                      LinearProgressIndicator(value: _downloadProgress),
                      const SizedBox(height: 8),
                    ],
                    Text(
                      _status,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Text input
            TextField(
              controller: _textCtrl,
              maxLines: 5,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: 'Text to speak',
                hintText: 'Enter text here...',
              ),
            ),
            const SizedBox(height: 16),

            // Voice selector
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedVoice,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Voice',
                    ),
                    items: kittenVoices
                        .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                        .toList(),
                    onChanged: (v) {
                      if (v != null) setState(() => _selectedVoice = v);
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Speed: ${_speed.toStringAsFixed(1)}x'),
                      Slider(
                        value: _speed,
                        min: 0.5,
                        max: 2.0,
                        divisions: 6,
                        onChanged: (v) => setState(() => _speed = v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Generate button
            FilledButton.icon(
              onPressed: _tts.isInitialized && !_isGenerating
                  ? _generate
                  : null,
              icon: _isGenerating
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.record_voice_over),
              label: Text(_isGenerating ? 'Generating...' : 'Generate Speech'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),

            if (_lastAudio != null) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _saveWav,
                icon: const Icon(Icons.save),
                label: const Text('Save as WAV'),
              ),
              const SizedBox(height: 8),
              Text(
                '${_lastAudio!.length} samples / '
                '${(_lastAudio!.length / _tts.sampleRate).toStringAsFixed(1)}s / '
                '${_tts.sampleRate} Hz',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
