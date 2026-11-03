import 'package:flutter/material.dart';

import 'dart:async';

import '../../core/net/network_activity.dart';

class NetworkWaitingView extends StatelessWidget {
  const NetworkWaitingView({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      Positioned.fill(child: child),
      ValueListenableBuilder<Set<String>>(
        valueListenable: NetworkActivity.waiting,
        builder: (context, waiting, _) => waiting.isEmpty
            ? const SizedBox.shrink()
            : Positioned(
                top: 8,
                left: 16,
                right: 16,
                child: Center(
                  child: Material(
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                    elevation: 2,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => showDialog<void>(
                        context: context,
                        builder: (_) => const _WaitingDetails(),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: Text(
                          '有请求正在等待网络连接，恢复后继续…',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
      ),
    ],
  );
}

class _WaitingDetails extends StatefulWidget {
  const _WaitingDetails();
  @override
  State<_WaitingDetails> createState() => _WaitingDetailsState();
}

class _WaitingDetailsState extends State<_WaitingDetails> {
  Timer? timer;
  @override
  void initState() {
    super.initState();
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('正在等待连接的请求'),
    content: SizedBox(
      width: double.maxFinite,
      child: ValueListenableBuilder<Set<String>>(
        valueListenable: NetworkActivity.waiting,
        builder: (_, ids, _) => ListView(
          shrinkWrap: true,
          children: [
            const Text('可能来自其他页面或后台任务。本地备份等操作不需要等待这些请求。'),
            if (ids.isEmpty) const ListTile(title: Text('没有等待中的请求')),
            for (final id in ids)
              Builder(
                builder: (_) {
                  final request = NetworkActivity.request(id);
                  final seconds = request?.waitingSince == null
                      ? null
                      : DateTime.now()
                            .difference(request!.waitingSince!)
                            .inSeconds;
                  return ListTile(
                    title: Text(
                      NetworkActivity.displayLabel(request?.label ?? '网络请求'),
                    ),
                    subtitle: Text(
                      '${request?.method ?? ''} ${request?.host ?? ''}${seconds == null ? '' : '\n已等待 $seconds 秒'}',
                    ),
                    trailing: request == null
                        ? null
                        : TextButton(
                            onPressed: () => NetworkActivity.cancel(id),
                            child: const Text('取消请求'),
                          ),
                  );
                },
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('关闭'),
      ),
    ],
  );
}
