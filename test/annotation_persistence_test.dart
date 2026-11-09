import 'package:flutter_test/flutter_test.dart';
import 'package:storm_teleprompter_plus/backend/article_service.dart';
import 'package:storm_teleprompter_plus/models/reading_annotation.dart';
import 'package:storm_teleprompter_plus/services/app_preferences.dart';

class _MemoryPreferences implements AppPreferences {
  final Map<String, String> data = {};
  bool fail = false;
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    if (fail) return false;
    data[key] = value;
    return true;
  }
}

void main() {
  const notes = [ReadingAnnotation(id: 'one', text: '重读',
    ranges: [AnnotationRange(start: 2, end: 3, quote: '不')])];

  test('atomic note/body writes survive reload, title edits and folder copies', () async {
    final preferences = _MemoryPreferences();
    final service = ArticleService(preferences: preferences);
    await service.init();
    final folder = await service.createFolder(name: '测试');
    final article = await service.createArticle(title: '示例', content: '<p>学习不是记住</p>',
      annotations: notes, folderId: folder.id);
    await service.updateArticle(article.id, title: '新标题');
    final copied = await service.copyFolder(folder.id, null);
    expect(copied!.articles.single.annotations.single.ranges.single.quote, '不');
    final second = ArticleService(preferences: preferences);
    await second.init();
    final reloaded = (await second.loadArticles()).firstWhere((item) => item.id == article.id);
    expect(reloaded.annotations.single.text, '重读');
    expect(reloaded.title, '新标题');
    final shifted = await second.updateArticle(article.id, content: '<p>今天学习不是记住</p>');
    expect(shifted!.annotations.single.ranges.single.start, 4);
    expect(shifted.annotations.single.isAnchored, isTrue);
  });

  test('a failed atomic save retains both the previous text and annotations', () async {
    final preferences = _MemoryPreferences();
    final service = ArticleService(preferences: preferences);
    await service.init();
    final article = await service.createArticle(title: '示例', content: '<p>学习不是记住</p>', annotations: notes);
    preferences.fail = true;
    await expectLater(service.updateArticle(article.id, content: '<p>新稿</p>', annotations: []), throwsStateError);
    final stored = (await service.loadArticles()).single;
    expect(stored.content, article.content);
    expect(stored.annotations.single.text, '重读');
  });
}
