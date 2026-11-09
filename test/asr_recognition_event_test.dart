import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/asr/asr_recognition_event.dart';

void main() {
  test('unchanged interim notifications do not become new speech', () {
    final source = AsrRecognitionSequencer()..reset(10);
    final first = source.update('今天开始学习', isFinal: false)!;
    expect(first.epoch, 10);
    expect(first.segmentId, 0);
    expect(first.revision, 1);
    for (var i = 0; i < 20; i++) {
      expect(source.update('今天开始学习', isFinal: false), isNull);
    }
    final revised = source.update('今天开始学习方法', isFinal: false)!;
    expect(revised.segmentId, 0);
    expect(revised.revision, 2);
  });

  test('final closes one utterance and an identical new utterance is kept', () {
    final source = AsrRecognitionSequencer()..reset(1);
    final partial = source.update('重要重要重要', isFinal: false)!;
    final finalEvent = source.update('重要重要重要', isFinal: true)!;
    final next = source.update('重要重要重要', isFinal: false)!;
    expect(finalEvent.segmentId, partial.segmentId);
    expect(finalEvent.revision, greaterThan(partial.revision));
    expect(next.segmentId, finalEvent.segmentId + 1);
    expect(next.text, '重要重要重要');
    expect(next.revision, 1);
  });

  test('cleared interim text is a revision, initial silence is not', () {
    final source = AsrRecognitionSequencer();
    expect(source.update('', isFinal: false), isNull);
    source.update('错误识别', isFinal: false);
    final cleared = source.update('', isFinal: false)!;
    expect(cleared.text, isEmpty);
    expect(cleared.revision, 2);
    final endpoint = source.update('', isFinal: true)!;
    expect(endpoint.isFinal, isTrue);
    expect(endpoint.segmentId, 0);
    expect(source.update('', isFinal: false), isNull);
  });

  test('manual anchor change creates a distinguishable new epoch', () {
    final source = AsrRecognitionSequencer()..reset(3);
    final before = source.update('同样一句话', isFinal: false)!;
    source.reset(4);
    final after = source.update('同样一句话', isFinal: false)!;
    expect(after.epoch, greaterThan(before.epoch));
    expect(after.revision, 1);
  });
}
