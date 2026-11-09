// 用已有本地模型回放指定的 16 千赫单声道音频，验证真实识别到稿件定位的链路。
// 不使用麦克风，不访问网络，不修改输入文件。
// 运行示例：dart run tool/verify_voice_follow.dart --runtime-dir <运行库目录>
//   --model-dir <中文模型目录> --audio <录音.wav> --script <稿件.txt>
// 可选 --anchor <原稿字符位置>；默认从开头开始。标准输出为逐行 JSON（结构化数据）。
// 合成语音只能用于链路冒烟；执行完成及最后位置均不等于真人准确率验收。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../lib/services/asr/alignment_engine.dart';
import '../lib/services/asr/asr_recognition_event.dart';
import '../lib/services/asr/asr_transcript_normalizer.dart';

const _sampleRate = 16000;
const _chunkSamples = 1600;
const _flushSamples = _sampleRate * 3;

Map<String, String> _options(List<String> arguments) {
  const names = {'runtime-dir', 'model-dir', 'audio', 'script', 'anchor'};
  final options = <String, String>{};
  for (var i = 0; i < arguments.length; i += 2) {
    final argument = arguments[i];
    if (!argument.startsWith('--') || i + 1 >= arguments.length) {
      throw const FormatException('参数格式应为 --参数名 参数值');
    }
    final name = argument.substring(2);
    if (!names.contains(name) || options.containsKey(name)) {
      throw FormatException('未知或重复参数：$argument');
    }
    options[name] = arguments[i + 1];
  }
  for (final required in ['runtime-dir', 'model-dir', 'audio', 'script']) {
    if (options[required]?.isNotEmpty != true) {
      throw FormatException('缺少参数：--$required');
    }
  }
  return options;
}

String _fileIn(String directory, String filename) =>
    '${Directory(directory).absolute.path}${Platform.pathSeparator}$filename';

void _emit(Map<String, Object?> event) => stdout.writeln(jsonEncode(event));

void _validateWaveHeader(File file) {
  // Check the format before native decoding, so channel mixing or resampling
  // cannot silently change the input used by this diagnostic.
  final handle = file.openSync();
  try {
    final header = handle.readSync(12);
    if (header.length != 12 ||
        ascii.decode(header.sublist(0, 4), allowInvalid: true) != 'RIFF' ||
        ascii.decode(header.sublist(8, 12), allowInvalid: true) != 'WAVE') {
      throw const FormatException('输入必须是标准波形音频文件');
    }
    while (handle.positionSync() + 8 <= handle.lengthSync()) {
      final chunk = handle.readSync(8);
      final name = ascii.decode(chunk.sublist(0, 4), allowInvalid: true);
      final size = ByteData.sublistView(chunk).getUint32(4, Endian.little);
      final payload = handle.positionSync();
      if (payload + size > handle.lengthSync()) {
        throw const FormatException('音频文件的数据块不完整');
      }
      if (name == 'fmt ') {
        if (size < 16) throw const FormatException('音频格式数据不完整');
        final format = ByteData.sublistView(handle.readSync(16));
        final channels = format.getUint16(2, Endian.little);
        final rate = format.getUint32(4, Endian.little);
        if (channels != 1 || rate != _sampleRate) {
          throw FormatException('音频必须是 16000 赫兹单声道；实际为 $rate 赫兹、$channels 声道');
        }
        return;
      }
      handle.setPositionSync(payload + size + (size.isOdd ? 1 : 0));
    }
    throw const FormatException('音频缺少格式信息');
  } finally {
    handle.closeSync();
  }
}

