import Flutter
import Foundation
import WebKit

/// 内置网页视图的**原生 Cookie 仓库读取**（iOS）。
///
/// 契约见 Dart 侧 `WafWebViewPage`：方法通道 `lumebox/webview` 的 `allCookies`
/// （返回 `[{name, value, domain, path}]`）。
///
/// ## 为什么必须走原生
///
/// Cloudflare 的 `cf_clearance` 是 **HttpOnly** 的——`document.cookie` 看不见它。
/// 用户在 App 内过完真人校验后，真正能复用的那枚凭证只在 `WKHTTPCookieStore`
/// 里；`webview_flutter` 的 Dart API 只能**写** Cookie、不能枚举，因此这里补一层
/// 只读通道，把整套 Cookie（含 HttpOnly）取回来交给 Dart 存进图源会话。
///
/// 只读、不写、不删：网页视图退出后这些 Cookie 仍留在 WKWebView 的数据仓里，
/// 下次打开网页视图仍是同一个登录态（用户不必反复验证）。
final class WafCookieController: NSObject {
  private let channelName = "lumebox/webview"

  func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "allCookies":
        WafCookieController.allCookies(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  /// 枚举默认数据仓里的全部 Cookie；`WKHTTPCookieStore` 是异步回调接口。
  ///
  /// `url` 参数当前只用于日志（不过滤）：跨子域分享的 Cookie（如
  /// `.example.com` 域上的 cf_clearance）必须一起带回去，按 url 过滤会漏掉它们。
  private static func allCookies(result: @escaping FlutterResult) {
    let store = WKWebsiteDataStore.default().httpCookieStore
    store.getAllCookies { cookies in
      let list: [[String: Any]] = cookies.map { cookie in
        [
          "name": cookie.name,
          "value": cookie.value,
          "domain": cookie.domain,
          "path": cookie.path,
        ]
      }
      DispatchQueue.main.async { result(list) }
    }
  }
}
