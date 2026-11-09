import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/asr/alignment_engine.dart';

void main() {
  group('sequential alignment index and utterance contracts', () {
    test(
      'preserves original punctuation and case-insensitive word offsets',
      () {
        const script = '大家好，Welcome to Storm Teleprompter，现在开始测试。';
        final alignment = TeleprompterAlignment()..setScript(script);
        final result = alignment.consumeTranscript(
          '大家好 welcome to storm teleprompter',
          true,
        );
        expect(result.index, script.indexOf('，现在') - 1);
        expect(result.meta.isWaiting, isFalse);
      },
    );

    test('logical boundaries work without adding display characters', () {
      const first = '先把知识整理成自己的笔记';
      const second = '接下来开始新的练习';
      const third = '最后检查本次学习成果';
      final alignment = TeleprompterAlignment()
        ..setScript(
          '$first$second$third',
          sentenceBoundaries: [first.length, first.length + second.length],
        )
        ..setCurrentIndex(first.length - 1);
      final result = alignment.consumeTranscript(second, true);
      expect(result.index, first.length + second.length - 1);
      expect(result.meta.allowBackward, isFalse);
    });

    test('complete two-character sentences retain both occurrences', () {
      const script = '重要。重要。接下来继续学习。';
      final alignment = TeleprompterAlignment()..setScript(script);
      expect(alignment.consumeTranscript('重要', true).index, 1);
      expect(alignment.consumeTranscript('重要', true).index, 4);
      expect(
        alignment.consumeTranscript('接下来继续学习', true).index,
        script.length - 2,
      );
    });

    test('short clauses separated by a Chinese comma consume real repeats', () {
      const script = '重要，重要。接下来继续学习。';
      final alignment = TeleprompterAlignment()..setScript(script);
      expect(alignment.consumeTranscript('重要', true).index, 1);
      expect(alignment.consumeTranscript('重要', true).index, 4);
      expect(
        alignment.consumeTranscript('接下来继续学习', true).index,
        script.length - 2,
      );
    });

    test('one-character noise cannot search ahead for a common character', () {
      const script = '今天我们学习怎样制定计划，然后分步执行，最终形成稳定的学习习惯。';
      final alignment = TeleprompterAlignment()..setScript(script);
      final result = alignment.consumeTranscript('的', true);
      expect(result.index, -1);
      expect(result.meta.isWaiting, isTrue);
    });

    test('repeated callbacks cannot confirm an unstable hypothesis', () {
      final alignment = TeleprompterAlignment()..setScript('今天我们开始学习新的知识。');
      final initial = alignment.consumeTranscript('今天我们开始', false);
      final confirmed = alignment.confirmedIndex;
      for (var i = 0; i < 20; i++) {
        expect(
          alignment.consumeTranscript('今天我们开始', false).index,
          initial.index,
        );
        expect(alignment.confirmedIndex, confirmed);
      }
    });

    test('growing matching speech confirms the unchanged earlier prefix', () {
      final alignment = TeleprompterAlignment()..setScript('今天我们开始学习新的知识。');
      final first = alignment.consumeTranscript('今天我们', false);
      alignment.consumeTranscript('今天我们开始学习', false);
      expect(alignment.confirmedIndex, first.index);
    });

    test('rejected final does not commit a speculative adjacent skip', () {
      const script = '先整理自己的笔记。然后开始今天的课程。';
      final alignment = TeleprompterAlignment()..setScript(script);
      final speculative = alignment.consumeTranscript('然后开始今天的课程', false);
      expect(speculative.index, greaterThan(script.indexOf('。')));
      alignment.consumeTranscript('完全没有相关内容', true);
      final corrected = alignment.consumeTranscript('先整理自己的笔记', true);
      expect(corrected.index, script.indexOf('。') - 1);
      expect(corrected.meta.allowBackward, isTrue);
    });

    test('empty final does not promote a speculative position either', () {
      const script = '先整理自己的笔记。然后开始今天的课程。';
      final alignment = TeleprompterAlignment()..setScript(script);
      alignment.consumeTranscript('然后开始今天的课程', false);
      alignment.consumeTranscript('', true);
      expect(
        alignment.consumeTranscript('先整理自己的笔记', true).index,
        script.indexOf('。') - 1,
      );
    });

    const longScript =
        '今天我们来讲学习方法。'
        '先把需要复习的材料准备好并整理成自己的笔记。'
        '之后寻找不同概念之间的关系再画出一张完整的结构图。'
        '把每个步骤用自己的话讲给其他同学听并回答他们的问题。'
        '最后通过实际练习检查理解中的漏洞并记录需要改进的地方。';

    test('withdrawn long speculation can return to its confirmed origin', () {
      final alignment = TeleprompterAlignment()..setScript(longScript);
      final speculative = alignment.consumeTranscript(longScript, false);
      expect(speculative.index, greaterThan(80));
      expect(alignment.confirmedIndex, -1);
      alignment.consumeTranscript('', false);
      alignment.consumeTranscript('', true);
      final corrected = alignment.consumeTranscript('今天我们来讲学习方法', true);
      expect(corrected.index, longScript.indexOf('。') - 1);
      expect(corrected.meta.allowBackward, isTrue);
    });

    test('confirmed long reading still rejects a remote earlier sentence', () {
      final alignment = TeleprompterAlignment()..setScript(longScript);
      final completed = alignment.consumeTranscript(longScript, true);
      final remoteRepeat = alignment.consumeTranscript('今天我们来讲学习方法', true);
      expect(remoteRepeat.index, completed.index);
      expect(remoteRepeat.meta.allowBackward, isFalse);
      expect(remoteRepeat.meta.isWaiting, isTrue);
    });

    test(
      'a long cumulative utterance continues beyond the old search window',
      () {
        final sentences = List.generate(
          30,
          (index) => '第${index + 1}项知识需要结合具体例子理解',
        );
        final script = '${sentences.join('。')}。';
        final alignment = TeleprompterAlignment()..setScript(script);
        var spoken = '';
        var previous = -1;
        for (var index = 0; index < sentences.length; index++) {
          spoken += sentences[index];
          final result = alignment.consumeTranscript(spoken, false);
          expect(result.index, greaterThan(previous));
          previous = result.index;
        }
        expect(
          alignment.consumeTranscript(spoken, true).index,
          script.length - 2,
        );
      },
    );

    test(
      'nearby skip needs distinguishing continuation beyond common opener',
      () {
        const script = '接下来先复习昨天的知识。接下来开始今天的练习。';
        final alignment = TeleprompterAlignment()..setScript(script);
        final opening = alignment.consumeTranscript('接下来', false);
        expect(opening.index, lessThan(script.indexOf('。')));
        final distinct = alignment.consumeTranscript('接下来开始今天的练习', true);
        expect(distinct.index, script.length - 2);
        expect(distinct.meta.strategy, 'nearby_skip');
      },
    );

    test(
      'same-utterance initial aside can recover on genuinely new speech',
      () {
        const script = '今天我们学习如何建立知识之间的联系。';
        const aside = '大家先稍等一下准备好了';
        final alignment = TeleprompterAlignment()..setScript(script);
        expect(alignment.consumeTranscript(aside, false).index, -1);
        final result = alignment.consumeTranscript('${aside}今天我们学习如何', false);
        expect(result.index, script.indexOf('建立') - 1);
        final continued = alignment.consumeTranscript(
          '${aside}今天我们学习如何建立知识之间的联系',
          true,
        );
        expect(continued.index, script.length - 2);
      },
    );

    test('same-utterance aside recovery remains anchored as speech grows', () {
      const script = '今天我们开始学习。建立知识之间的联系十分重要。';
      const prefix = '今天我们开始学习';
      const aside = '大家先喝一口水等一下再继续';
      final alignment = TeleprompterAlignment()..setScript(script);
      final before = alignment.consumeTranscript(prefix, false);
      final waiting = alignment.consumeTranscript('$prefix$aside', false);
      expect(waiting.index, before.index);
      expect(waiting.meta.isWaiting, isTrue);
      final resumed = alignment.consumeTranscript(
        '$prefix${aside}建立知识之间的联系',
        false,
      );
      expect(resumed.index, greaterThan(before.index));
      final next = alignment.consumeTranscript(
        '$prefix${aside}建立知识之间的联系十分',
        false,
      );
      expect(next.index, greaterThanOrEqualTo(resumed.index));
      final finalResult = alignment.consumeTranscript(
        '$prefix${aside}建立知识之间的联系十分重要',
        true,
      );
      expect(finalResult.index, script.length - 2);
    });

    test('rereading a sentence may continue past the old position', () {
      const script = '建立知识之间的联系十分重要。接下来进行练习。';
      final alignment = TeleprompterAlignment()..setScript(script);
      alignment.consumeTranscript('建立知识之间', true);
      final result = alignment.consumeTranscript('建立知识之间的联系十分重要', true);
      expect(result.index, script.indexOf('。') - 1);
      expect(result.meta.strategy, 'reread');
    });

    test('manual movement clears all utterance recovery state', () {
      const script = '今天我们开始学习。建立知识之间的联系十分重要。';
      final alignment = TeleprompterAlignment()..setScript(script);
      alignment.consumeTranscript('大家先喝水', false);
      alignment.consumeTranscript('大家先喝水今天我们开始学习', false);
      alignment.setCurrentIndex(script.indexOf('。'));
      final result = alignment.consumeTranscript('建立知识之间的联系十分重要', true);
      expect(result.index, script.length - 2);
    });
  });
}
