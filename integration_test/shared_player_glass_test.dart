import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:lume_box/core/player/abstract_player.dart';
import 'package:lume_box/core/player/player_factory.dart';
import 'package:lume_box/core/player/player_settings.dart';
import 'package:lume_box/core/reading/reading.dart';
import 'package:lume_box/core/security/local_cipher.dart';
import 'package:lume_box/core/session/section.dart';
import 'package:lume_box/core/theme/frosted_settings.dart';
import 'package:lume_box/core/theme/lume_theme.dart';
import 'package:lume_box/features/video/video_player_page.dart';
import 'package:lume_box/features/video/video_player_settings.dart';
import 'package:lume_box/features/video/player_settings_sheet.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized().framePolicy =
      LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('shared player engines and native glass modal lifecycle', (
    tester,
  ) async {
    final directory = await getApplicationSupportDirectory();
    // Isolated simulator fixture data; no real credentials or subscriptions.
    // ignore: invalid_use_of_visible_for_testing_member
    LocalCipher.configurePreview(directory.path, Uint8List(32));
    await FrostedSettings.instance.boot();
    await FrostedSettings.instance.setPlayerNative(true);
    final library = await ReadingLibrary.open(Section.video);
    final store = VideoPlayerSettingsStore(library);
    Future<void> frames() async {
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await tester.pump();
    }

    Future<void> capture(String name) async {
      debugPrint('PLAYER_GLASS_CAPTURE $name');
      await Future<void>.delayed(const Duration(seconds: 3));
    }

    for (final kernel in PlayerKernel.selectable) {
      AbstractPlayer? player;
      PlayerKernel? chosen;
      store.save(
        PlayerSettings(
          kernel: kernel,
          autoHideControls: false,
          autoNext: false,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: LumeTheme.build(),
          home: VideoPlayerPage(
            title: 'Shared player ${kernel.label}',
            library: library,
            playerFactory: (selected) {
              chosen = selected;
              return player = PlayerFactory.create(kernel: selected);
            },
            media: PlayerMedia(
              uri: Uri.parse('http://127.0.0.1:18765/protected/smoke.mp4'),
              headers: const {'X-Lume-Test': r'ticket=a,b\c'},
            ),
          ),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 40));
      while ((player?.snapshot.value.position ?? Duration.zero) <
          const Duration(seconds: 1)) {
        if (player?.snapshot.value.error != null) {
          fail('${kernel.name}: ${player!.snapshot.value.error}');
        }
        if (DateTime.now().isAfter(deadline)) {
          fail(
            '${kernel.name}: playback did not advance: ${player?.snapshot.value.error}',
          );
        }
        await frames();
      }
      expect(
        chosen,
        kernel,
        reason: 'A fallback cannot count as a successful engine check',
      );
      expect(player!.snapshot.value.error, isNull);
      debugPrint(
        'SHARED_PLAYER_READY ${kernel.name} ${player!.snapshot.value.position}',
      );
      await player!.pause();
      await frames();
      expect(
        tester.getSize(find.byKey(const Key('fullscreen-top-surface'))).height,
        lessThanOrEqualTo(56),
      );
      expect(
        tester
            .getSize(find.byKey(const Key('fullscreen-bottom-surface')))
            .height,
        lessThanOrEqualTo(88),
      );
      if (kernel == PlayerKernel.avplayer) {
        await capture('controls');
        await tester.tap(find.byTooltip('播放器设置'));
        await frames();
        expect(find.byType(PlayerSettingsSheet), findsOneWidget);
        await capture('settings');
        await tester.tap(find.byTooltip('播放器外观'));
        await frames();
        expect(find.text('经典版'), findsOneWidget);
        await capture('appearance-menu');
        // Dismiss the popup, then the settings panel, retaining the player.
        Navigator.of(tester.element(find.text('经典版'))).pop();
        await frames();
        Navigator.of(tester.element(find.byType(PlayerSettingsSheet))).pop();
        await frames();
        expect(find.byType(PlayerSettingsSheet), findsNothing);
        await capture('settings-closed');
      }
      await player!.seek(const Duration(seconds: 3));
      await player!.play();
      await frames();
      expect(player!.snapshot.value.error, isNull);
      debugPrint('SHARED_PLAYER_OK ${kernel.name}');
      await tester.pumpWidget(const SizedBox());
      await frames();
    }
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    debugPrint('SHARED_PLAYER_ALL_OK');
  });
}
