import 'package:lume_box/shared/widgets/lume_icon.dart';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/cat/cat_service.dart';
import '../../shared/widgets/glass_card.dart';

/// Source-provided account/configuration pages stay inside the app.
class CatWebPage extends StatefulWidget {
  const CatWebPage({super.key, required this.url});
  final Uri url;
  @override
  State<CatWebPage> createState() => _CatWebPageState();
}

class _CatWebPageState extends State<CatWebPage> {
  int progress = 0;
  String? error;
  late final WebViewController controller = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setNavigationDelegate(
      NavigationDelegate(
        onProgress: (value) {
          if (mounted) setState(() => progress = value);
        },
        onPageStarted: (_) {
          if (mounted) setState(() => error = null);
        },
        onWebResourceError: (failure) {
          if (mounted && failure.isForMainFrame == true) {
            setState(() => error = '配置页加载失败，请刷新重试');
          }
        },
        onNavigationRequest: (request) async {
          final uri = Uri.tryParse(request.url);
          if (uri == null) return NavigationDecision.prevent;
          if (['http', 'https', 'about', 'data', 'blob'].contains(uri.scheme)) {
            return NavigationDecision.navigate;
          }
          final opened =
              await CatService.channel.invokeMethod<bool>('openExternal', {
                'url': uri.toString(),
              }) ??
              false;
          if (!opened && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('未安装对应网盘应用，请使用配置页的二维码或网页登录')),
            );
          }
          return NavigationDecision.prevent;
        },
        onPageFinished: (_) async {
          // Provider pages sometimes use a new window for login; keep it in this configuration session.
          await controller.runJavaScript(
            'window.open = function(url) { if (url) location.href = url; return window; };',
          );
        },
      ),
    )
    ..loadRequest(widget.url);
  @override
  Widget build(BuildContext context) => GlassScaffold(
    effectModule: GlassModule.cat,
    title: '网盘登录与配置',
    leading: IconButton(
      icon: const LumeIcon(Icons.arrow_back, slot: 'cat_web_page.1'),
      onPressed: () async {
        if (await controller.canGoBack()) {
          await controller.goBack();
        } else if (context.mounted) {
          Navigator.pop(context);
        }
      },
    ),
    actions: [
      IconButton(
        tooltip: '刷新',
        icon: const LumeIcon(Icons.refresh, slot: 'cat_web_page.2'),
        onPressed: () => controller.reload(),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('完成'),
      ),
    ],
    child: Column(
      children: [
        if (progress < 100) LinearProgressIndicator(value: progress / 100),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        Expanded(child: WebViewWidget(controller: controller)),
      ],
    ),
  );
}
