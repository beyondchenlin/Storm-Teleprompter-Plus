part of '../editor_page.dart';

/// 编辑内容转换、自动保存队列和提词启动逻辑。
mixin EditorLogic on State<EditorPage> {
  late final TextEditingController titleController;
  late final TextEditingController contentController;
  late final TextEditingController findController;
  late final TextEditingController replaceController;
  late final quill.QuillController quillController;
  late final FocusNode editorFocusNode;
  final GlobalKey quillEditorKey = GlobalKey(
    debugLabel: 'PersistentArticleEditor',
  );
  late final FocusNode findFocusNode;
  late ArticleProvider _articleProvider;

  Article? _savedArticle;
  Map<String, dynamic>? _draftTeleprompterSettings;

  AppSettings get annotationPreviewSettings => context
      .read<SettingsProvider>()
      .settings
      .mergeOverrides(_draftTeleprompterSettings ?? const {});

  void applyAnnotationAppearance(AppSettings settings) {
    final current = annotationPreviewSettings;
    if (current.annotationFontFamily == settings.annotationFontFamily &&
        current.annotationFontSize == settings.annotationFontSize &&
        current.annotationColor == settings.annotationColor) return;
    _draftTeleprompterSettings = current.copyWith(
      annotationFontFamily: settings.annotationFontFamily,
      annotationFontSize: settings.annotationFontSize,
      annotationColor: settings.annotationColor,
    ).toTeleprompterMap();
    _markChanged();
  }
  List<ReadingAnnotation> _annotations = const [];
  List<ReadingAnnotation> get annotations => List.unmodifiable(_annotations);
  String? _annotationFontNoticeContent;
  List<ReadingAnnotation>? _annotationFontNoticeNotes;
  bool _annotationFontNotice = false;
  String? _saveFolderId;
  bool _discardOnDispose = false;
  bool _disposingEditor = false;

  /// 普通模式始终自动保存，快速模式由启动时策略决定。
  bool get autoSaveEnabled => !widget.quickMode || widget.autoSave;
  Timer? _autosaveTimer;
  Future<Article?>? _saveOperation;
  _EditorDraft? _queuedDraft;
  bool _syncingEditorContent = false;
  int _editRevision = 0;

  // Keys are the actual Quill history entries, never a text search or a body
  // hash. Only anchors enter this history; the current note text always wins.
  final Map<qd.Delta, _AnnotationHistoryRecord> _annotationHistory =
      Map<qd.Delta, _AnnotationHistoryRecord>.identity();
  List<qd.Delta> _knownAnnotationUndo = const [];
  quill.Document? _annotationHistoryDocument;
  qd.Delta? _lastAnnotationDocumentDelta;
  _AnnotationHistoryReplay? _annotationHistoryReplay;

  bool isDirty = false;
  bool isSaving = false;
  bool _lastSaveFailed = false;
  bool isFindReplaceVisible = false;
  bool isReplaceMode = false;
  String findReplaceStatus = '';

  Article? get currentArticle => _savedArticle;

  int get plainTextLength =>
      TextParser.visibleCharacterCount(quillController.document.toPlainText());

  bool get canStartTeleprompter => plainTextLength > 0 && !isSaving;

  String get saveStatusText {
    if (isSaving) return '保存中';
    if (_lastSaveFailed) return '保存失败（修改已保留）';
    if (!autoSaveEnabled && (isDirty || _savedArticle == null)) return '未保存';
    if (isDirty) return '等待自动保存';
    return _savedArticle == null ? '尚未保存' : '已保存';
  }

  @override
  void initState() {
    super.initState();
    _savedArticle = widget.article;
    _draftTeleprompterSettings = widget.article?.teleprompterSettings == null
        ? null
        : Map<String, dynamic>.from(widget.article!.teleprompterSettings!);
    _annotations = AnnotationAnchors.validate(
      widget.article?.content ?? '',
      widget.article?.annotations ?? const [],
    );
    _saveFolderId = widget.initialFolderId;
    titleController = TextEditingController(text: widget.article?.title ?? '');
    contentController = TextEditingController(
      text: widget.article?.content ?? '',
    );
    findController = TextEditingController();
    replaceController = TextEditingController();
    editorFocusNode = FocusNode(debugLabel: 'ArticleEditor');
    findFocusNode = FocusNode(debugLabel: 'FindReplace');
    quillController = _AnnotationQuillController(
      onHistoryReplay: _performAnnotationHistoryReplay,
      document: quill.Document.fromDelta(
        _contentToDelta(widget.article?.content ?? ''),
      ),
      selection: const TextSelection.collapsed(offset: 0),
      config: quill_config.QuillControllerConfig(
        // flutter_quill 目前仅通过实验 API 暴露自定义粘贴清理回调。
        // ignore: experimental_member_use
        clipboardConfig: quill_config.QuillClipboardConfig(
          // ignore: experimental_member_use
          onPlainTextPaste: (plainText) async => _cleanPastedText(plainText),
          // ignore: experimental_member_use
          onRichTextPaste: (delta, isExternal) async =>
              _cleanPastedDelta(delta),
        ),
      ),
    );

    // The editor always stores paragraph HTML. Convert legacy plain-text
    // offsets now, before a selection notification or title-only save can
    // mistake removal of structural newlines for edits to annotated words.
    final originalContent = contentController.text;
    final initialHtml = _deltaToStorageHtml(quillController.document.toDelta());
    _annotations = _normalizeInitialAnnotationAnchors(
      originalContent,
      initialHtml,
      _annotations,
    );
    contentController.text = initialHtml;
    _resetAnnotationHistory();

    titleController.addListener(_markChanged);
    quillController.addListener(_onQuillContentChanged);
  }

  /// A known representation conversion, not a guessed textual diff. HTML
  /// reading indices exclude line/paragraph separators while plain-text
  /// indices include them. Every other UTF-16 unit retains its exact order.
  List<ReadingAnnotation> _normalizeInitialAnnotationAnchors(
    String previousContent,
    String nextContent,
    List<ReadingAnnotation> notes,
  ) {
    if (notes.isEmpty) return const [];
    final before = AnnotationAnchors.bodyText(previousContent);
    final after = AnnotationAnchors.bodyText(nextContent);
    if (before == after) return AnnotationAnchors.validate(nextContent, notes);
    final withoutBreaks = before.replaceAll(RegExp(r'[\n\u2028]'), '');
    if (withoutBreaks != after) {
      // Unsupported external markup must still fail conservatively. It must
      // never borrow the position of another occurrence of the same words.
      return AnnotationAnchors.remap(previousContent, nextContent, notes);
    }
    final positions = List<int>.filled(before.length + 1, 0);
    var nextIndex = 0;
    for (var index = 0; index < before.length; index++) {
      positions[index] = nextIndex;
      final unit = before.codeUnitAt(index);
      if (unit != 0x0a && unit != 0x2028) nextIndex++;
    }
    positions[before.length] = nextIndex;
    return List.unmodifiable(
      notes.map((note) {
        if (!note.isAnchored) return note;
        final ranges = <AnnotationRange>[];
        for (final range in note.ranges) {
          if (!AnnotationAnchors.matches(before, range)) {
            return note.copyWith(unresolvedReason: '原文范围已失效，请重新选择字词');
          }
          final mapped = AnnotationRange(
            start: positions[range.start],
            end: positions[range.end],
            quote: range.quote.replaceAll(RegExp(r'[\n\u2028]'), ''),
          );
          if (!AnnotationAnchors.matches(after, mapped)) {
            return note.copyWith(unresolvedReason: '批注只对应换行或无法确认的原文，请重新选择字词');
          }
          ranges.add(mapped);
        }
        return note.copyWith(ranges: ranges);
      }),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _articleProvider = context.read<ArticleProvider>();
  }

  @override
  void dispose() {
    _disposingEditor = true;
    _autosaveTimer?.cancel();
    titleController.removeListener(_markChanged);
    quillController.removeListener(_onQuillContentChanged);
    if (autoSaveEnabled && isDirty && !_discardOnDispose) unawaited(save());
    titleController.dispose();
    contentController.dispose();
    findController.dispose();
    replaceController.dispose();
    editorFocusNode.dispose();
    findFocusNode.dispose();
    quillController.dispose();
    super.dispose();
  }

  void _onQuillContentChanged() {
    if (_syncingEditorContent) return;

    if (!identical(quillController.document, _annotationHistoryDocument)) {
      _resetAnnotationHistory();
    }
    final delta = quillController.document.toDelta();
    final rawHtml = _deltaToStorageHtml(delta);
    final html = _sanitizeStorageHtml(rawHtml);
    if (html != rawHtml) {
      _replaceEditorHtml(html);
      return;
    }
    if (html == contentController.text) {
      if (_annotationHistoryReplay == null) {
        _recordAnnotationEdit(_annotations, delta);
      }
      if (mounted) setState(() {});
      return;
    }

    final previousAnnotations = _annotations;
    if (_annotationHistoryReplay == null) {
      _annotations = AnnotationAnchors.remap(
        contentController.text,
        html,
        _annotations,
      );
    }
    _syncingEditorContent = true;
    contentController.value = TextEditingValue(
      text: html,
      selection: TextSelection.collapsed(offset: html.length),
    );
    _syncingEditorContent = false;
    if (_annotationHistoryReplay == null) {
      _recordAnnotationEdit(previousAnnotations, delta);
      _markChanged();
    }
  }

  void _resetAnnotationHistory() {
    _annotationHistory.clear();
    _annotationHistoryDocument = quillController.document;
    _rememberAnnotationHistory(quillController.document.toDelta());
  }

  void _rememberAnnotationHistory(qd.Delta delta) {
    final stack = quillController.document.history.stack;
    final active = Set<qd.Delta>.identity()
      ..addAll(stack.undo)
      ..addAll(stack.redo);
    _annotationHistory.removeWhere((entry, _) => !active.contains(entry));
    _knownAnnotationUndo = List.of(stack.undo);
    _lastAnnotationDocumentDelta = delta;
  }

  void _recordAnnotationEdit(
    List<ReadingAnnotation> previousAnnotations,
    qd.Delta delta,
  ) {
    final undo = quillController.document.history.stack.undo;
    final previousDelta = _lastAnnotationDocumentDelta;
    final oldTop = _knownAnnotationUndo.isEmpty
        ? null
        : _knownAnnotationUndo.last;
    final newTop = undo.isEmpty ? null : undo.last;
    if (newTop != null && !identical(newTop, oldTop) && previousDelta != null) {
      // A controller operation can contain several document operations. Check
      // the real undo target before associating an anchor snapshot with it.
      final target = delta.compose(newTop);
      Map<String, _AnnotationAnchorState>? before;
      if (target == previousDelta) {
        before = _captureAnnotationAnchors(previousAnnotations);
      } else if (oldTop != null &&
          undo.length == _knownAnnotationUndo.length &&
          _sameHistoryEntries(
            undo.take(undo.length - 1),
            _knownAnnotationUndo.take(_knownAnnotationUndo.length - 1),
          ) &&
          target == previousDelta.compose(oldTop)) {
        final previousRecord = _annotationHistory[oldTop];
        if (previousRecord != null) {
          final current = _captureAnnotationAnchors(previousAnnotations);
          before = {
            for (final entry in previousRecord.before.entries)
              // An explicit reattachment between two coalesced edits must not
              // inherit the old location of this note in the merged group.
              if (current[entry.key]?.sameAs(previousRecord.after[entry.key]) ??
                  false)
                entry.key: entry.value,
          };
        }
      }
      if (before != null) {
        _annotationHistory[newTop] = _AnnotationHistoryRecord(
          before: before,
          after: _captureAnnotationAnchors(_annotations),
        );
      }
    } else if (identical(newTop, oldTop) &&
        previousDelta != null &&
        delta != previousDelta) {
      // An unrecorded external mutation invalidates the provenance. Keep notes
      // conservative rather than reusing unrelated stack entries later.
      _annotationHistory.clear();
    }
    _rememberAnnotationHistory(delta);
  }

  void _performAnnotationHistoryReplay(bool redo, VoidCallback operation) {
    // Flush any controller operation which deliberately deferred its notify.
    _onQuillContentChanged();
    final document = quillController.document;
    final stack = document.history.stack;
    final source = redo ? stack.redo : stack.undo;
    if (source.isEmpty) {
      operation();
      return;
    }
    final replay = _AnnotationHistoryReplay(
      redo: redo,
      document: document,
      entry: source.last,
      undo: List.of(stack.undo),
      redoEntries: List.of(stack.redo),
      content: contentController.text,
      anchors: _captureAnnotationAnchors(_annotations),
    );
    _annotationHistoryReplay = replay;
    var succeeded = false;
    try {
      operation();
      succeeded = true;
    } finally {
      _finishAnnotationHistoryReplay(replay, succeeded: succeeded);
    }
  }

  void _finishAnnotationHistoryReplay(
    _AnnotationHistoryReplay replay, {
    required bool succeeded,
  }) {
    // The controller normally notifies synchronously after its document has
    // changed. Also cover a history operation whose notification was skipped.
    _onQuillContentChanged();
    _annotationHistoryReplay = null;
    final currentNotes = _annotations;
    final currentAnchors = _captureAnnotationAnchors(currentNotes);
    final stack = quillController.document.history.stack;
    final source = replay.redo ? stack.redo : stack.undo;
    final destination = replay.redo ? stack.undo : stack.redo;
    final previousSource = replay.redo ? replay.redoEntries : replay.undo;
    final previousDestination = replay.redo ? replay.undo : replay.redoEntries;
    final replayed =
        succeeded &&
        identical(quillController.document, replay.document) &&
        _sameHistoryEntries(
          source,
          previousSource.take(previousSource.length - 1),
        ) &&
        destination.length == previousDestination.length + 1 &&
        _sameHistoryEntries(
          destination.take(previousDestination.length),
          previousDestination,
        );
    final record = replayed ? _annotationHistory[replay.entry] : null;
    final expected = replay.redo ? record?.before : record?.after;
    final target = replay.redo ? record?.after : record?.before;
    final body = AnnotationAnchors.bodyText(contentController.text);
    final remapped = AnnotationAnchors.remap(
      replay.content,
      contentController.text,
      currentNotes,
    );
    _annotations = List.unmodifiable(
      remapped.map((note) {
        final current = currentAnchors[note.id];
        final restored = target?[note.id];
        if (current == null ||
            !(current.sameAs(expected?[note.id])) ||
            !(current.sameAs(replay.anchors[note.id])) ||
            restored == null ||
            !restored.canApplyTo(body)) {
          return note;
        }
        return restored.applyTo(note);
      }),
    );
    if (replayed) {
      final after = _captureAnnotationAnchors(_annotations);
      // Capture the actual inverse transition, including notes created after
      // the body edit. Undo retains those notes as pending; redo can then
      // restore their exact locations without reviving deleted notes.
      _annotationHistory[destination.last] = _AnnotationHistoryRecord(
        before: replay.redo ? currentAnchors : after,
        after: replay.redo ? after : currentAnchors,
      );
    } else {
      _annotationHistory.clear();
    }
    _rememberAnnotationHistory(quillController.document.toDelta());
    if (replay.content != contentController.text ||
        !_sameAnnotationAnchorLists(currentNotes, _annotations)) {
      _markChanged();
    } else if (mounted) {
      setState(() {});
    }
  }

  void _markChanged() {
    if (!mounted || _disposingEditor) return;
    _lastSaveFailed = false;
    _discardOnDispose = false;
    _editRevision++;
    setState(() => isDirty = true);
    _scheduleAutosave();
  }

  void _scheduleAutosave() {
    _autosaveTimer?.cancel();
    if (!autoSaveEnabled) return;
    _autosaveTimer = Timer(
      const Duration(milliseconds: 700),
      () => unawaited(save()),
    );
  }

  void flushAutosave() {
    _autosaveTimer?.cancel();
    if (autoSaveEnabled && isDirty && !_discardOnDispose) unawaited(save());
  }

  Future<Article?> save({bool force = false}) async {
    if (!force && !isDirty) return _savedArticle;
    final draft = _captureDraft();
    final activeSave = _saveOperation;
    if (activeSave != null) {
      _queuedDraft = draft;
      return activeSave;
    }

    final operation = _runSave(draft);
    _saveOperation = operation;
    try {
      return await operation;
    } finally {
      if (identical(_saveOperation, operation)) _saveOperation = null;
    }
  }

  Future<Article?> _runSave(_EditorDraft initialDraft) async {
    if (mounted && !_disposingEditor) setState(() {
      isSaving = true;
      _lastSaveFailed = false;
    });

    try {
      var draft = initialDraft;
      while (true) {
        _queuedDraft = null;
        if (_savedArticle == null &&
            draft.visibleCharacterCount == 0 &&
            draft.title.trim().isEmpty) {
          if (mounted && !_disposingEditor) setState(() => isDirty = false);
          return _savedArticle;
        }

        final title = _effectiveTitle(draft);
        final article = _savedArticle;
        Article? savedArticle;
        if (article == null) {
          savedArticle = await _articleProvider.createArticle(
            title: title,
            content: draft.content,
            annotations: draft.annotations,
            folderId: _saveFolderId,
            teleprompterSettings: draft.teleprompterSettings,
          );
        } else {
          savedArticle = await _articleProvider.updateArticle(
            article.id,
            title: title,
            content: draft.content,
            annotations: draft.annotations,
            teleprompterSettings: draft.teleprompterSettings,
          );
        }

        if (savedArticle == null) {
          if (mounted && !_disposingEditor) setState(() {
            isDirty = true;
            _lastSaveFailed = true;
          });
          return null;
        }
        _savedArticle = savedArticle;
        final queuedDraft = _queuedDraft;
        if (queuedDraft == null) {
          if (mounted && !_disposingEditor && _editRevision == draft.revision) {
            setState(() => isDirty = false);
          }
          return _savedArticle;
        }
        draft = queuedDraft;
      }
    } catch (e) {
      debugPrint('[Editor] autosave failed: $e');
      if (mounted && !_disposingEditor) setState(() {
        isDirty = true;
        _lastSaveFailed = true;
      });
      return null;
    } finally {
      if (mounted && !_disposingEditor) setState(() => isSaving = false);
    }
  }

  _EditorDraft _captureDraft() {
    final plainText = quillController.document.toPlainText();
    return _EditorDraft(
      title: titleController.text,
      plainText: plainText,
      content: contentController.text.trim(),
      visibleCharacterCount: TextParser.visibleCharacterCount(plainText),
      revision: _editRevision,
      annotations: AnnotationAnchors.validate(
        contentController.text,
        _annotations,
      ),
      teleprompterSettings: _draftTeleprompterSettings == null
          ? null
          : Map<String, dynamic>.unmodifiable(_draftTeleprompterSettings!),
    );
  }

  String _effectiveTitle(_EditorDraft draft) {
    final explicit = draft.title.trim();
    if (explicit.isNotEmpty) return explicit;
    final fallback = draft.plainText.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (fallback.isEmpty) return '无标题';
    return fallback.length > 30 ? fallback.substring(0, 30) : fallback;
  }

  Future<void> quickStartTeleprompter() async {
    if (plainTextLength == 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入可见的稿件正文')));
      return;
    }
    // 手动保存模式下直接使用内存快照，不因提词启动而落盘。
    final now = DateTime.now();
    final draft = _captureDraft();
    final article = autoSaveEnabled
        ? await save(force: true)
        : Article(
            id: _savedArticle?.id ?? 'quick-${identityHashCode(this)}',
            title: _effectiveTitle(draft),
            content: draft.content,
            annotations: draft.annotations,
            createdAt: now,
            updatedAt: now,
            teleprompterSettings: draft.teleprompterSettings,
          );
    if (!mounted) return;

    if (article == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存失败，当前修改仍保留在编辑器中，请重试后开始提词')),
      );
      return;
    }
    if (article.content.trim().isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请输入稿件正文')));
      return;
    }

    final teleprompterProvider = context.read<TeleprompterProvider>();
    final settingsProvider = context.read<SettingsProvider>();
    settingsProvider.loadArticleOverrides(article.teleprompterSettings);
    teleprompterProvider.loadScript(article.id, article.content);
    final connection = context.read<ConnectionProvider>();
    if (connection.isLocal && connection.isConnected) {
      connection.send(
        WsMessage(
          type: WsMessageType.teleprompterStartSession,
          data: {
            'articleId': article.id,
            'currentIndex': teleprompterProvider.currentIndex,
            'isPlaying': teleprompterProvider.isPlaying,
            'article': article.toJson(),
            'settings': settingsProvider.mergedSettings.toSessionMap(),
          },
        ),
      );
    }

    final initialSessionSettings = settingsProvider.mergedSettings.toTeleprompterMap();
    var lastSessionSettings = initialSessionSettings;
    void rememberSessionSettings() {
      final overrides = settingsProvider.articleOverrides;
      if (overrides.isNotEmpty) {
        lastSessionSettings = Map<String, dynamic>.from(overrides);
      }
    }
    settingsProvider.addListener(rememberSessionSettings);
    try {
      await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: teleprompterProvider),
            ChangeNotifierProvider.value(value: settingsProvider),
            ChangeNotifierProvider.value(value: _articleProvider),
          ],
          child: TeleprompterPage(
            article: article,
            persistArticleSettings: autoSaveEnabled || _savedArticle != null,
          ),
        ),
      ),
      );
    } finally {
      settingsProvider.removeListener(rememberSessionSettings);
    }
    if (mounted && !_sameTeleprompterSettings(
      initialSessionSettings, lastSessionSettings,
    )) {
      _draftTeleprompterSettings = lastSessionSettings;
      _markChanged();
    }
  }

  bool _sameTeleprompterSettings(
    Map<String, dynamic> first,
    Map<String, dynamic> second,
  ) => first.length == second.length && first.entries.every(
    (entry) => second.containsKey(entry.key) && second[entry.key] == entry.value,
  );

  void removeEmptyLines() {
    final updated = contentController.text
        .replaceAll(RegExp(r'<p>\s*</p>\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'(\r?\n)\s*(\r?\n)+'), '\n')
        .trim();
    _replaceEditorHtml(updated);
  }

  void addParagraphIndentation() {
    _replaceEditorHtml(
      _mapParagraphs(contentController.text, (body) {
        final clean = _removeLeadingIndent(body);
        return clean.trim().isEmpty ? clean : '\u3000\u3000$clean';
      }),
    );
  }

  void removeParagraphIndentation() {
    _replaceEditorHtml(
      _mapParagraphs(contentController.text, _removeLeadingIndent),
    );
  }

  void normalizeQuotePairs() {
    _replaceEditorHtml(_mapTextOutsideTags(contentController.text, _quoteText));
  }

  void applyFontSize(String value) {
    final parsed = double.tryParse(value.trim());
    if (parsed == null || parsed <= 0) return;
    quillController.formatSelection(
      quill.Attribute.fromKeyValue(quill.Attribute.size.key, parsed)!,
    );
    _onQuillContentChanged();
  }

  /// Only warn when an actual annotation range is entirely inside text whose
  /// explicit size makes its 22% note smaller than the 8px readability limit.
  /// A small, unrelated footer must not prompt a manuscript-wide change.
  bool get hasSmallAnnotationFontSize {
    if (annotationPreviewSettings.annotationFontSize != 0) return false;
    final content = contentController.text;
    if (_annotationFontNoticeContent == content &&
        identical(_annotationFontNoticeNotes, _annotations)) {
      return _annotationFontNotice;
    }
    _annotationFontNoticeContent = content;
    _annotationFontNoticeNotes = _annotations;
    _annotationFontNotice = false;
    final ranges = [
      for (final note in _annotations)
        if (note.isAnchored) ...note.ranges,
    ]..sort((left, right) => left.start.compareTo(right.start));
    if (ranges.isEmpty) return false;

    final smallSpans = <({int start, int end})>[];
    int? start;
    var end = 0;
    void finish() {
      if (start case final int first) {
        smallSpans.add((start: first, end: end));
      }
      start = null;
    }

    for (final line in TextParser.parse(content)) {
      for (final character in line.characters) {
        final size = character.fontSizePx;
        if (size != null && size > 0 && size * .22 < 8) {
          if (start != null && character.rawIndex != end) finish();
          start ??= character.rawIndex;
          end = character.rawIndex + character.char.length;
        } else {
          finish();
        }
      }
    }
    finish();
    var index = 0;
    for (final range in ranges) {
      while (index < smallSpans.length &&
          smallSpans[index].end <= range.start) {
        index++;
      }
      if (index == smallSpans.length) break;
      final span = smallSpans[index];
      if (range.start >= span.start &&
          range.end > range.start &&
          range.end <= span.end) {
        _annotationFontNotice = true;
        break;
      }
    }
    return _annotationFontNotice;
  }

  /// One explicit, undoable size-only operation over the whole manuscript.
  /// Keeping the existing document also keeps the user's selection and notes.
  void useTeleprompterFontSize() {
    final length = quillController.document.length - 1;
    if (length <= 0) return;
    final size = quill.Attribute.fromKeyValue(quill.Attribute.size.key, null)!;
    final history = quillController.document.history;
    // Do not merge this document-wide action with adjacent typing.
    history.lastRecorded = 0;
    try {
      quillController.formatText(0, length, size);
      if (quillController.toggledStyle.attributes.containsKey(size.key)) {
        quillController.forceToggledStyle(
          quillController.toggledStyle.put(size),
        );
      }
      _onQuillContentChanged();
    } finally {
      history.lastRecorded = 0;
    }
  }

  void showFindReplaceDialog({required bool replaceMode}) {
    setState(() {
      isFindReplaceVisible = true;
      isReplaceMode = replaceMode;
      findReplaceStatus = '';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) findFocusNode.requestFocus();
    });
  }

  void closeFindReplaceBar() {
    setState(() {
      isFindReplaceVisible = false;
      findReplaceStatus = '';
    });
    editorFocusNode.requestFocus();
  }

  void findNextMatch() {
    final index = _findNext(findController.text);
    setState(() {
      findReplaceStatus = index >= 0 ? '已定位到匹配项' : '没有找到匹配项';
    });
  }

  void replaceCurrentMatch() {
    final replaced = _replaceCurrent(
      findController.text,
      replaceController.text,
    );
    setState(() {
      findReplaceStatus = replaced ? '已替换当前匹配项' : '没有可替换的匹配项';
    });
  }

  void replaceAllMatches() {
    final count = _replaceAll(findController.text, replaceController.text);
    setState(() {
      findReplaceStatus = count > 0 ? '已替换 $count 处' : '没有可替换的匹配项';
    });
  }

  int _findNext(String query) {
    if (query.isEmpty) return -1;
    final text = quillController.document.toPlainText();
    final selection = quillController.selection;
    final start = selection.isValid ? selection.extentOffset : 0;
    var index = text.indexOf(query, start.clamp(0, text.length));
    if (index < 0 && start > 0) index = text.indexOf(query);
    if (index >= 0) {
      quillController.updateSelection(
        TextSelection(baseOffset: index, extentOffset: index + query.length),
        quill.ChangeSource.local,
      );
      editorFocusNode.requestFocus();
    }
    return index;
  }

  bool _replaceCurrent(String query, String replacement) {
    if (query.isEmpty) return false;
    final selection = quillController.selection;
    final text = quillController.document.toPlainText();
    final selected = selection.isValid && !selection.isCollapsed
        ? text.substring(
            selection.start.clamp(0, text.length),
            selection.end.clamp(0, text.length),
          )
        : '';
    if (selected != query && _findNext(query) < 0) return false;
    final current = quillController.selection;
    quillController.replaceText(
      current.start,
      current.end - current.start,
      replacement,
      TextSelection.collapsed(offset: current.start + replacement.length),
    );
    _onQuillContentChanged();
    return true;
  }

  int _replaceAll(String query, String replacement) {
    if (query.isEmpty) return 0;
    final text = quillController.document.toPlainText();
    final matches = query.allMatches(text).toList(growable: false);
    if (matches.isEmpty) return 0;
    for (final match in matches.reversed) {
      quillController.replaceText(
        match.start,
        match.end - match.start,
        replacement,
        TextSelection.collapsed(offset: match.start + replacement.length),
      );
    }
    _onQuillContentChanged();
    return matches.length;
  }

  void _replaceEditorHtml(String html) {
    if (_annotationHistoryReplay == null) {
      _annotations = AnnotationAnchors.remap(
        contentController.text,
        html,
        _annotations,
      );
    }
    _syncingEditorContent = true;
    quillController.document = quill.Document.fromDelta(_contentToDelta(html));
    contentController.value = TextEditingValue(
      text: html,
      selection: TextSelection.collapsed(offset: html.length),
    );
    _syncingEditorContent = false;
    _resetAnnotationHistory();
    if (_annotationHistoryReplay == null) _markChanged();
  }

  qd.Delta _contentToDelta(String content) {
    if (content.trim().isEmpty) {
      return qd.Delta()..insert('\n');
    }

    if (TextParser.isHtml(content)) {
      final storageDelta = _storageHtmlToDelta(content);
      if (storageDelta.operations.isNotEmpty) return storageDelta;
      try {
        final delta = HtmlToDelta().convert(content);
        if (delta.operations.isNotEmpty) return _sanitizeEditorDelta(delta);
      } catch (e) {
        debugPrint('[Editor] HTML to Delta failed: $e');
      }
    }

    final normalized = content.endsWith('\n') ? content : '$content\n';
    return qd.Delta()..insert(normalized);
  }

  qd.Delta _storageHtmlToDelta(String html) {
    final delta = qd.Delta();
    final paragraphPattern = RegExp(
      r'<(?:p|div|h[1-6])[^>]*>(.*?)</(?:p|div|h[1-6])>',
      caseSensitive: false,
      dotAll: true,
    );
    final matches = paragraphPattern.allMatches(html).toList();
    if (matches.isEmpty) return delta;

    for (final match in matches) {
      _appendInlineHtmlToDelta(delta, match.group(1) ?? '');
      delta.insert('\n');
    }
    return delta;
  }

  void _appendInlineHtmlToDelta(qd.Delta delta, String html) {
    final attributes = <String, dynamic>{};
    var cursor = 0;
    for (final match in RegExp(r'<[^>]+>').allMatches(html)) {
      if (match.start > cursor) {
        _insertDeltaText(
          delta,
          html.substring(cursor, match.start),
          attributes,
        );
      }
      final tag = match.group(0) ?? '';
      if (RegExp(r'^<br(?:\s|/?>)', caseSensitive: false).hasMatch(tag)) {
        // U+2028 is a visual line break inside a Quill paragraph. A normal
        // newline remains a paragraph boundary. Keeping these distinct also
        // preserves paragraph-wide reading colour after a save/reopen.
        delta.insert(
          '\u2028',
          attributes.isEmpty ? null : Map<String, dynamic>.from(attributes),
        );
      } else {
        _applyInlineTagToAttributes(tag, attributes);
      }
      cursor = match.end;
    }
    if (cursor < html.length) {
      _insertDeltaText(delta, html.substring(cursor), attributes);
    }
  }

  void _insertDeltaText(
    qd.Delta delta,
    String text,
    Map<String, dynamic> attributes,
  ) {
    // TextParser retains tabs and carriage returns as actual body characters.
    // A literal line feed inside a paragraph is its soft line break, not a
    // space. Do not silently rewrite imported words while opening the editor.
    final normalized = _decodeHtml(text).replaceAll('\n', '\u2028');
    if (normalized.isEmpty) return;
    delta.insert(
      normalized,
      attributes.isEmpty ? null : Map<String, dynamic>.from(attributes),
    );
  }

  void _applyInlineTagToAttributes(
    String rawTag,
    Map<String, dynamic> attributes,
  ) {
    final tag = rawTag.toLowerCase();
    final isClosing = tag.startsWith('</');
    final nameMatch = RegExp(r'</?\s*([a-z0-9]+)').firstMatch(tag);
    final name = nameMatch?.group(1);
    if (name == null) return;

    switch (name) {
      case 'br':
        return;
      case 'b':
      case 'strong':
        isClosing ? attributes.remove('bold') : attributes['bold'] = true;
        return;
      case 'i':
      case 'em':
        isClosing ? attributes.remove('italic') : attributes['italic'] = true;
        return;
      case 'u':
        isClosing
            ? attributes.remove('underline')
            : attributes['underline'] = true;
        return;
      case 's':
      case 'strike':
      case 'del':
        isClosing ? attributes.remove('strike') : attributes['strike'] = true;
        return;
      case 'span':
        if (isClosing) {
          attributes.remove('background');
          attributes.remove('color');
          attributes.remove('size');
        } else {
          final style = RegExp(
            r'''style\s*=\s*["']([^"']+)["']''',
            caseSensitive: false,
          ).firstMatch(rawTag)?.group(1);
          if (style != null) {
            final background =
                InlineStyleParser.color(style, 'background-color') ??
                InlineStyleParser.color(style, 'background');
            final color = InlineStyleParser.color(style, 'color');
            final size = RegExp(
              r'font-size\s*:\s*([^;]+)',
              caseSensitive: false,
            ).firstMatch(style)?.group(1)?.trim();
            if (background != null) attributes['background'] = background;
            if (color != null) attributes['color'] = color;
            final parsedSize = _fontSizeAttributeValue(size);
            if (parsedSize != null) attributes['size'] = parsedSize;
          }
        }
    }
  }

  String _deltaToStorageHtml(qd.Delta delta) {
    final paragraphs = <String>[];
    final current = StringBuffer();

    for (final operation in delta.operations) {
      if (!operation.isInsert || operation.data is! String) continue;

      final attributes = operation.attributes ?? const <String, dynamic>{};
      final text = operation.data as String;
      var start = 0;
      for (final separator in RegExp(r'[\n\u2028]').allMatches(text)) {
        if (separator.start > start) {
          current.write(
            _formatInlineHtml(
              text.substring(start, separator.start),
              attributes,
            ),
          );
        }
        if (separator.group(0) == '\u2028') {
          current.write('<br>');
        } else {
          paragraphs.add('<p>${current.toString()}</p>');
          current.clear();
        }
        start = separator.end;
      }
      if (start < text.length) {
        current.write(_formatInlineHtml(text.substring(start), attributes));
      }
    }

    if (current.isNotEmpty) paragraphs.add('<p>${current.toString()}</p>');
    return paragraphs.join('\n').trim();
  }

  String _formatInlineHtml(String text, Map<String, dynamic> attributes) {
    var result = const HtmlEscape(HtmlEscapeMode.element).convert(text);

    if (attributes['bold'] == true) result = '<b>$result</b>';
    if (attributes['italic'] == true) result = '<i>$result</i>';
    if (attributes['underline'] == true) result = '<u>$result</u>';
    if (attributes['strike'] == true) result = '<s>$result</s>';

    final styles = <String>[];
    final background = attributes['background'];
    final color = attributes['color'];
    final size = attributes['size'];
    if (background is String && background.isNotEmpty) {
      styles.add('background-color: $background');
    }
    if (color is String && color.isNotEmpty) {
      styles.add('color: $color');
    }
    if (size is num) {
      styles.add('font-size: ${_normalizeFontSize(size.toString())}');
    } else if (size is String && size.isNotEmpty) {
      styles.add('font-size: ${_normalizeFontSize(size)}');
    }
    if (styles.isNotEmpty) {
      result = '<span style="${styles.join('; ')}">$result</span>';
    }

    return result;
  }

  String _cleanPastedText(String text) {
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .where((line) => !_isSourceUrlLine(line))
        .join('\n');
  }

  qd.Delta _cleanPastedDelta(qd.Delta delta) {
    final cleaned = qd.Delta();
    for (final operation in delta.operations) {
      if (operation.isInsert && operation.data is String) {
        final text = _cleanPastedText(operation.data as String);
        if (text.isEmpty) continue;
        cleaned.insert(text, _sanitizeDeltaAttributes(operation.attributes));
      } else if (operation.isInsert) {
        cleaned.insert(
          operation.data,
          _sanitizeDeltaAttributes(operation.attributes),
        );
      } else {
        cleaned.push(operation);
      }
    }
    return cleaned;
  }

  String _sanitizeStorageHtml(String html) {
    final withoutParagraphs = html.replaceAll(
      RegExp(
        r'<p[^>]*>\s*(?:sourceurl|source url)\s*:?.*?</p>\s*',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );
    return withoutParagraphs
        .split(RegExp(r'\r?\n'))
        .where(
          (line) => !_isSourceUrlLine(line.replaceAll(RegExp(r'<[^>]+>'), '')),
        )
        .join('\n')
        .trim();
  }

  bool _isSourceUrlLine(String line) {
    return RegExp(
      r'^\s*(?:sourceurl|source\s+url)\s*:?.*$',
      caseSensitive: false,
    ).hasMatch(line.trim());
  }

  qd.Delta _sanitizeEditorDelta(qd.Delta delta) {
    final sanitized = qd.Delta();
    for (final operation in delta.operations) {
      if (operation.isInsert) {
        sanitized.insert(
          operation.data,
          _sanitizeDeltaAttributes(operation.attributes),
        );
      } else {
        sanitized.push(operation);
      }
    }
    return sanitized;
  }

  Map<String, dynamic>? _sanitizeDeltaAttributes(
    Map<String, dynamic>? attributes,
  ) {
    if (attributes == null || attributes.isEmpty) return attributes;
    final sanitized = Map<String, dynamic>.from(attributes);
    final size = sanitized['size'];
    if (size != null) {
      final normalized = size is num
          ? size.toDouble()
          : _fontSizeAttributeValue(size.toString());
      if (normalized == null || normalized <= 0) {
        sanitized.remove('size');
      } else {
        sanitized['size'] = normalized;
      }
    }
    return sanitized.isEmpty ? null : sanitized;
  }

  String _decodeHtml(String text) => TextParser.decodeHtmlEntities(text);

  String _normalizeFontSize(String value) {
    final trimmed = value.trim().toLowerCase();
    final match = RegExp(
      r'^(\d+(?:\.\d+)?)(px|pt|em|rem)?$',
    ).firstMatch(trimmed);
    if (match == null) return value;
    final parsed = double.tryParse(match.group(1) ?? '');
    if (parsed == null || parsed <= 0) return value;
    final unit = match.group(2) ?? 'px';
    final display = parsed.truncateToDouble() == parsed
        ? parsed.toStringAsFixed(0)
        : parsed.toStringAsFixed(1);
    return '$display$unit';
  }

  double? _fontSizeAttributeValue(String? value) {
    if (value == null) return null;
    final normalized = value.trim().toLowerCase();
    switch (normalized) {
      case 'small':
        return 13;
      case 'normal':
        return 16;
      case 'large':
        return 24;
      case 'huge':
        return 32;
    }

    final match = RegExp(
      r'^(\d+(?:\.\d+)?)(px|pt|em|rem)?$',
    ).firstMatch(normalized);
    if (match == null) return null;
    final number = double.tryParse(match.group(1) ?? '');
    if (number == null || number <= 0) return null;
    final unit = match.group(2);
    if (unit == 'pt') return number * 96 / 72;
    if (unit == 'em' || unit == 'rem') return number * 16;
    return number;
  }

  String _mapParagraphs(String html, String Function(String body) mapper) {
    final pattern = RegExp(r'<p>(.*?)</p>', caseSensitive: false, dotAll: true);
    if (!pattern.hasMatch(html)) {
      return html.split('\n').map(mapper).join('\n');
    }
    return html.replaceAllMapped(
      pattern,
      (match) => '<p>${mapper(match.group(1) ?? '')}</p>',
    );
  }

  String _removeLeadingIndent(String text) {
    return text.replaceFirst(RegExp(r'^(?:\s|　|&nbsp;)+'), '');
  }

  String _mapTextOutsideTags(String html, String Function(String text) mapper) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final match in RegExp(r'<[^>]+>').allMatches(html)) {
      if (match.start > cursor) {
        buffer.write(mapper(html.substring(cursor, match.start)));
      }
      buffer.write(match.group(0));
      cursor = match.end;
    }
    if (cursor < html.length) buffer.write(mapper(html.substring(cursor)));
    return buffer.toString();
  }

  String _quoteText(String text) {
    final decoded = TextParser.decodeHtmlEntities(text);
    final normalized = TextParser.normalizeQuotePairs(decoded);
    return TextParser.encodeHtmlEntities(normalized);
  }
}

