import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:storm_teleprompter_plus/services/asr/asr_model_store.dart';
import 'package:storm_teleprompter_plus/services/asr/asr_preparation_exception.dart';

void main() {
  late Directory temporary;
  late Directory root;
  late Directory target;
  late Directory bundled;
  late AsrModelManifest manifest;
  late Map<String, List<int>> fixture;

  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('bk_asr_store_');
    root = Directory(p.join(temporary.path, '中文用户', '模型数据'));
    target = Directory(p.join(root.path, 'zipformer2-ced'));
    bundled = Directory(p.join(temporary.path, '安装目录', '内置中文模型'));
    fixture = {
      'encoder.onnx': utf8.encode('encoder-fixture'),
      'decoder.onnx': utf8.encode('decoder-fixture'),
      'joiner.onnx': utf8.encode('joiner-fixture'),
      'tokens.txt': utf8.encode('中 0\n文 1\n'),
    };
    final roles = ['encoder', 'decoder', 'joiner', 'tokens'];
    manifest = AsrModelManifest(
      modelId: 'zipformer2-ced',
      modelFamily: 'zipformer',
      sampleRate: 16000,
      files: fixture.entries.indexed.map((item) {
        final (index, entry) = item;
        return AsrModelFile(
          role: roles[index],
          name: entry.key,
          bytes: entry.value.length,
          sha256: sha256.convert(entry.value).toString(),
          url: Uri.https('modelscope.cn', '/fixture/' + entry.key),
        );
      }).toList(),
    );
  });

  tearDown(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<void> writeFixture(Directory directory) async {
    await directory.create(recursive: true);
    for (final entry in fixture.entries) {
      await File(p.join(directory.path, entry.key)).writeAsBytes(entry.value);
    }
  }

  test(
    'packaged manifest pins the complete original Zipformer family',
    () async {
      final actual = AsrModelManifest.parse(
        await File(AsrModelManifest.assetPath).readAsString(),
      );
      expect(actual.modelFamily, 'zipformer');
      expect(actual.sampleRate, 16000);
      expect(actual.files.map((file) => file.role).toSet(), {
        'encoder',
        'decoder',
        'joiner',
        'tokens',
      });
      expect(actual.totalBytes, 55616588);
      expect(
        actual.files.every((file) => file.url.host == 'modelscope.cn'),
        isTrue,
      );
    },
  );

  test(
    'valid installed model needs no network and keeps other models intact',
    () async {
      await writeFixture(target);
      final personal = File(p.join(root.path, 'other-model', 'notes.txt'));
      await personal.parent.create(recursive: true);
      await personal.writeAsString('other model is untouched');
      var requested = 0;
      final store = AsrModelStore(
        manifest: manifest,
        modelRoot: root,
        clientFactory: () {
          requested++;
          return MockClient((_) async => http.Response('', 500));
        },
      );
      expect((await store.prepare()).path, target.path);
      expect(requested, 0);
      expect(await personal.readAsString(), 'other model is untouched');
    },
  );

  test(
    'missing model is restored from verified bundled files in Chinese paths',
    () async {
      await writeFixture(bundled);
      final messages = <String>[];
      final store = AsrModelStore(
        manifest: manifest,
        modelRoot: root,
        bundledDirectory: bundled,
        clientFactory: () => throw StateError('Unexpected network access'),
      );
      final result = await store.prepare(
        onProgress: (_, message) => messages.add(message),
      );
      expect(await manifest.isDirectoryValid(result), isTrue);
      expect(messages.any((value) => value.contains('恢复内置')), isTrue);
      expect(await manifest.isDirectoryValid(bundled), isTrue);
    },
  );

  test(
    'same-length corruption downloads only the damaged file and verifies it',
    () async {
      await writeFixture(target);
      final corrupt = File(p.join(target.path, 'encoder.onnx'));
      await corrupt.writeAsBytes(
        List.filled(fixture['encoder.onnx']!.length, 0),
      );
      final requested = <String>[];
      final store = AsrModelStore(
        manifest: manifest,
        modelRoot: root,
        clientFactory: () => MockClient((request) async {
          final name = request.url.pathSegments.last;
          requested.add(name);
          return http.Response.bytes(fixture[name]!, 200);
        }),
      );
      await store.prepare();
      expect(requested, ['encoder.onnx']);
      expect(await manifest.isDirectoryValid(target), isTrue);
    },
  );

  test(
    'invalid download cannot replace the prior model or leave staging data',
    () async {
      await writeFixture(target);
      final corrupt = File(p.join(target.path, 'encoder.onnx'));
      final previous = List.filled(fixture['encoder.onnx']!.length, 0);
      await corrupt.writeAsBytes(previous);
      final store = AsrModelStore(
        manifest: manifest,
        modelRoot: root,
        clientFactory: () =>
            MockClient((_) async => http.Response.bytes(previous, 200)),
      );
      await expectLater(
        store.prepare(),
        throwsA(isA<AsrModelPreparationException>()),
      );
      expect(await corrupt.readAsBytes(), previous);
      expect(await root.list().map((file) => p.basename(file.path)).toList(), [
        'zipformer2-ced',
      ]);
    },
  );

  test('cancelled recovery never publishes a partial directory', () async {
    final subscribed = Completer<void>();
    final body = StreamController<List<int>>(onListen: subscribed.complete);
    final store = AsrModelStore(
      manifest: manifest,
      modelRoot: root,
      clientFactory: () => MockClient.streaming((_, _) async {
        return http.StreamedResponse(body.stream, 200);
      }),
    );
    final operation = store.prepare();
    final assertion = expectLater(
      operation,
      throwsA(
        isA<AsrModelPreparationException>().having(
          (error) => error.isCancelled,
          'isCancelled',
          isTrue,
        ),
      ),
    );
    await subscribed.future;
    store.cancel();
    body.add([0]);
    await body.close();
    await assertion;
    expect(await target.exists(), isFalse);
    expect(await root.list().toList(), isEmpty);
  });

  test('concurrent preparation shares one operation', () async {
    await writeFixture(bundled);
    final store = AsrModelStore(
      manifest: manifest,
      modelRoot: root,
      bundledDirectory: bundled,
    );
    final first = store.prepare();
    final second = store.prepare();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]);
    expect(await manifest.isDirectoryValid(target), isTrue);
  });

  test(
    'a failed direct connection may use the explicitly supplied proxy fallback',
    () async {
      var proxyRequests = 0;
      final store = AsrModelStore(
        manifest: manifest,
        modelRoot: root,
        clientFactory: () => MockClient((_) async => http.Response('', 503)),
        fallbackClientFactory: () async => MockClient((request) async {
          proxyRequests++;
          return http.Response.bytes(
            fixture[request.url.pathSegments.last]!,
            200,
          );
        }),
      );
      await store.prepare();
      expect(proxyRequests, 4);
      expect(await manifest.isDirectoryValid(target), isTrue);
    },
  );
}
