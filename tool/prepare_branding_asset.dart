import 'dart:io';

import 'package:image/image.dart' as image;

/// The uploaded file was named .png but contains JPEG data. Keep its original
/// bytes separately and normalize the decoded pixels to a real lossless PNG.
Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent;
  final source = image.decodeImage(
    await File('${root.path}/assets/branding/BK103-source.jpg').readAsBytes(),
  );
  if (source == null || source.width != source.height || source.width < 256) {
    throw StateError('The source artwork must be square and at least 256px.');
  }
  await File(
    '${root.path}/lib/favicon.png',
  ).writeAsBytes(image.encodePng(source));
  stdout.writeln('BK103 artwork normalized: ${source.width}x${source.height}.');
}
