import '../js/source_script.dart';
import '../session/section.dart';
import 'source_package.dart';
import 'source_media_hints.dart';
import 'source_content_category.dart';

/// One routing policy for local imports and repository uploads. No code execution.
abstract final class SourceImportRouting {
  static Section section(String script, {Section fallback = Section.video}) {
    final prepared = SourcePackage.prepare(script);
    final metadata = SourceMetadata.parseHeader(prepared);
    if (metadata == null) return fallback;
    final candidates = Section.values
        .where((s) => metadata.sectionMismatch(s, script: prepared) == null)
        .toList();
    return candidates.length == 1 ? candidates.single : fallback;
  }

  static String repositoryKind(String script, {String fallback = 'video'}) {
    final metadata = SourceMetadata.parseHeader(script);
    final hint = SourceMediaHints.fromScript(script);
    if (hint == 'audio' ||
        metadata?.category == 'audiobook' ||
        SourceMediaHints.audioLabel('${metadata?.id} ${metadata?.name}')) {
      return 'audiobook';
    }
    if (hint == 'novel') return 'novel';
    if (hint == 'photo') return 'photo';
    if (section(script) == Section.comic) return 'comic';
    if (SourceContentCategories.fromScript(script) == 'movie') return 'movie';
    if (metadata?.category == 'video' ||
        SourceContentCategories.fromScript(script) == 'adult') {
      return 'video';
    }
    return fallback;
  }
}
