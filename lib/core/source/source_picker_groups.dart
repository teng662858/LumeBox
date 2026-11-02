import 'source_entry_order.dart';
import '../session/section.dart';
import 'source.dart';
import 'source_preferences.dart';

/// Display grouping never changes a source's section, ID or runtime.
class SourcePickerGroups {
  static const orderKey = 'source.picker.groupOrder';
  static List<(String, String)> forSection(Section section) =>
      SourceEntryOrder.read(section, orderKey, defaults(section));
  static List<(String, String)> defaults(Section section) => switch (section) {
    Section.comic => [
      ('comic', '漫画'),
      ('photo', '美图'),
      ('novel', '小说'),
      ('audiobook', '有声'),
      ('kazumi', 'Kazumi'),
    ],
    Section.video => [('video', '视频'), ('movie', '影视'), ('tvbox', 'TVBOX')],
    Section.cat => [('cat', '猫源')],
  };

  static String groupFor(Section section, SourceDescriptor source) {
    final groups = forSection(section);
    final saved = SourcePreferences.read(section, source.id).pickerGroup;
    if (groups.any((group) => group.$1 == saved)) return saved;
    for (final group in groups) {
      if (source.group == group.$2) return group.$1;
    }
    if (section == Section.comic) {
      if (source.isKazumi) return 'kazumi';
      if (source.isAudio) return 'audiobook';
      if (source.mediaKind == 'novel') return 'novel';
      if (source.mediaKind == 'photo') return 'photo';
    }
    if (section == Section.video && source.isTvBox) return 'tvbox';
    final path = Uri.tryParse(source.originUrl)?.path ?? '';
    for (final group in groups.where((group) => group.$1 != section.id)) {
      if (path.contains('/${group.$1}/')) return group.$1;
    }
    if (section == Section.comic && source.id == 'z8pt_comic') return 'photo';
    if (section == Section.video &&
        const {
          'gztv5_video',
          'jpyy2_video',
          'luttt_video',
          'duboku_video',
          'ptt_drama',
        }.contains(source.id)) {
      return 'movie';
    }
    return section.id;
  }
}
