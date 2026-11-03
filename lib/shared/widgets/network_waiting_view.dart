import 'package:flutter/material.dart';

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
                child: IgnorePointer(
                  child: Center(
                    child: Material(
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(18),
                      elevation: 2,
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
