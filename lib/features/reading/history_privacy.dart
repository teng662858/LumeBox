import '../../shared/widgets/drawer_geometry.dart';
import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

import '../../core/reading/reading_library.dart';

class HistoryPrivacy {
  static const lockKey = 'history.lock';
  static String digest(String salt, String pin) =>
      sha256.convert(utf8.encode('$salt:$pin')).toString();

  static Future<String?> input(BuildContext context, String title) async {
    var entered = '';
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          onChanged: (value) => entered = value,
          obscureText: true,
          autofocus: true,
          keyboardType: TextInputType.number,
          maxLength: 12,
          decoration: const InputDecoration(hintText: '至少 6 位数字'),
          onSubmitted: (value) {
            if (RegExp(r'^\d{6,12}$').hasMatch(value)) {
              Navigator.pop(context, value);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (RegExp(r'^\d{6,12}$').hasMatch(entered)) {
                Navigator.pop(context, entered);
              }
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    return result;
  }

  static Future<bool> unlock(
    BuildContext context,
    ReadingLibrary library,
  ) async {
    final stored = library.setting(lockKey) ?? '';
    if (stored.isEmpty) return true;
    final pin = await input(context, '解锁历史记录');
    if (pin == null) return false;
    final parts = stored.split(':');
    final valid = parts.length == 2 && digest(parts.first, pin) == parts.last;
    if (!valid && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('密码不正确')));
    }
    return valid;
  }

  static Future<void> toggleLock(
    BuildContext context,
    ReadingLibrary library,
  ) async {
    if ((library.setting(lockKey) ?? '').isNotEmpty) {
      if (await unlock(context, library)) library.setSetting(lockKey, '');
      return;
    }
    final pin = await input(context, '设置历史记录锁');
    if (pin == null || !context.mounted) return;
    final confirm = await input(context, '再次输入密码');
    if (confirm != pin) return;
    final salt = base64UrlEncode(
      List<int>.generate(24, (_) => Random.secure().nextInt(256)),
    );
    library.setSetting(lockKey, '$salt:${digest(salt, pin)}');
  }
}

/// Conceal an already-open history when the application loses focus.
class HistoryPrivacyGuard extends StatefulWidget {
  const HistoryPrivacyGuard({
    super.key,
    required this.library,
    required this.enabled,
    required this.child,
  });
  final ReadingLibrary library;
  final bool enabled;
  final Widget child;
  @override
  State<HistoryPrivacyGuard> createState() => _HistoryPrivacyGuardState();
}

class _HistoryPrivacyGuardState extends State<HistoryPrivacyGuard>
    with WidgetsBindingObserver {
  bool hidden = false, unlocking = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.enabled ||
        (widget.library.setting(HistoryPrivacy.lockKey) ?? '').isEmpty) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      if (hidden) unawaited(unlock());
    } else if (mounted && !hidden) {
      setState(() => hidden = true);
    }
  }

  Future<void> unlock() async {
    if (unlocking || !mounted) return;
    unlocking = true;
    final allowed = await HistoryPrivacy.unlock(context, widget.library);
    if (!mounted) return;
    setState(() {
      unlocking = false;
      if (allowed) hidden = false;
    });
  }

  @override
  Widget build(BuildContext context) => hidden
      ? Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SizedBox(
            height: DrawerGeometry.height(context),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline, size: 40),
                  const SizedBox(height: 16),
                  const Text('历史记录已锁定'),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: unlocking ? null : unlock,
                    child: const Text('解锁'),
                  ),
                ],
              ),
            ),
          ),
        )
      : widget.child;
}
