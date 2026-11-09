/// Preserve the words the speaker actually said, including repetitions.
/// Duplicate delivery is handled by utterance identity, not text rewriting.
String normalizeAsrTranscript(String text) => text.trim();

/// Both inputs belong to different recognizer utterances. Equal text across
/// that boundary can be an intentional repetition and must remain visible.
String appendAsrTranscript(String committed, String segment) {
  if (committed.isEmpty) return segment;
  if (segment.isEmpty) return committed;
  return '$committed\n$segment';
}

/// The partial replaces the current utterance, rather than being appended on
/// every audio callback. Its contents never decide whether an event is new.
String composeAsrDisplayText(String committed, String partial) =>
    appendAsrTranscript(committed, partial);
