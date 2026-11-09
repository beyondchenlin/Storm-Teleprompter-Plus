import 'dart:math' as math;

/// An approved reading position. Candidate positions are never used as an
/// independent search origin until their utterance has been committed.
class AlignmentResult {
  final int index;
  final String targetId;
  final AlignmentMeta meta;

  const AlignmentResult({
    required this.index,
    required this.targetId,
    required this.meta,
  });
}

class AlignmentMeta {
  final String strategy;
  final int matchedLength;
  final String text;
  final bool isFinal;
  final bool allowBackward;
  final bool isWaiting;

  const AlignmentMeta({
    required this.strategy,
    this.matchedLength = 0,
    required this.text,
    required this.isFinal,
    this.allowBackward = false,
    this.isWaiting = false,
  });
}

class _Path {
  final int edits;
  final int matches;
  final int run;
  final int longestRun;
  final int trailingEdits;

  const _Path({
    this.edits = 0,
    this.matches = 0,
    this.run = 0,
    this.longestRun = 0,
    this.trailingEdits = 0,
  });

  _Path match() => _Path(
    edits: edits,
    matches: matches + 1,
    run: run + 1,
    longestRun: math.max(longestRun, run + 1),
  );

  _Path? edit() => trailingEdits >= 3
      ? null
      : _Path(
          edits: edits + 1,
          matches: matches,
          longestRun: longestRun,
          trailingEdits: trailingEdits + 1,
        );
}

class _Candidate {
  final int start;
  final int end;
  final int consumed;
  final int matches;
  final int edits;
  final int longestRun;
  final String strategy;
  final int transcriptStart;

  const _Candidate({
    required this.start,
    required this.end,
    required this.consumed,
    required this.matches,
    required this.edits,
    required this.longestRun,
    this.strategy = 'sequential',
    this.transcriptStart = 0,
  });

  int get score => matches * 3 - edits * 2;

  _Candidate withStrategy(String value) => _Candidate(
    start: start,
    end: end,
    consumed: consumed,
    matches: matches,
    edits: edits,
    longestRun: longestRun,
    strategy: value,
    transcriptStart: transcriptStart,
  );
}

/// Sequential, utterance-aware script alignment.
///
/// The recognizer supplies cumulative hypotheses for one utterance, then a
/// final hypothesis. Every revision is aligned from that utterance's original
/// anchor; receiving the same hypothesis repeatedly cannot consume more script.
/// Current/adjacent sentences are preferred over remote identical phrases.
class TeleprompterAlignment {
  static final _readingCharacter = RegExp(r'[a-zA-Z0-9\u3400-\u9fff]');
  static final _sentenceBreak = RegExp(r'[。！？!?；;，\r\n]');
  static final _latinOnly = RegExp(r'^[a-z0-9]+$');
  static const _maximumNearbyDistance = 80;
  static const _maximumBackwardDistance = 80;
  static const _editBand = 16;

  String _cleanScript = '';
  final List<int> _indexMap = [];
  final List<int> _sentenceStarts = [];
  int _anchorIndex = -1;
  int _currentIndex = -1;
  int _confirmedIndex = -1;
  String _previousText = '';
  _Candidate? _previousCandidate;
  AlignmentResult? _lastPartialResult;
  bool _manualAnchor = false;
  int _recoveryOffset = 0;
  int _recoveryAnchor = -1;
  String _recoveryPrefix = '';

  /// [sentenceBoundaries] contains original character offsets, useful when
  /// rich text paragraphs have no literal newline in the display index space.
  void setScript(
    String content, {
    Iterable<int> sentenceBoundaries = const [],
  }) {
    final explicitBoundaries = sentenceBoundaries.toSet();
    final script = StringBuffer();
    _indexMap.clear();
    _sentenceStarts
      ..clear()
      ..add(0);
    var pendingBoundary = false;
    for (var raw = 0; raw < content.length; raw++) {
      if (explicitBoundaries.contains(raw)) pendingBoundary = true;
      final character = content[raw];
      if (_sentenceBreak.hasMatch(character) ||
          (character == '.' &&
              (raw == 0 ||
                  !_isDigit(content[raw - 1]) ||
                  raw + 1 == content.length ||
                  !_isDigit(content[raw + 1])))) {
        pendingBoundary = true;
      }
      if (!_readingCharacter.hasMatch(character)) continue;
      if (pendingBoundary && _indexMap.length != _sentenceStarts.last) {
        _sentenceStarts.add(_indexMap.length);
      }
      pendingBoundary = false;
      script.write(character.toLowerCase());
      _indexMap.add(raw);
    }
    _cleanScript = script.toString();
    reset();
  }

