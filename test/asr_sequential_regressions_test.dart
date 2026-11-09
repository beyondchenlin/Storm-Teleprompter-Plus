import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/services/asr/alignment_engine.dart';

int _endOf(String script, String phrase, {bool last = false}) =>
    (last ? script.lastIndexOf(phrase) : script.indexOf(phrase)) +
    phrase.length -
    1;

void main() {
  group('sequential speech following regressions', () {
    test(
      'an identical later sentence continues forwards after the middle paragraph',
      () {
        const phrase = '今天我们来讲学习方法';
        const middle = '先把旧知识整理成自己的笔记';
        const script = '$phrase。\n$middle。\n$phrase。';
        final alignment = TeleprompterAlignment()..setScript(script);
        alignment.consumeTranscript(phrase, true);
        final before = alignment.consumeTranscript(middle, true);

        final partial = alignment.consumeTranscript(phrase, false);
        final completed = alignment.consumeTranscript(phrase, true);

        expect(before.index, _endOf(script, middle));
        expect(partial.index, greaterThanOrEqualTo(before.index));
        expect(partial.meta.allowBackward, isFalse);
        expect(completed.index, _endOf(script, phrase, last: true));
      },
    );

    test(
      'a mistaken word cannot select a similar sentence in a distant paragraph',
      () {
        const first = '本节讲的是复习方法';
        const mistaken = '本节讲的是学习方法';
        const script = '$first。\n先把旧知识整理成自己的笔记。\n$mistaken。';
        final alignment = TeleprompterAlignment()..setScript(script);

        final provisional = alignment.consumeTranscript(mistaken, false);
        expect(provisional.index, lessThanOrEqualTo(_endOf(script, first)));

        final corrected = alignment.consumeTranscript(first, true);
        expect(corrected.index, _endOf(script, first));
      },
    );

    test('a single common character does not jump to a later occurrence', () {
      const script = '今天我们学习怎样制定计划，然后分步执行，最终形成稳定的学习习惯。';
      final alignment = TeleprompterAlignment()..setScript(script);

      expect(alignment.consumeTranscript('的', false).index, -1);
      expect(alignment.consumeTranscript('的', true).index, -1);
    });

    test('an aside matching only a common connective holds its place', () {
      const script = '今天我们学习怎样制定计划，然后分步执行，最终形成稳定的学习习惯。';
      final alignment = TeleprompterAlignment()..setScript(script);
      final before = alignment.consumeTranscript('今天我们学习', true);

      final aside = alignment.consumeTranscript('大家喝口水然后等一会再继续', false);
      final asideEnd = alignment.consumeTranscript('大家喝口水然后等一会再继续', true);
      expect(aside.index, before.index);
      expect(asideEnd.index, before.index);

      final resumed = alignment.consumeTranscript('怎样制定计划然后分步执行', true);
      expect(resumed.index, _endOf(script, '分步执行'));
    });

    test('identical partial notifications do not consume further script', () {
      const first = '请先整理你的学习笔记';
      const script = '$first。\n$first。\n最后检查掌握程度。';
      final alignment = TeleprompterAlignment()..setScript(script);
      final initial = alignment.consumeTranscript(first, false);

      for (var count = 0; count < 20; count++) {
        final repeated = alignment.consumeTranscript(first, false);
        expect(repeated.index, initial.index);
      }
      final completed = alignment.consumeTranscript(first, true);
      expect(completed.index, _endOf(script, first));
    });

    test(
      'two genuinely spoken adjacent duplicate sentences remain two occurrences',
      () {
        const phrase = '请先整理你的学习笔记';
        const script = '$phrase。\n$phrase。\n最后检查掌握程度。';
        final alignment = TeleprompterAlignment()..setScript(script);

        final first = alignment.consumeTranscript(phrase, true);
        final second = alignment.consumeTranscript(phrase, true);

        expect(first.index, _endOf(script, phrase));
        expect(second.index, _endOf(script, phrase, last: true));
        expect(second.meta.allowBackward, isFalse);
      },
    );

    test('real repeated words inside one utterance keep their full extent', () {
      const script = '重要重要重要，接下来再谈方法。';
      final alignment = TeleprompterAlignment()..setScript(script);

      final result = alignment.consumeTranscript('重要重要重要', true);

      expect(result.index, _endOf(script, '重要重要重要'));
    });

    test(
      'long cumulative recognition crosses sentences without an endpoint',
      () {
        const script =
            '学习需要先明确目标。把复杂的任务分成几个小步骤。'
            '每天坚持完成其中一个步骤。接着检查自己没有掌握的地方。'
            '遇到困难可以回头查看之前的笔记。将新知识和已有经验联系起来。'
            '通过实际练习发现理解中的漏洞。再用自己的语言重新解释一遍。'
            '最后制定下一轮复习的计划。整个过程需要保持清晰而稳定的节奏。';
        final alignment = TeleprompterAlignment()..setScript(script);
        var previous = -1;

        for (var end = 6; end < script.length; end += 6) {
          final result = alignment.consumeTranscript(
            script.substring(0, end),
            false,
          );
          expect(result.index, greaterThanOrEqualTo(previous));
          expect(result.index, lessThan(end));
          previous = result.index;
        }
        final finalResult = alignment.consumeTranscript(script, true);
        expect(finalResult.index, _endOf(script, '清晰而稳定的节奏'));
      },
    );

    test(
      'one omitted word and an inserted filler recover inside the current sentence',
      () {
        const script = '今天我们一起测试语音跟随功能。下一段介绍具体操作方法。';
        final alignment = TeleprompterAlignment()..setScript(script);

        alignment.consumeTranscript('今天一起测试', false);
        final result = alignment.consumeTranscript('今天我们这个一起测试语音跟随功能', true);

        expect(result.index, _endOf(script, '语音跟随功能'));
      },
    );

    test(
      'a two-character substitution still reaches the current sentence ending',
      () {
        const script = '学习的关键是建立知识之间的联系。接下来通过练习加深理解。';
        final alignment = TeleprompterAlignment()..setScript(script);

        final result = alignment.consumeTranscript('学习的关键是形成知识之间的联系', true);

        expect(result.index, _endOf(script, '知识之间的联系'));
      },
    );

    test(
      'a presenter can restart the current sentence without rewinding distant text',
      () {
        const first = '先把需要复习的材料准备好';
        const current = '再把旧知识整理成自己的笔记';
        const restart = '再把旧知识整理';
        const script = '$first。\n$current。\n最后检查掌握程度。';
        final alignment = TeleprompterAlignment()..setScript(script);
        alignment.consumeTranscript(first, true);
        final before = alignment.consumeTranscript(current, true);

        final restarted = alignment.consumeTranscript(restart, true);

        expect(restarted.index, _endOf(script, restart));
        expect(restarted.index, lessThan(before.index));
        expect(restarted.index, greaterThanOrEqualTo(script.indexOf(current)));
        expect(restarted.meta.allowBackward, isTrue);
        expect(
          alignment.consumeTranscript('成自己的笔记', true).index,
          _endOf(script, current),
        );
      },
    );

    test(
      'manual relocation replaces an unfinished previous utterance anchor',
      () {
        const first = '先从基础知识开始学习';
        const target = '在这里介绍完全不同的练习方法';
        const script = '$first。中间这一段介绍其他内容。$target。';
        final alignment = TeleprompterAlignment()..setScript(script);
        alignment.consumeTranscript('先从基础知识', false);

        alignment.setCurrentIndex(script.indexOf(target));
        final result = alignment.consumeTranscript(target, true);
        expect(result.index, _endOf(script, target));

        alignment.setCurrentIndex(0);
        expect(
          alignment.consumeTranscript(first, true).index,
          _endOf(script, first),
        );
      },
    );

    test(
      'English case changes and punctuation keep the same script position',
      () {
        const phrase = 'The Quick Brown Fox jumps over the lazy dog';
        const script = '$phrase.\nNext we discuss a different example.';
        final alignment = TeleprompterAlignment()..setScript(script);

        expect(alignment.consumeTranscript('a', false).index, -1);
        final result = alignment.consumeTranscript(
          'the quick brown FOX jumps over the lazy dog!',
          true,
        );

        expect(result.index, _endOf(script, phrase));
      },
    );

    test(
      'Chinese and English in the same sentence retain raw text offsets',
      () {
        const script = '大家好，Welcome to the lesson，现在开始测试。\n接着学习下一节。';
        final alignment = TeleprompterAlignment()..setScript(script);

        final result = alignment.consumeTranscript(
          '大家好 welcome to the lesson 现在开始测试',
          true,
        );

        expect(result.index, _endOf(script, '现在开始测试'));
      },
    );

    test('punctuation-only and silent results preserve confirmed position', () {
      const phrase = '请先整理你的学习笔记';
      const script = '$phrase。\n然后开始今天的练习。';
      final alignment = TeleprompterAlignment()..setScript(script);
      final before = alignment.consumeTranscript(phrase, true);

      for (final silence in ['', '   ', '，。！？']) {
        expect(alignment.consumeTranscript(silence, false).index, before.index);
        expect(alignment.consumeTranscript(silence, true).index, before.index);
      }
    });
  });
}
