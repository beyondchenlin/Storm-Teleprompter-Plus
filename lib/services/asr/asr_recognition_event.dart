/// One revision of a recognizer utterance. Text alone cannot distinguish a
/// duplicate notification from the speaker genuinely saying the same words.
class AsrRecognitionEvent {
  const AsrRecognitionEvent({
    required this.epoch,
    required this.segmentId,
    required this.revision,
    required this.text,
    required this.isFinal,
  });

  /// Replaced whenever the user chooses a new reading position or restarts.
  final int epoch;
  final int segmentId;
  final int revision;
  final String text;
  final bool isFinal;
}

/// Assigns identity at the recognizer boundary, before callbacks reach the
/// position matcher. An unchanged partial is not new reading evidence.
class AsrRecognitionSequencer {
  int _epoch = 0;
  int _segmentId = 0;
  int _revision = 0;
  String? _lastText;

  void reset(int epoch) {
    _epoch = epoch;
    _segmentId = 0;
    _revision = 0;
    _lastText = null;
  }

  AsrRecognitionEvent? update(String text, {required bool isFinal}) {
    final normalized = text.trim();
    if (!isFinal &&
        (normalized == _lastText ||
            (normalized.isEmpty && _lastText == null))) {
      return null;
    }
    _lastText = normalized;
    final event = AsrRecognitionEvent(
      epoch: _epoch,
      segmentId: _segmentId,
      revision: ++_revision,
      text: normalized,
      isFinal: isFinal,
    );
    if (isFinal) {
      _segmentId++;
      _revision = 0;
      _lastText = null;
    }
    return event;
  }
}