/// Only explicit controller history actions may recover an invalidated anchor.
/// Ordinary typing, even when it recreates identical text, never takes this path.
class _AnnotationQuillController extends quill.QuillController {
  _AnnotationQuillController({
    required super.document,
    required super.selection,
    required super.config,
    required this.onHistoryReplay,
  });

  final void Function(bool redo, VoidCallback operation) onHistoryReplay;

  @override
  void undo() => onHistoryReplay(false, () => super.undo());

  @override
  void redo() => onHistoryReplay(true, () => super.redo());
}

class _AnnotationAnchorState {
  _AnnotationAnchorState(ReadingAnnotation note)
    : ranges = List.unmodifiable(note.ranges),
      unresolvedReason = note.unresolvedReason;

  final List<AnnotationRange> ranges;
  final String? unresolvedReason;

  bool sameAs(_AnnotationAnchorState? other) {
    if (other == null ||
        unresolvedReason != other.unresolvedReason ||
        ranges.length != other.ranges.length) {
      return false;
    }
    for (var index = 0; index < ranges.length; index++) {
      final left = ranges[index];
      final right = other.ranges[index];
      if (left.start != right.start ||
          left.end != right.end ||
          left.quote != right.quote) {
        return false;
      }
    }
    return true;
  }

  bool canApplyTo(String body) =>
      unresolvedReason != null ||
      ranges.every((range) => AnnotationAnchors.matches(body, range));