void main(List<String> arguments) {
  if (arguments.length == 1 && arguments.single == '--help') {
    stdout.writeln(
      '用法：dart run tool/verify_voice_follow.dart '
      '--runtime-dir <运行库目录> --model-dir <中文模型目录> '
      '--audio <16000赫兹单声道音频> --script <纯文本稿件> [--anchor <字符位置>]',
    );
    return;
  }

  sherpa.OnlineRecognizer? recognizer;
  sherpa.OnlineStream? stream;
  final total = Stopwatch()..start();
  try {
    final options = _options(arguments);
    final runtimeDirectory = options['runtime-dir']!;
    final modelDirectory = options['model-dir']!;
    if (!Directory(runtimeDirectory).existsSync() ||
        !Directory(modelDirectory).existsSync()) {
      throw const FileSystemException('运行库目录或模型目录不存在');
    }
    final audioFile = File(options['audio']!);
    final scriptFile = File(options['script']!);
    if (!audioFile.existsSync() || !scriptFile.existsSync()) {
      throw const FileSystemException('指定的音频或稿件文件不存在');
    }
    _validateWaveHeader(audioFile);
    final script = scriptFile.readAsStringSync().replaceFirst(
      RegExp(r'^\uFEFF'),
      '',
    );
    if (script.trim().isEmpty) throw const FormatException('稿件为空');
    final anchor = int.tryParse(options['anchor'] ?? '-1');
    if (anchor == null || anchor < -1 || anchor >= script.length) {
      throw const FormatException('起始字符位置超出稿件范围');
    }
    final manifestFile = File.fromUri(
      Platform.script.resolve('../assets/asr/zipformer2-ced.manifest.json'),
    );
    final manifest =
        jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
    final modelFiles = {
      for (final entry in manifest['files'] as List)
        (entry as Map<String, dynamic>)['role'] as String: _fileIn(
          modelDirectory,
          entry['name'] as String,
        ),
    };
    for (final role in ['encoder', 'decoder', 'joiner', 'tokens']) {
      final path = modelFiles[role];
      if (path == null || !File(path).existsSync()) {
        throw FileSystemException('缺少模型文件：$role', path);
      }
    }

    // The diagnostic runs beside the Dart executable rather than the app.
    // Load the supplied dependency first so a system DLL with the same name
    // cannot take precedence over the runtime being verified.
    if (Platform.isWindows) {
      DynamicLibrary.open(_fileIn(runtimeDirectory, 'onnxruntime.dll'));
    }
    sherpa.initBindings(runtimeDirectory);
    final wave = sherpa.readWave(audioFile.absolute.path);
    if (wave.sampleRate != _sampleRate || wave.samples.isEmpty) {
      throw const FormatException('音频解码结果为空或采样率不符');
    }
    final loaded = Stopwatch()..start();
    final activeRecognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          modelType: manifest['modelFamily'] as String,
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: modelFiles['encoder']!,
            decoder: modelFiles['decoder']!,
            joiner: modelFiles['joiner']!,
          ),
          tokens: modelFiles['tokens']!,
          numThreads: 2,
          debug: false,
        ),
        enableEndpoint: true,
        rule1MinTrailingSilence: 2.4,
        rule2MinTrailingSilence: 1.2,
        rule3MinUtteranceLength: 20,
      ),
    );
    recognizer = activeRecognizer;
    final activeStream = activeRecognizer.createStream();
    stream = activeStream;
    loaded.stop();
    final alignment = TeleprompterAlignment()
      ..setScript(script)
      ..setCurrentIndex(anchor);
    final sequence = AsrRecognitionSequencer()..reset(1);
    final decoding = Stopwatch()..start();
    var processed = 0;
    var currentIndex = anchor;
    var eventCount = 0;
    var moves = 0;
    var backwardMoves = 0;
    var waitingEvents = 0;
    var finalSegments = 0;
    var largestForwardMove = 0;

    void deliver(String text, bool isFinal) {
      final event = sequence.update(text, isFinal: isFinal);
      if (event == null) return;
      eventCount++;
      if (isFinal && event.text.isNotEmpty) finalSegments++;
      final result = alignment.consumeTranscript(
        normalizeAsrTranscript(event.text),
        event.isFinal,
      );
      final previous = currentIndex;
      if (result.index >= 0 &&
          (result.index >= currentIndex || result.meta.allowBackward)) {
        currentIndex = result.index;
      }
      final moved = previous != currentIndex;
      if (moved) {
        moves++;
        if (currentIndex < previous) backwardMoves++;
        largestForwardMove = math.max(
          largestForwardMove,
          currentIndex - previous,
        );
      }
      if (result.meta.isWaiting) waitingEvents++;
      _emit({
        'type': 'recognition',
        'audioSeconds': math.min(processed, wave.samples.length) / _sampleRate,
        'flushing': processed > wave.samples.length,
        'segmentId': event.segmentId,
        'revision': event.revision,
        'isFinal': event.isFinal,
        'text': event.text,
        'currentIndex': currentIndex,
        'strategy': result.meta.strategy,
        'matchedLength': result.meta.matchedLength,
        'waiting': result.meta.isWaiting,
        'moved': moved,
        'allowBackward': result.meta.allowBackward,
      });
    }

    void decode(Float32List samples) {
      processed += samples.length;
      activeStream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      while (activeRecognizer.isReady(activeStream)) {
        activeRecognizer.decode(activeStream);
      }
      final result = activeRecognizer.getResult(activeStream);
      final isFinal = activeRecognizer.isEndpoint(activeStream);
      deliver(result.text, isFinal);
      if (isFinal) activeRecognizer.reset(activeStream);
    }

    for (
      var offset = 0;
      offset < wave.samples.length;
      offset += _chunkSamples
    ) {
      decode(
        Float32List.sublistView(
          wave.samples,
          offset,
          math.min(offset + _chunkSamples, wave.samples.length),
        ),
      );
    }
    // Drain decoder look-ahead and the same endpoint detector used by the app.
    // This added silence is reported separately from the input audio duration.
    for (var offset = 0; offset < _flushSamples; offset += _chunkSamples) {
      decode(Float32List(_chunkSamples));
    }
    final remainder = activeRecognizer.getResult(activeStream).text;
    if (remainder.trim().isNotEmpty) deliver(remainder, true);
    decoding.stop();
    total.stop();
    _emit({
      'type': 'summary',
      'audioSeconds': wave.samples.length / _sampleRate,
      'flushSeconds': _flushSamples / _sampleRate,
      'modelLoadMs': loaded.elapsedMilliseconds,
      'recognitionMs': decoding.elapsedMilliseconds,
      'totalMs': total.elapsedMilliseconds,
      'realTimeFactor':
          decoding.elapsedMicroseconds /
          1000000 /
          (wave.samples.length / _sampleRate),
      'initialIndex': anchor,
      'finalIndex': currentIndex,
      'scriptCharacters': script.length,
      'events': eventCount,
      'moves': moves,
      'backwardMoves': backwardMoves,
      'largestForwardMove': largestForwardMove,
      'waitingEvents': waitingEvents,
      'finalSegments': finalSegments,
      'evaluation': '链路回放完成；不代表真人识别准确率验收',
    });
  } catch (error) {
    stderr.writeln('语音跟随回放失败：$error');
    exitCode = 1;
  } finally {
    try {
      stream?.free();
    } finally {
      recognizer?.free();
    }
  }
}