  static bool _isDigit(String character) =>
      character.codeUnitAt(0) >= 48 && character.codeUnitAt(0) <= 57;

  void reset() {
    _anchorIndex = -1;
    _currentIndex = -1;
    _confirmedIndex = -1;
    _manualAnchor = false;
    _clearUtterance();
  }

  void _clearUtterance() {
    _previousText = '';
    _previousCandidate = null;
    _lastPartialResult = null;
    _recoveryOffset = 0;
    _recoveryAnchor = -1;
    _recoveryPrefix = '';
  }

  /// The caller resets the recognizer's current utterance at the same time.
  void setCurrentIndex(int rawIndex) {
    var cleanIndex = -1;
    if (rawIndex >= 0 && _indexMap.isNotEmpty) {
      // The selected character remains visible. The normal continuation starts
      // after it, with an inclusive fallback for reading the clicked word.
      cleanIndex = _indexMap.indexWhere((raw) => raw >= rawIndex);
      if (cleanIndex < 0) cleanIndex = _indexMap.length - 1;
    }
    _anchorIndex = cleanIndex;
    _currentIndex = cleanIndex;
    _confirmedIndex = cleanIndex;
    _manualAnchor = true;
    _clearUtterance();
  }

  int _toRaw(int index) =>
      index < 0 || index >= _indexMap.length ? -1 : _indexMap[index];

  String _normalize(String text) => text
      .split('')
      .where(_readingCharacter.hasMatch)
      .map((character) => character.toLowerCase())
      .join();

