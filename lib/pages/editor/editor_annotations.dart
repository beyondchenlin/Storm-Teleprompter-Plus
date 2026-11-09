part of '../editor_page.dart';

/// Selection-based coaching notes, including repair of imported unbound notes.
mixin EditorAnnotations on State<EditorPage>, EditorLogic {
  bool showAnnotationPreview = true;
  String? _previewAnnotationId;

  void toggleAnnotationPreview() =>
      setState(() => showAnnotationPreview = !showAnnotationPreview);

  ReadingAnnotation? get _focusedPreviewNote =>
      _annotations
          .where((note) => note.id == _previewAnnotationId && note.isAnchored)
          .firstOrNull ??
      _annotations.where((note) => note.isAnchored).firstOrNull;

  Future<void> editExistingAnnotation(ReadingAnnotation note) async {
    _previewAnnotationId = note.id;
    final text = await _editAnnotationText(
      text: note.text,
      quote: note.ranges.map((range) => range.quote).join(' / '),
      ranges: note.isAnchored ? note.ranges : const [],
      editingId: note.id,
    );
    if (!mounted || text == null) return;
    _annotations = [
      for (final item in _annotations)
        if (item.id == note.id) item.copyWith(text: text) else item,
    ];
    _markChanged();
  }

  Widget _annotationPreviewPanel() => Column(
    children: [
      SizedBox(
        height: 34,
        child: Row(
          children: [
            const SizedBox(width: 12),
            const Expanded(
              child: Text('提词效果 · 点击框选字词可修改批注', style: TextStyle(fontSize: 12)),
            ),
            IconButton(
              tooltip: '收起预览',
              iconSize: 18,
              onPressed: toggleAnnotationPreview,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      ),
      SizedBox(
        height: 36,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          children: [
            for (final note in _annotations)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: ActionChip(
                  visualDensity: VisualDensity.compact,
                  avatar: Icon(
                    note.isAnchored
                        ? Icons.comment_outlined
                        : Icons.error_outline,
                    size: 14,
                  ),
                  label: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      note.isAnchored
                          ? '${note.ranges.map((range) => range.quote).join(' / ')} · ${note.text}'
                          : '待定位 · ${note.text}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  onPressed: () {
                    if (!note.isAnchored) {
                      unawaited(manageAnnotations());
                      return;
                    }
                    setState(() => _previewAnnotationId = note.id);
                    _selectAnnotation(note);
                  },
                ),
              ),
          ],
        ),
      ),
      Expanded(
        child: LayoutBuilder(
          builder: (context, constraints) => ReadingAnnotationPreview(
            content: contentController.text,
            annotations: _focusedPreviewNote == null
                ? const []
                : [_focusedPreviewNote!],
            focusRawIndex: _focusedPreviewNote?.ranges.first.start,
            height: constraints.maxHeight,
            onNoteTap: editExistingAnnotation,
          ),
        ),
      ),
    ],
  );

  Widget buildAnnotationWorkspace(Widget editor) => LayoutBuilder(
    builder: (context, constraints) {
      if (_annotations.isEmpty || !showAnnotationPreview) return editor;
      if (constraints.maxWidth >= 1040 && constraints.maxHeight >= 300) {
        return Row(
          children: [
            Expanded(child: editor),
            const VerticalDivider(width: 1),
            SizedBox(width: 440, child: _annotationPreviewPanel()),
          ],
        );
      }
      if (constraints.maxHeight >= 380) {
        return Column(
          children: [
            Expanded(child: editor),
            const Divider(height: 1),
            SizedBox(height: 230, child: _annotationPreviewPanel()),
          ],
        );
      }
      return Column(
        children: [
          Expanded(child: editor),
          TextButton.icon(
            onPressed: _showCompactAnnotationPreview,
            icon: const Icon(Icons.preview_outlined),
            label: Text('查看 ${_annotations.length} 条批注的提词效果'),
          ),
        ],
      );
    },
  );

  Future<void> _showCompactAnnotationPreview() async {
    final note = _focusedPreviewNote;
    if (note == null) {
      await manageAnnotations();
      return;
    }
    final selected = await showDialog<ReadingAnnotation>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('提词效果局部预览'),
        content: SizedBox(
          width: 680,
          child: ReadingAnnotationPreview(
            content: contentController.text,
            annotations: [note],
            focusRawIndex: note.ranges.first.start,
            height: MediaQuery.sizeOf(context).height * .5,
            onNoteTap: (item) => Navigator.pop(context, item),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, note),
            child: const Text('编辑批注'),
          ),
        ],
      ),
    );
    if (mounted && selected != null) await editExistingAnnotation(selected);
  }

  AnnotationRange? _selectedAnnotationRange() {
    // Commit the editor's normalized body before translating its newline-based
    // selection offsets into the teleprompter's newline-free HTML offsets.
    _onQuillContentChanged();
    final selection = quillController.selection;
    final plain = quillController.document.toPlainText();
    if (!selection.isValid ||
        selection.isCollapsed ||
        selection.end > plain.length)
      return null;
    final start = plain
        .substring(0, selection.start)
        .replaceAll(RegExp(r'[\n\u2028]'), '')
        .length;
    final quote = plain
        .substring(selection.start, selection.end)
        .replaceAll(RegExp(r'[\n\u2028]'), '');
    if (quote.trim().isEmpty) return null;
    final range = AnnotationRange(
      start: start,
      end: start + quote.length,
      quote: quote,
    );
    return AnnotationAnchors.matches(
          AnnotationAnchors.bodyText(contentController.text),
          range,
        )
        ? range
        : null;
  }

  Future<String?> _editAnnotationText({
    String text = '',
    String? quote,
    List<AnnotationRange> ranges = const [],
    String? editingId,
  }) async {
    final controller = TextEditingController(text: text);
    try {
      return await showSettledDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('朗读批注'),
          scrollable: true,
          content: SizedBox(
            width: 680,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (quote != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '对应原文：$quote',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                TextField(
                  key: const ValueKey('annotation-text-input'),
                  controller: controller,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: '批注内容',
                    hintText: '例如：重读、停一秒、放慢语速',
                    helperText: '提词时在字词上方显示；长备注只缩略显示，全文会完整保存',
                    helperMaxLines: 2,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final cue in ['重读', '停一秒', '放慢语速', '语气上扬'])
                      ActionChip(
                        label: Text(cue),
                        onPressed: () {
                          controller.text = cue;
                          controller.selection = TextSelection.collapsed(
                            offset: cue.length,
                          );
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                if (ranges.isNotEmpty) ...[
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('实时局部预览', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(height: 6),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: controller,
                    builder: (context, value, _) => ReadingAnnotationPreview(
                      key: const ValueKey('live-annotation-preview'),
                      content: contentController.text,
                      annotations: [
                        ReadingAnnotation(
                          id: 'preview-draft',
                          text: value.text,
                          ranges: ranges,
                        ),
                      ],
                      onNoteTap: (_) {},
                      focusRawIndex: ranges.first.start,
                      height: 190,
                    ),
                  ),
                ] else
                  const Text('绑定到原文字词后，这里会显示提词效果。'),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isNotEmpty) Navigator.pop(dialogContext, value);
              },
              child: const Text('保存批注'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  Future<void> addAnnotation() async {
    final range = _selectedAnnotationRange();
    if (range == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('先在正文中选中需要重读、停顿或提示的字词')));
      return;
    }
    final value = await _editAnnotationText(
      quote: range.quote,
      ranges: [range],
    );
    if (!mounted || value == null) return;
    _previewAnnotationId = 'manual-${DateTime.now().microsecondsSinceEpoch}';
    showAnnotationPreview = true;
    _annotations = [
      ..._annotations,
      ReadingAnnotation(
        id: _previewAnnotationId!,
        text: value,
        ranges: [range],
      ),
    ];
    _markChanged();
  }

  void _selectAnnotation(ReadingAnnotation note) {
    if (!note.isAnchored) return;
    final range = note.ranges.first;
    final plain = quillController.document.toPlainText();
    int editorOffset(int raw) {
      var counted = 0;
      for (var i = 0; i < plain.length; i++) {
        if (plain[i] == '\n' || plain[i] == '\u2028') continue;
        if (counted == raw) return i;
        counted++;
      }
      return plain.length - 1;
    }

    quillController.updateSelection(
      TextSelection(
        baseOffset: editorOffset(range.start),
        extentOffset: editorOffset(range.end),
      ),
      quill.ChangeSource.local,
    );
    editorFocusNode.requestFocus();
  }

  Future<void> manageAnnotations() async {
    final selection = _selectedAnnotationRange();
    final locate = await showSettledDialog<ReadingAnnotation>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, updateDialog) {
          void updateNotes(List<ReadingAnnotation> notes) {
            _annotations = notes;
            _markChanged();
            updateDialog(() {});
          }

          final pending = _annotations.where((note) => !note.isAnchored).length;
          return AlertDialog(
            title: Text(
              '批注管理 · ${_annotations.length} 条${pending == 0 ? '' : ' · $pending 条待定位'}',
            ),
            content: SizedBox(
              width: 580,
              height: MediaQuery.sizeOf(context).height * .55,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    selection == null
                        ? '添加或重新定位：先关闭此窗口，在正文选中字词，再打开批注管理。'
                        : '当前选中：${selection.quote}',
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: _annotations.isEmpty
                        ? const Center(child: Text('暂无批注。选中正文后，点击“添加批注”。'))
                        : ListView.separated(
                            itemCount: _annotations.length,
                            separatorBuilder: (_, _) => const Divider(),
                            itemBuilder: (context, index) {
                              final note = _annotations[index];
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    note.ranges.isEmpty
                                        ? '尚未绑定原文'
                                        : '原文：${note.ranges.map((r) => r.quote).join(' / ')}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  SelectableText(
                                    note.text.isEmpty
                                        ? '（原文件未提供批注文字）'
                                        : note.text,
                                  ),
                                  if (!note.isAnchored)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 4),
                                      child: Text(
                                        note.unresolvedReason ?? '请选中对应字词后绑定',
                                        style: TextStyle(
                                          color: Theme.of(
                                            context,
                                          ).colorScheme.error,
                                        ),
                                      ),
                                    ),
                                  Wrap(
                                    spacing: 4,
                                    children: [
                                      if (note.isAnchored)
                                        TextButton(
                                          onPressed: () => Navigator.pop(
                                            dialogContext,
                                            note,
                                          ),
                                          child: const Text('定位原文'),
                                        ),
                                      TextButton(
                                        onPressed: selection == null
                                            ? null
                                            : () {
                                                updateNotes([
                                                  for (final item
                                                      in _annotations)
                                                    if (identical(item, note))
                                                      item.copyWith(
                                                        ranges: [selection],
                                                        clearUnresolvedReason:
                                                            true,
                                                      )
                                                    else
                                                      item,
                                                ]);
                                              },
                                        child: const Text('绑定到所选字词'),
                                      ),
                                      TextButton(
                                        onPressed: () async {
                                          final value =
                                              await _editAnnotationText(
                                                text: note.text,
                                                quote: note.ranges
                                                    .map((r) => r.quote)
                                                    .join(' / '),
                                                ranges: note.isAnchored
                                                    ? note.ranges
                                                    : const [],
                                                editingId: note.id,
                                              );
                                          if (!mounted ||
                                              !dialogContext.mounted ||
                                              value == null)
                                            return;
                                          updateNotes([
                                            for (final item in _annotations)
                                              if (identical(item, note))
                                                item.copyWith(text: value)
                                              else
                                                item,
                                          ]);
                                        },
                                        child: const Text('编辑'),
                                      ),
                                      TextButton(
                                        onPressed: () => updateNotes(
                                          _annotations
                                              .where(
                                                (item) =>
                                                    !identical(item, note),
                                              )
                                              .toList(),
                                        ),
                                        child: const Text('删除'),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('完成'),
              ),
            ],
          );
        },
      ),
    );
    if (mounted && locate != null) _selectAnnotation(locate);
  }
}