  ReadingAnnotation applyTo(ReadingAnnotation current) => current.copyWith(
    ranges: ranges,
    unresolvedReason: unresolvedReason,
    clearUnresolvedReason: unresolvedReason == null,
  );
}

Map<String, _AnnotationAnchorState> _captureAnnotationAnchors(
  List<ReadingAnnotation> notes,
) {
  final anchors = <String, _AnnotationAnchorState>{};
  final seen = <String>{};
  for (final note in notes) {
    if (note.id.isEmpty) continue;
    if (!seen.add(note.id)) {
      // Malformed imported duplicate IDs cannot identify a unique note.
      anchors.remove(note.id);
      continue;
    }
    anchors[note.id] = _AnnotationAnchorState(note);
  }
  return anchors;
}

bool _sameAnnotationAnchorLists(
  List<ReadingAnnotation> before,
  List<ReadingAnnotation> after,
) {
  if (before.length != after.length) return false;
  for (var index = 0; index < before.length; index++) {
    if (before[index].id != after[index].id ||
        !_AnnotationAnchorState(
          before[index],
        ).sameAs(_AnnotationAnchorState(after[index]))) {
      return false;
    }
  }
  return true;
}

bool _sameHistoryEntries(Iterable<qd.Delta> left, Iterable<qd.Delta> right) {
  final leftIterator = left.iterator;
  final rightIterator = right.iterator;
  while (leftIterator.moveNext()) {
    if (!rightIterator.moveNext() ||
        !identical(leftIterator.current, rightIterator.current)) {
      return false;
    }
  }
  return !rightIterator.moveNext();
}

class _AnnotationHistoryRecord {
  const _AnnotationHistoryRecord({required this.before, required this.after});

  final Map<String, _AnnotationAnchorState> before;
  final Map<String, _AnnotationAnchorState> after;
}

class _AnnotationHistoryReplay {
  const _AnnotationHistoryReplay({
    required this.redo,
    required this.document,
    required this.entry,
    required this.undo,
    required this.redoEntries,
    required this.content,
    required this.anchors,
  });

  final bool redo;
  final quill.Document document;
  final qd.Delta entry;
  final List<qd.Delta> undo;
  final List<qd.Delta> redoEntries;
  final String content;
  final Map<String, _AnnotationAnchorState> anchors;
}

class _EditorDraft {
  const _EditorDraft({
    required this.title,
    required this.plainText,
    required this.content,
    required this.visibleCharacterCount,
    required this.revision,
    this.annotations = const [],
    this.teleprompterSettings,
  });

  final String title;
  final String plainText;
  final String content;
  final int visibleCharacterCount;
  final int revision;
  final List<ReadingAnnotation> annotations;
  final Map<String, dynamic>? teleprompterSettings;
}
