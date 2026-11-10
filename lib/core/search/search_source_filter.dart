import '../source/source_picker_groups.dart';
import '../session/section.dart';
import '../source/data_source.dart';
import '../source/source_content_category.dart';
import '../source/source_content_rating.dart';

enum SearchContentGroup {
  all('全部内容'),
  movie('影视'),
  adult('成人'),
  comic('漫画'),
  audio('听书'),
  novel('小说'),
  photo('美图'),
  mixed('综合'),
  other('待分类');

  const SearchContentGroup(this.label);
  final String label;
}

enum SearchSourceKind {
  all('全部类型'),
  js('JS源'),
  python('PY源'),
  cat('猫源');

  const SearchSourceKind(this.label);
  final String label;
}

/// Content and interpreter are separate facets: e.g. PY × 影视 or JS × 成人.
class SearchSourceFilter {
  const SearchSourceFilter({
    this.content = SearchContentGroup.all,
    this.kind = SearchSourceKind.all,
  });
  final SearchContentGroup content;
  final SearchSourceKind kind;
  SearchSourceFilter copyWith({
    SearchContentGroup? content,
    SearchSourceKind? kind,
  }) => SearchSourceFilter(
    content: content ?? this.content,
    kind: kind ?? this.kind,
  );
  bool matches(SourceDescriptor source) =>
      (content == SearchContentGroup.all || contentOf(source) == content) &&
      (kind == SearchSourceKind.all || kindOf(source) == kind);

  static SearchSourceKind kindOf(SourceDescriptor source) =>
      source.runtimeKind == 'python'
      ? SearchSourceKind.python
      : source.runtimeKind == 'cat' ||
            source.isTvBox ||
            source.section == Section.cat
      ? SearchSourceKind.cat
      : SearchSourceKind.js;

  static SearchContentGroup contentOf(SourceDescriptor source) {
    final category = source.section == Section.comic
        ? SourceContentCategory.fromId(source.contentCategory)
        : SourceContentCategories.forSource(source);
    if (category == SourceContentCategory.adult ||
        source.group == '成人' ||
        source.section == Section.comic &&
            SourceContentRating.isAdult(source.id, source.name)) {
      return SearchContentGroup.adult;
    }
    final media = source.mediaKind.isNotEmpty
        ? source.mediaKind
        : SourcePickerGroups.groupFor(source.section ?? Section.video, source);
    if (source.isAudio || media == 'audiobook') return SearchContentGroup.audio;
    if (media == 'novel') return SearchContentGroup.novel;
    if (media == 'photo') return SearchContentGroup.photo;
    if (source.mixedContent || category == SourceContentCategory.mixed) {
      return SearchContentGroup.mixed;
    }
    if (source.mediaKind == 'comic' || source.section == Section.comic) {
      return SearchContentGroup.comic;
    }
    if (category == SourceContentCategory.movie ||
        source.mediaKind == 'video' && kindOf(source) == SearchSourceKind.cat) {
      return SearchContentGroup.movie;
    }
    return SearchContentGroup.other;
  }
}
