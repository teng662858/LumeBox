import Flutter
import UIKit

private final class SmokeMessenger: NSObject, FlutterBinaryMessenger {
  var handlers: [String: FlutterBinaryMessageHandler] = [:]
  var received: [FlutterMethodCall] = []
  private var connection: Int64 = 0

  func send(onChannel channel: String, message: Data?) {
    if (channel.hasPrefix("lumebox/system_tab_bar_") || channel.hasPrefix("lumebox/system_search_button_")), let data = message {
      received.append(FlutterStandardMethodCodec.sharedInstance().decodeMethodCall(data))
    }
  }

  func send(onChannel channel: String, message: Data?, binaryReply callback: FlutterBinaryReply?) {
    send(onChannel: channel, message: message)
    callback?(nil)
  }

  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    handlers[channel] = handler
    connection += 1
    return connection
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}

  func update(_ values: [String: Any]) -> Data? {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    var reply: Data?
    let call = FlutterMethodCall(methodName: "update", arguments: values)
    handlers["lumebox/system_tab_bar_1"]?(codec.encode(call)) { reply = $0 }
    return reply
  }
}

@main
final class SystemTabBarSmoke: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  private let messenger = SmokeMessenger()
  private var platformView: FlutterPlatformView?
  private var searchView: FlutterPlatformView?
  private func checkpoint(_ phase: String, detail: String = "") {
    let status: [String: Any] = ["phase": phase, "detail": detail]
    let output = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/native-tab-bar-status.json")
    do {
      try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONSerialization.data(withJSONObject: status).write(to: output, options: .atomic)
    } catch {
      fputs("Cannot save smoke status: \(error)\n", stderr)
      exit(1)
    }
    print("LUME_SYSTEM_TAB_BAR_SMOKE_\(phase): \(detail)")
    fflush(stdout)
  }

  private func require(_ condition: @autoclosure () -> Bool,
                       _ message: String = "Native tab bar assertion failed", line: UInt = #line) {
    if !condition() {
      checkpoint("failed", detail: "\(message) (line \(line))")
      exit(1)
    }
  }
  private var configuration: [String: Any] = [
    "entries": [["id": "comic", "label": "漫画"], ["id": "video", "label": "视频"], ["id": "settings", "label": "设置"], ["id": "search", "label": "搜索"]],
    "activeId": "comic", "showLabels": true, "iconSize": 24,
    "brightness": "light", "tintColor": 0xFF7C5CFF,
  ]

  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    checkpoint("launched")
    let window = UIWindow(frame: UIScreen.main.bounds)
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    let title = UILabel(frame: CGRect(x: 24, y: 110, width: window.bounds.width - 48, height: 80))
    title.numberOfLines = 0
    title.text = "原生导航组件验证\n这不是完整 App 截图"
    title.font = .systemFont(ofSize: 22, weight: .semibold)
    controller.view.addSubview(title)
    for row in 0..<12 {
      let label = UILabel(frame: CGRect(x: 24, y: CGFloat(220 + row * 52), width: window.bounds.width - 48, height: 44))
      label.text = "页面内容 · \(row + 1)  漫画 / 视频 / 设置"
      label.textColor = [.systemPurple, .systemBlue, .systemGreen][row % 3]
      controller.view.addSubview(label)
    }
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window

    let factory = LumeSystemTabBarFactory(messenger: messenger)
    platformView = factory.create(withFrame: .zero, viewIdentifier: 1, arguments: configuration)
    let view = platformView!.view()
    controller.view.addSubview(view)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      let height = UITabBar().sizeThatFits(CGSize(width: window.bounds.width - 32, height: 1000)).height
      view.frame = CGRect(x: 16, y: window.bounds.height - window.safeAreaInsets.bottom - height - 8,
                          width: window.bounds.width - 32, height: height)
      view.layoutIfNeeded()
      self.verify(view)
      let size: CGFloat = 60
      view.frame.size.width -= size + 10
      view.layoutIfNeeded()
      let search = LumeSystemSearchFactory(messenger: self.messenger).create(
        withFrame: CGRect(x: window.bounds.width - 16 - size, y: view.frame.midY - size / 2, width: size, height: size),
        viewIdentifier: 2, arguments: ["brightness": "light", "tintColor": 0xFF7C5CFF, "materialOpacity": 0.6])
      self.searchView = search
      controller.view.addSubview(search.view())
      let button = search.view() as! UIButton
      self.require(button.configuration?.cornerStyle == .capsule && button.configuration?.image != nil, "Search must be a circular UIKit button")
      self.require(!view.frame.intersects(button.frame), "Search must sit beside the navigation capsule")
      button.sendActions(for: .touchUpInside)
      self.require(self.messenger.received.contains { $0.method == "pressed" }, "Native search press must reach Flutter")
      self.checkpoint("verified")
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
          window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let output = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/native-tab-bar.png")
        do {
          guard let png = image.pngData() else { throw NSError(domain: "Smoke", code: 1) }
          try png.write(to: output, options: .atomic)
        } catch {
          self.checkpoint("failed", detail: "Cannot save screenshot: \(error)")
          exit(1)
        }
        self.checkpoint("passed")
        print("LUME_SYSTEM_TAB_BAR_SMOKE_OK")
        fflush(stdout)
        exit(0)
      }
    }
    return true
  }

  private func verify(_ view: UIView) {
    let bar = view.subviews.compactMap { $0 as? UITabBar }.first!
    require(bar.items?.count == 4 && bar.selectedItem === bar.items?[0])
    let searchItem = bar.items![3]
    require(searchItem.image != nil && searchItem.selectedImage != nil)
    bar.selectedItem = searchItem
    bar.delegate?.tabBar?(bar, didSelect: searchItem)
    require(bar.selectedItem === bar.items?[0], "Search must keep the current content tab selected")
    require(messenger.received.contains { $0.method == "selected" && ($0.arguments as? String) == "search" })
    require(bar.bounds.height >= 49 && bar.bounds.height <= 100)
    let original = bar.items![0]
    configuration["activeId"] = "video"
    require(messenger.update(configuration) != nil)
    require(bar.selectedItem === bar.items?[1] && bar.items?[0] === original,
                 "Selecting a tab must preserve native items and their animation state")
    bar.delegate?.tabBar?(bar, didSelect: bar.items![2])
    require(messenger.received.contains { $0.method == "selected" && ($0.arguments as? String) == "settings" })

    configuration["showLabels"] = false
    configuration["brightness"] = "dark"
    configuration["iconSize"] = 28
    configuration["tintColor"] = 0xFF008A6A
    _ = messenger.update(configuration)
    require(bar.items!.allSatisfy { $0.title == nil && $0.accessibilityLabel != nil })
    require(view.overrideUserInterfaceStyle == .dark)
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    require(bar.tintColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    require(abs(green - 138.0 / 255.0) < 0.001 && abs(blue - 106.0 / 255.0) < 0.001)

    configuration["entries"] = [["id": "settings", "label": "设置"], ["id": "comic", "label": "漫画"]]
    configuration["activeId"] = "comic"
    configuration["showLabels"] = true
    configuration["brightness"] = "light"
    _ = messenger.update(configuration)
    require(bar.items?.count == 2 && bar.selectedItem === bar.items?[1])
    require(bar.items?.first?.accessibilityIdentifier == "shell.tab.settings")
    configuration["entries"] = [["id": "comic", "label": "漫画"], ["id": "comic", "label": "重复"]]
    _ = messenger.update(configuration)
    require(bar.items?.count == 2 && bar.items?.first?.accessibilityIdentifier == "shell.tab.settings",
                 "Invalid duplicate IDs must leave the previous native navigation intact")
    configuration["entries"] = [["id": "comic", "label": "漫画"], ["id": "video", "label": "视频"], ["id": "music", "label": "音乐"], ["id": "settings", "label": "设置"]]
    configuration["iconSize"] = 24
    _ = messenger.update(configuration)
    view.layoutIfNeeded()
    require(bar.items?.map { $0.accessibilityIdentifier ?? "" } == ["shell.tab.comic", "shell.tab.video", "shell.tab.music", "shell.tab.settings"],
            "The native bar must accept and display all four production tabs")
    require(bar.items?.allSatisfy { $0.image != nil && $0.selectedImage != nil } == true,
            "Every production tab, including music, must have a native symbol")
  }
}
