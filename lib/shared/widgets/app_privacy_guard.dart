import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:lume_box/core/theme/lume_typography.dart';
import 'package:flutter/material.dart';

import '../../core/session/privacy_settings.dart';

/// Outside Navigator: all routes, dialogs and reader pages are concealed.
class AppPrivacyGuard extends StatefulWidget {
  const AppPrivacyGuard({super.key, required this.child, this.settings});
  final Widget child;
  final PrivacySettings? settings;
  @override
  State<AppPrivacyGuard> createState() => _AppPrivacyGuardState();
}

class _AppPrivacyGuardState extends State<AppPrivacyGuard>
    with WidgetsBindingObserver {
  PrivacySettings get settings => widget.settings ?? PrivacySettings.instance;
  late bool locked = settings.appLock;
  late bool wasEnabled = settings.appLock;
  bool obscured = false;
  int generation = 0;
  String? error;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    settings.addListener(changed);
    if (locked) scheduleUnlock();
  }

  void changed() {
    if (mounted) {
      setState(() {
        final justEnabled = settings.appLock && !wasEnabled;
        wasEnabled = settings.appLock;
        if (!settings.appLock) {
          locked = false;
          obscured = false;
          generation++;
        } else if (justEnabled &&
            (WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.paused ||
                WidgetsBinding.instance.lifecycleState ==
                    AppLifecycleState.hidden)) {
          locked = true;
          obscured = true;
          generation++;
        }
      });
    }
  }

  void scheduleUnlock() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && locked && !obscured && !settings.authenticating) unlock();
  });
  Future<void> unlock({AppUnlockMethod? method}) async {
    if (settings.authenticating) return;
    final token = generation;
    setState(() => error = null);
    try {
      final success = await settings.authenticate(using: method);
      if (mounted && generation == token) {
        setState(() {
          locked = !success;
          if (!success) error = '未完成验证，请重试';
        });
      }
    } catch (_) {
      if (mounted && generation == token) {
        setState(() => error = '无法验证，请检查系统锁屏密码或面容设置');
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!settings.appLock) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      setState(() {
        obscured = true;
        if (!settings.authenticating ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.hidden) {
          locked = true;
          generation++;
        }
      });
    } else if (state == AppLifecycleState.resumed) {
      setState(() => obscured = false);
      if (locked) scheduleUnlock();
    }
  }

  @override
  void dispose() {
    generation++;
    settings.removeListener(changed);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!settings.appLock) return widget.child;
    final concealed = locked || obscured;
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: concealed,
          child: ExcludeFocus(
            excluding: concealed,
            child: TickerMode(enabled: !concealed, child: widget.child),
          ),
        ),
        if (concealed)
          Material(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const LumeIcon(
                        Icons.lock_outline,
                        slot: 'app_privacy_guard.1',
                        size: 48,
                      ),
                      const SizedBox(height: 20),
                      const Text(
                        'LumeBox 已锁定',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: LumeTypography.displaySmallSize,
                        ),
                      ),
                      const SizedBox(height: 20),
                      if (settings.authenticating)
                        const CircularProgressIndicator()
                      else if (!obscured) ...[
                        FilledButton(
                          onPressed: () => unlock(),
                          child: Text('使用${settings.method.label}解锁'),
                        ),
                        if (settings.method == AppUnlockMethod.face)
                          TextButton(
                            onPressed: () =>
                                unlock(method: AppUnlockMethod.passcode),
                            child: const Text('使用锁屏密码'),
                          ),
                      ],
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(error!),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
