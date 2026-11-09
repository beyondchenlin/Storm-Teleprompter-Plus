part of '../editor_page.dart';

/// Selection-based coaching notes, including repair of imported unbound notes.
mixin EditorAnnotations on State<EditorPage>, EditorLogic {
  AnnotationRange? _selectedAnnotationRange() {
    // Commit the editor's normalized body before translating its newline-based
    // selection offsets into the teleprompter's newline-free HTML offsets.
    _onQuillContentChanged();
    final selection = quillController.selection;
    final plain = quillController.document.toPlainText();
    if (!selection.isValid || selection.isCollapsed ||
        selection.end > plain.length) return null;
    final start = plain.substring(0, selection.start).replaceAll('\n', '').length;
    final quote = plain.substring(selection.start, selection.end).replaceAll('\n', '');
    if (quote.trim().isEmpty) return null;
    final range = AnnotationRange(start: start, end: start + quote.length, quote: quote);
    return AnnotationAnchors.matches(AnnotationAnchors.bodyText(contentController.text), range)
        ? range : null;
  }

  Future<String?> _editAnnotationText({String text = '', String? quote}) async {
    final controller = TextEditingController(text: text);
    try {
      return await showSettledDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('朗读批注'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (quote != null) Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('对应原文：$quote', maxLines: 3, overflow: TextOverflow.ellipsis),
                ),
                TextField(
                  key: const ValueKey('annotation-text-input'),
                  controller: controller,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 5,
                  maxLength: 2000,
                  decoration: const InputDecoration(
                    labelText: '批注内容',
                    hintText: '例如：重读、停一秒、放慢语速',
                    helperText: '提词时在字词上方显示；长备注可点击查看全文',
                    helperMaxLines: 2,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('先在正文中选中需要重读、停顿或提示的字词')),
      );
      return;
    }
    final value = await _editAnnotationText(quote: range.quote);
    if (!mounted || value == null) return;
    _annotations = [..._annotations, ReadingAnnotation(
      id: 'manual-${DateTime.now().microsecondsSinceEpoch}', text: value, ranges: [range],
    )];
    _markChanged();
  }

  void _selectAnnotation(ReadingAnnotation note) {
    if (!note.isAnchored) return;
    final range = note.ranges.first;
    final plain = quillController.document.toPlainText();
    int editorOffset(int raw) {
      var counted = 0;
      for (var i = 0; i < plain.length; i++) {
        if (plain[i] == '\n') continue;
        if (counted == raw) return i;
        counted++;
      }
      return plain.length - 1;
    }
    quillController.updateSelection(
      TextSelection(baseOffset: editorOffset(range.start), extentOffset: editorOffset(range.end)),
      quill.ChangeSource.local,
    );
    editorFocusNode.requestFocus();
  }

  Future<void> manageAnnotations() async {
    final selection = _selectedAnnotationRange();
    final locate = await showSettledDialog<ReadingAnnotation>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(builder: (context, updateDialog) {
        void updateNotes(List<ReadingAnnotation> notes) {
          _annotations = notes;
          _markChanged();
          updateDialog(() {});
        }
        final pending = _annotations.where((note) => !note.isAnchored).length;
        return AlertDialog(
          title: Text('批注管理 · ${_annotations.length} 条${pending == 0 ? '' : ' · $pending 条待定位'}'),
          content: SizedBox(
            width: 580,
            height: MediaQuery.sizeOf(context).height * .55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(selection == null
                    ? '添加或重新定位：先关闭此窗口，在正文选中字词，再打开批注管理。'
                    : '当前选中：${selection.quote}', maxLines: 3, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 12),
                Expanded(child: _annotations.isEmpty
                  ? const Center(child: Text('暂无批注。选中正文后，点击“添加批注”。'))
                  : ListView.separated(
                      itemCount: _annotations.length,
                      separatorBuilder: (_, _) => const Divider(),
                      itemBuilder: (context, index) {
                        final note = _annotations[index];
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(note.ranges.isEmpty ? '尚未绑定原文' : '原文：${note.ranges.map((r) => r.quote).join(' / ')}',
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                            const SizedBox(height: 4),
                            SelectableText(note.text.isEmpty ? '（原文件未提供批注文字）' : note.text),
                            if (!note.isAnchored) Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(note.unresolvedReason ?? '请选中对应字词后绑定',
                                style: TextStyle(color: Theme.of(context).colorScheme.error)),
                            ),
                            Wrap(spacing: 4, children: [
                              if (note.isAnchored) TextButton(
                                onPressed: () => Navigator.pop(dialogContext, note), child: const Text('定位原文')),
                              TextButton(
                                onPressed: selection == null ? null : () {
                                  updateNotes([for (final item in _annotations)
                                    if (identical(item, note)) item.copyWith(ranges: [selection], clearUnresolvedReason: true) else item]);
                                }, child: const Text('绑定到所选字词')),
                              TextButton(onPressed: () async {
                                final value = await _editAnnotationText(text: note.text,
                                  quote: note.ranges.map((r) => r.quote).join(' / '));
                                if (!mounted || !dialogContext.mounted || value == null) return;
                                updateNotes([for (final item in _annotations)
                                  if (identical(item, note)) item.copyWith(text: value) else item]);
                              }, child: const Text('编辑')),
                              TextButton(onPressed: () => updateNotes(
                                _annotations.where((item) => !identical(item, note)).toList()),
                                child: const Text('删除')),
                            ]),
                          ],
                        );
                      },
                    )),
              ],
            ),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('完成'))],
        );
      }),
    );
    if (mounted && locate != null) _selectAnnotation(locate);
  }
}
