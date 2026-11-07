import 'dart:io';

import 'package:image/image.dart' as image;

/// Validate the supplied transparent PNG and preserve its exact original bytes.
Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent;
  final bytes = await File(
    '${root.path}/assets/branding/BK-Teleprompter-source.png',
  ).readAsBytes();
  final source = image.decodePng(bytes);
  if (source == null || source.width != source.height || source.width < 256) {
    throw StateError('The source artwork must be square and at least 256px.');
  }
  await File('${root.path}/lib/favicon.png').writeAsBytes(bytes);
  await File('${root.path}/head_pic.png').writeAsBytes(bytes);
  stdout.writeln('BK 提词器 artwork preserved: ${source.width}x${source.height}.');
}