  int _sentenceOf(int index) {
    var low = 0;
    var high = _sentenceStarts.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (_sentenceStarts[middle] <= index) {
        low = middle;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int _sentenceEnd(int index) {
    final sentence = _sentenceOf(index);
    return sentence + 1 < _sentenceStarts.length
        ? _sentenceStarts[sentence + 1]
        : _cleanScript.length;
  }

  static _Path? _betterPath(_Path? first, _Path? second) {
    if (first == null) return second;
    if (second == null) return first;
    if (first.edits != second.edits) {
      return first.edits < second.edits ? first : second;
    }
    if (first.matches != second.matches) {
      return first.matches > second.matches ? first : second;
    }
    return first.longestRun >= second.longestRun ? first : second;
  }

  /// Banded edit-distance alignment from a particular nearby script origin.
  /// It may consume many sentences when the cumulative hypothesis supports
  /// them; the search-origin window is not a cap on utterance length.
  _Candidate? _matchAt(int start, String text, {required bool isFinal}) {
    if (start < 0 || start >= _cleanScript.length || text.isEmpty) return null;
    final remaining = _cleanScript.length - start;
    final width = math.min(remaining, text.length + _editBand);
    var previous = List<_Path?>.filled(width + 1, null);
    previous[0] = const _Path();
    for (var column = 1; column <= math.min(3, width); column++) {
      previous[column] = previous[column - 1]?.edit();
    }
    _Candidate? best;
    for (var row = 1; row <= text.length; row++) {
      final current = List<_Path?>.filled(width + 1, null);
      if (row <= 3) current[0] = previous[0]?.edit();
      final firstColumn = math.max(1, row - _editBand);
      final lastColumn = math.min(width, row + _editBand);
      for (var column = firstColumn; column <= lastColumn; column++) {
        final equal = text[row - 1] == _cleanScript[start + column - 1];
        final diagonal = previous[column - 1];
        var path = equal ? diagonal?.match() : diagonal?.edit();
        path = _betterPath(path, previous[column]?.edit());
        path = _betterPath(path, current[column - 1]?.edit());
        current[column] = path;
        // Only a matching final character establishes an actual read position.
        if (path == null || !equal || path.trailingEdits != 0) continue;
        final shortComplete =
            isFinal &&
            text.length <= 2 &&
            row == text.length &&
            column == text.length &&
            start + column == _sentenceEnd(start) &&
            path.edits == 0;
        final minimum = shortComplete ? text.length : 3;
        if (path.matches < minimum ||
            path.longestRun < math.min(3, minimum) ||
            path.matches / row < 0.70 ||
            path.matches / column < 0.70 ||
            path.edits / math.max(row, column) > 0.30) {
          continue;
        }
        final candidate = _Candidate(
          start: start,
          end: start + column - 1,
          consumed: row,
          matches: path.matches,
          edits: path.edits,
          longestRun: path.longestRun,
        );
        if (best == null ||
            candidate.score > best.score ||
            (candidate.score == best.score && candidate.end < best.end)) {
          best = candidate;
        }
      }
      previous = current;
      if (firstColumn > width) break;
    }
    return best;
  }

  bool _strongRelocation(_Candidate candidate, String text) =>
      candidate.matches >= (_latinOnly.hasMatch(text) ? 8 : 6) &&
      candidate.longestRun >= 4 &&
      candidate.consumed >= text.length - 1 &&
      candidate.matches / candidate.consumed >= 0.85 &&
      candidate.edits <= 1;

  _Candidate? _forward(int anchor, String text, {required bool isFinal}) {
    final start = math.max(0, anchor + 1);
    if (start >= _cleanScript.length) return null;
    var continuous = _matchAt(start, text, isFinal: isFinal);
    if (_manualAnchor && anchor >= 0 && continuous == null) {
      continuous = _matchAt(anchor, text, isFinal: isFinal);
    }
    // Near-identical later sentences must not steal a valid continuation.
    // Four new distinguishing characters are required before considering an
    // adjacent sentence when only a common opening matched the current one.
    if (continuous != null && continuous.consumed >= text.length - 3) {
      return continuous;
    }
    final sentence = _sentenceOf(start);
    if (sentence + 1 >= _sentenceStarts.length) return continuous;
    final next = _sentenceStarts[sentence + 1];
    if (next - start > _maximumNearbyDistance) return continuous;
    final candidate = _matchAt(next, text, isFinal: isFinal);
    if (candidate != null &&
        _strongRelocation(candidate, text) &&
        (continuous == null ||
            (candidate.consumed - continuous.consumed >= 4 &&
                candidate.matches - continuous.matches >= 4))) {
      return candidate.withStrategy('nearby_skip');
    }
    return continuous;
  }

  _Candidate? _reread(int position, String text, {required bool isFinal}) {
    if (position < 0) return null;
    final sentence = _sentenceOf(position);
    // Most recent sentence first. Never search the whole preceding document.
    for (var number = sentence; number >= math.max(0, sentence - 1); number--) {
      final start = _sentenceStarts[number];
      if (position - start > _maximumBackwardDistance) continue;
      final candidate = _matchAt(start, text, isFinal: isFinal);
      if (candidate != null &&
          candidate.start <= position &&
          _strongRelocation(candidate, text)) {
        return candidate.withStrategy('reread');
      }
    }
    return null;
  }

  /// After a long aside within the same utterance, resume using new speech
  /// after an unchanged, already-aligned prefix. A short common word cannot
  /// trigger this recovery and old hypotheses cannot be consumed twice.
  _Candidate? _recoverAfterAside(String text, {required bool isFinal}) {
    final previous = _previousCandidate;
    int earliest;
    if (previous != null) {
      if (previous.consumed >= text.length ||
          _previousText.length < previous.consumed ||
          !text.startsWith(_previousText.substring(0, previous.consumed))) {
        return null;
      }
      earliest = previous.consumed;
    } else {
      // Initial asides also need recovery. Require genuinely growing speech;
      // polling the same unrelated text, or finalizing it, adds no evidence.
      if (_previousText.isEmpty ||
          text.length <= _previousText.length ||
          !text.startsWith(_previousText))
        return null;
      earliest = math.max(0, _previousText.length - 5);
    }
    final latest = text.length - 6;
    if (latest < earliest) return null;
    // Look only at genuinely new suffixes, bounded to a normal spoken clause.
    final first = math.max(earliest, text.length - 80);
    for (var offset = first; offset <= latest; offset++) {
      final suffix = text.substring(offset);
      var candidate = _forward(_currentIndex, suffix, isFinal: isFinal);
      candidate ??= _reread(_currentIndex, suffix, isFinal: isFinal);
      if (candidate == null || !_strongRelocation(candidate, suffix)) continue;
      return _Candidate(
        start: candidate.start,
        end: candidate.end,
        consumed: offset + candidate.consumed,
        matches: candidate.matches,
        edits: candidate.edits,
        longestRun: candidate.longestRun,
        strategy: candidate.strategy == 'reread' ? 'reread' : 'resume',
        transcriptStart: offset,
      );
    }
    return null;
  }

  AlignmentResult _result(
    String text,
    bool isFinal,
    String strategy, {
    int matched = 0,
    bool backward = false,
    bool waiting = false,
  }) {
    final raw = _toRaw(_currentIndex);
    return AlignmentResult(
      index: raw,
      targetId: 'word_$raw',
      meta: AlignmentMeta(
        strategy: strategy,
        matchedLength: matched,
        text: text,
        isFinal: isFinal,
        allowBackward: backward,
        isWaiting: waiting,
      ),
    );
  }

  AlignmentResult consumeTranscript(String text, bool isFinal) {
    final normalized = _normalize(text);
    if (_cleanScript.isEmpty || normalized.isEmpty) {
      if (isFinal) {
        _anchorIndex = _confirmedIndex;
        _manualAnchor = false;
        _clearUtterance();
      }
      return _result(text, isFinal, 'empty');
    }
    if (!isFinal && normalized == _previousText && _lastPartialResult != null) {
      return _lastPartialResult!;
    }

    final before = _currentIndex;
    if (_recoveryOffset > 0 && !normalized.startsWith(_recoveryPrefix)) {
      _recoveryOffset = 0;
      _recoveryAnchor = -1;
      _recoveryPrefix = '';
    }
    var candidate = _forward(
      _recoveryOffset > 0 ? _recoveryAnchor : _anchorIndex,
      normalized.substring(_recoveryOffset),
      isFinal: isFinal,
    );
    if (candidate != null && _recoveryOffset > 0) {
      candidate = _Candidate(
        start: candidate.start,
        end: candidate.end,
        consumed: candidate.consumed + _recoveryOffset,
        matches: candidate.matches,
        edits: candidate.edits,
        longestRun: candidate.longestRun,
        strategy: 'resume',
        transcriptStart: _recoveryOffset,
      );
    }
    final recovered = _recoverAfterAside(normalized, isFinal: isFinal);
    if (recovered != null &&
        (candidate == null || recovered.consumed > candidate.consumed)) {
      candidate = recovered;
    }
    candidate ??= _reread(_anchorIndex, normalized, isFinal: isFinal);

    var strategy = 'none';
    var backward = false;
    if (candidate != null) {
      if (candidate.end < before && candidate.strategy != 'reread') {
        final sentence = _sentenceOf(before);
        final floor = math.max(
          _sentenceStarts[math.max(0, sentence - 1)],
          before - _maximumBackwardDistance,
        );
        // A local revision may retract even a long *unconfirmed* hypothesis.
        // The distance guard protects confirmed reading history, not guesses
        // which the recognizer has subsequently withdrawn.
        if (candidate.end < floor && candidate.end < _confirmedIndex) {
          candidate = null;
        }
      }
      if (candidate != null) {
        _currentIndex = candidate.end;
        backward = _currentIndex < before;
        strategy = backward && candidate.strategy != 'reread'
            ? 'partial_correction'
            : candidate.strategy;
        if (candidate.transcriptStart > 0) {
          _recoveryOffset = candidate.transcriptStart;
          _recoveryAnchor = candidate.start - 1;
          _recoveryPrefix = normalized.substring(0, _recoveryOffset);
        }
        if (isFinal) {
          _confirmedIndex = _currentIndex;
        } else if (_previousCandidate?.start == candidate.start) {
          var common = 0;
          final length = math.min(_previousText.length, normalized.length);
          while (common < length &&
              _previousText[common] == normalized[common]) {
            common++;
          }
          if (common > candidate.transcriptStart) {
            final stable = _matchAt(
              candidate.start,
              normalized.substring(candidate.transcriptStart, common),
              isFinal: false,
            );
            if (stable != null &&
                stable.end <= candidate.end &&
                stable.end <= _previousCandidate!.end) {
              _confirmedIndex = stable.end;
            }
          }
        }
      }
    }

    final result = _result(
      text,
      isFinal,
      strategy,
      matched: candidate?.matches ?? 0,
      backward: backward,
      waiting: candidate == null || candidate.consumed < normalized.length - 3,
    );
    if (isFinal) {
      // A rejected final must not turn an unstable hypothesis into a new
      // permanent search origin. The next utterance resumes at the last
      // confirmed prefix; a valid later hypothesis can correct the display.
      _anchorIndex = _confirmedIndex;
      _manualAnchor = false;
      _clearUtterance();
    } else {
      _previousText = normalized;
      _previousCandidate = candidate;
      _lastPartialResult = result;
    }
    return result;
  }

  int get cleanLength => _cleanScript.length;
  int get currentIndex => _currentIndex;
  int get confirmedIndex => _confirmedIndex;
}
