/// An exact, half-open UTF-16 range in the teleprompter's parsed body.
/// The quote is checked before painting; a stale offset must never mark a word.
class AnnotationRange {
  final int start;
  final int end;
  final String quote;

  const AnnotationRange({
    required this.start,
    required this.end,
    required this.quote,
  });

  factory AnnotationRange.fromJson(Map<String, dynamic> json) =>
      AnnotationRange(
        start: (json['start'] as num?)?.toInt() ?? -1,
        end: (json['end'] as num?)?.toInt() ?? -1,
        quote: json['quote'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'start': start, 'end': end, 'quote': quote};

  AnnotationRange shifted(int delta) =>
      AnnotationRange(start: start + delta, end: end + delta, quote: quote);
}

/// Coaching notes are stored separately from body text and speech alignment.
/// Unanchored notes retain their text and original quote for manual repair.
class ReadingAnnotation {
  final String id;
  final String text;
  final List<AnnotationRange> ranges;
  final String source;
  final int? page;
  final String? unresolvedReason;

  const ReadingAnnotation({
    required this.id,
    required this.text,
    this.ranges = const [],
    this.source = 'manual',
    this.page,
    this.unresolvedReason,
  });

  bool get isAnchored => unresolvedReason == null && ranges.isNotEmpty;

  factory ReadingAnnotation.fromJson(Map<String, dynamic> json) =>
      ReadingAnnotation(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        ranges: List.unmodifiable(
          (json['ranges'] as List? ?? const []).whereType<Map>().map(
            (range) =>
                AnnotationRange.fromJson(Map<String, dynamic>.from(range)),
          ),
        ),
        source: json['source'] as String? ?? 'manual',
        page: (json['page'] as num?)?.toInt(),
        unresolvedReason: json['unresolvedReason'] as String?,
      );

  static List<ReadingAnnotation> listFromJson(Object? value) =>
      List.unmodifiable(
        (value is List ? value : const []).whereType<Map>().map(
          (item) => ReadingAnnotation.fromJson(Map<String, dynamic>.from(item)),
        ),
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    'ranges': ranges.map((range) => range.toJson()).toList(),
    'source': source,
    if (page != null) 'page': page,
    if (unresolvedReason != null) 'unresolvedReason': unresolvedReason,
  };

  ReadingAnnotation copyWith({
    String? text,
    List<AnnotationRange>? ranges,
    String? unresolvedReason,
    bool clearUnresolvedReason = false,
  }) => ReadingAnnotation(
    id: id,
    text: text ?? this.text,
    ranges: ranges == null ? this.ranges : List.unmodifiable(ranges),
    source: source,
    page: page,
    unresolvedReason: clearUnresolvedReason
        ? null
        : unresolvedReason ?? this.unresolvedReason,
  );
}
