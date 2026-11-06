import 'dart:io';

import 'package:image/image.dart' as image;

/// Generate every Windows shell size from the unchanged user-supplied artwork.
/// The launcher package emits only one frame, which leaves small taskbar and
/// title-bar icons dependent on Windows resampling the 256px frame.
Future<void> main() async {
  final root = File.fromUri(Platform.script).parent.parent;
  final source = image.decodePng(
    await File('${root.path}/lib/favicon.png').readAsBytes(),
  );
  if (source == null || source.width != source.height || source.width < 256) {
    throw StateError(
      'The application icon must be a square PNG of at least 256px.',
    );
  }
  const sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256];
  final frames = [
    for (final size in sizes)
      image.copyResize(
        source,
        width: size,
        height: size,
        interpolation: image.Interpolation.average,
      ),
  ];
  final destination = File(
    '${root.path}/windows/runner/resources/app_icon.ico',
  );
  await destination.parent.create(recursive: true);
  await destination.writeAsBytes(image.IcoEncoder().encodeImages(frames));
  stdout.writeln('BK103 Windows icon: ${sizes.join(", ")}px.');
}
