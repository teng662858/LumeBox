import Flutter
import UIKit

/// A real system navigation control, embedded only in the bottom bar's area.
/// The existing Flutter controller continues to own pages, routes and playback.
final class LumeSystemTabBarFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger

  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let messenger = registrar.messenger()
    registrar.register(LumeSystemTabBarFactory(messenger: messenger), withId: "lumebox/system_tab_bar")
    registrar.register(LumeSystemSearchFactory(messenger: messenger), withId: "lumebox/system_search_button")
    FlutterMethodChannel(name: "lumebox/system_tab_bar", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "capabilities" else {
          result(FlutterMethodNotImplemented)
          return
        }
        if #available(iOS 26.0, *) {
          result(["supported": true, "height": LumeSystemTabBarContainer.fittingHeight(width: 320)])
        } else {
          // Keep the established Dock on systems without the new material.
          result(["supported": false])
        }
      }
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    LumeSystemTabBarView(frame: frame, viewId: viewId, args: args, messenger: messenger)
  }
}

/// A real UIKit glass button: the OS owns its material and press interaction.
final class LumeSystemSearchFactory: NSObject, FlutterPlatformViewFactory {
  let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }
  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol { FlutterStandardMessageCodec.sharedInstance() }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    LumeSystemSearchView(frame: frame, viewId: viewId, args: args, messenger: messenger)
  }
}

private final class LumeSystemSearchView: NSObject, FlutterPlatformView {
  let button: UIButton
  let channel: FlutterMethodChannel
  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    button = UIButton(type: .system)
    button.frame = frame
    channel = FlutterMethodChannel(name: "lumebox/system_search_button_\(viewId)", binaryMessenger: messenger)
    super.init()
    button.accessibilityLabel = "全局搜索"
    button.accessibilityIdentifier = "global-search-button"
    button.addTarget(self, action: #selector(pressed), for: .touchUpInside)
    update(args)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      self?.update(call.arguments)
      result(nil)
    }
  }
  deinit { channel.setMethodCallHandler(nil) }
  func view() -> UIView { button }
  @objc private func pressed() { channel.invokeMethod("pressed", arguments: nil) }
  private func update(_ arguments: Any?) {
    let values = arguments as? [String: Any] ?? [:]
    var configuration: UIButton.Configuration
    if #available(iOS 26.0, *) { configuration = .glass() }
    else { configuration = .bordered() }
    configuration.cornerStyle = .capsule
    configuration.contentInsets = .zero
    configuration.image = UIImage(systemName: "magnifyingglass")
    configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 24, weight: .regular)
    if let tint = values["tintColor"] as? NSNumber {
      let argb = tint.uint32Value
      configuration.baseForegroundColor = UIColor(red: CGFloat((argb >> 16) & 255) / 255,
        green: CGFloat((argb >> 8) & 255) / 255, blue: CGFloat(argb & 255) / 255, alpha: 1)
    }
    let rawDensity = (values["materialOpacity"] as? NSNumber)?.doubleValue ?? 0.6
    let density = CGFloat(rawDensity.isFinite ? min(1, max(0, rawDensity)) : 0.6)
    configuration.background.backgroundColor = UIColor.systemBackground.withAlphaComponent(
      values["opaqueBackground"] as? Bool == true ? 1 : density)
    button.configuration = configuration
    button.overrideUserInterfaceStyle = values["brightness"] as? String == "dark" ? .dark : .light
    button.isEnabled = values["enabled"] as? Bool != false
  }
}

private struct LumeSystemTabSpec: Equatable {
  let id: String
  let label: String
  let badge: Int
}

private final class LumeContentTabBar: UITabBar {
  // Flutter already positions this control above the home indicator.
  override var safeAreaInsets: UIEdgeInsets { .zero }
}

private final class LumeSystemTabBarContainer: UIView {
  let bar = LumeContentTabBar()
  var preferredHeight: CGFloat = 0
  var onHeightChanged: ((CGFloat) -> Void)?
  private var lastHeight: CGFloat = 0

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    bar.backgroundColor = .clear
    addSubview(bar)
    // UIKit alone owns the glass platter and moving selection lens. Never add
    // a second glass/material view underneath it or fade the whole control.
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  static func fittingHeight(width: CGFloat) -> CGFloat {
    let size = LumeContentTabBar().sizeThatFits(CGSize(width: max(width, 1), height: 1000))
    return min(max(ceil(size.height), 49), 100)
  }

  var fittingBarHeight: CGFloat {
    let size = bar.sizeThatFits(CGSize(width: max(bounds.width, 1), height: 1000))
    return min(max(ceil(size.height), 49), 100)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let height = fittingBarHeight
    let target = preferredHeight > 0 ? preferredHeight : height
    let scale = target / height
    // Resize the complete public control, including its system lens and hit
    // targets. No traversal or modification of UIKit's private glass views.
    bar.transform = .identity
    bar.bounds = CGRect(x: 0, y: 0, width: bounds.width / scale, height: height)
    bar.center = CGPoint(x: bounds.midX, y: bounds.height - target / 2)
    bar.transform = CGAffineTransform(scaleX: scale, y: scale)
    if lastHeight != height {
      lastHeight = height
      // Deliver after layout, so Flutter can update its content inset safely.
      DispatchQueue.main.async { [weak self] in self?.onHeightChanged?(height) }
    }
  }
}

private final class LumeSystemTabBarView: NSObject, FlutterPlatformView, UITabBarDelegate {
  private let container: LumeSystemTabBarContainer
  private let channel: FlutterMethodChannel
  private var specs: [LumeSystemTabSpec] = []
  private var showLabels = true
  private var iconSize: CGFloat = 24
  private var solidIcons = false
  private var selectedContentId: String?

  init(frame: CGRect, viewId: Int64, args: Any?, messenger: FlutterBinaryMessenger) {
    container = LumeSystemTabBarContainer(frame: frame)
    channel = FlutterMethodChannel(name: "lumebox/system_tab_bar_\(viewId)", binaryMessenger: messenger)
    super.init()
    container.bar.delegate = self
    container.onHeightChanged = { [weak self] height in
      self?.channel.invokeMethod("metrics", arguments: ["height": height])
    }
    _ = update(args)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      guard let self = self else { result(nil); return }
      guard self.update(call.arguments) else {
        result(FlutterError(code: "configuration", message: "Invalid system tab bar configuration", details: nil))
        return
      }
      result(["height": self.container.fittingBarHeight])
    }
  }

  deinit { channel.setMethodCallHandler(nil) }

  func view() -> UIView { container }

  private func update(_ arguments: Any?) -> Bool {
    guard let values = arguments as? [String: Any],
          let entries = values["entries"] as? [[String: Any]],
          !entries.isEmpty, entries.count <= 5 else { return false }
    var next: [LumeSystemTabSpec] = []
    for entry in entries {
      guard let id = entry["id"] as? String, ["comic", "video", "music", "settings", "search"].contains(id),
            let label = entry["label"] as? String, !label.isEmpty,
            !next.contains(where: { $0.id == id }) else { return false }
      next.append(LumeSystemTabSpec(id: id, label: label,
        badge: max(0, (entry["badge"] as? NSNumber)?.intValue ?? 0)))
    }
    let labels = values["showLabels"] as? Bool ?? true
    let rawHeight = (values["barHeight"] as? NSNumber)?.doubleValue ?? 0
    container.preferredHeight = rawHeight.isFinite && rawHeight > 0
      ? CGFloat(min(max(rawHeight, 40), 120)) : 0
    let rawSize = (values["iconSize"] as? NSNumber)?.doubleValue ?? 24
    let size = CGFloat(rawSize.isFinite ? min(max(rawSize, 18), 30) : 24)
    let solid = values["solidIcons"] as? Bool ?? false
    if specs != next || labels != showLabels || size != iconSize || solid != solidIcons {
      specs = next
      showLabels = labels
      iconSize = size
      solidIcons = solid
      let configuration = UIImage.SymbolConfiguration(pointSize: size, weight: .regular)
      let items = specs.map { spec -> UITabBarItem in
        let symbol: String
        switch spec.id {
        case "comic": symbol = "book"
        case "video": symbol = "play.circle"
        case "music": symbol = "music.note"
        case "search": symbol = "magnifyingglass"
        default: symbol = "gearshape"
        }
        let filled = (spec.id == "search" || spec.id == "music") ? symbol : symbol + ".fill"
        let item = UITabBarItem(
          title: labels ? spec.label : nil,
          image: UIImage(systemName: solid ? filled : symbol, withConfiguration: configuration),
          selectedImage: UIImage(systemName: filled, withConfiguration: configuration)
        )
        item.accessibilityLabel = spec.label
        item.badgeValue = spec.badge > 0 ? (spec.badge > 99 ? "99+" : String(spec.badge)) : nil
        item.accessibilityIdentifier = "shell.tab.\(spec.id)"
        return item
      }
      container.bar.setItems(items, animated: false)
    }
    let activeId = values["activeId"] as? String
    selectedContentId = activeId
    let index = specs.firstIndex(where: { $0.id == activeId })
    container.bar.selectedItem = index.flatMap { container.bar.items?[$0] }
    container.overrideUserInterfaceStyle = values["brightness"] as? String == "dark" ? .dark : .light
    container.bar.unselectedItemTintColor = solid
      ? (values["brightness"] as? String == "dark" ? .white : UIColor(white: 0.086, alpha: 1))
      : nil
    let opacity = (values["materialOpacity"] as? NSNumber)?.doubleValue ?? 0.6
    let density = CGFloat(opacity.isFinite ? min(1, max(0, opacity)) : 0.6)
    let appearance = UITabBarAppearance()
    if values["opaqueBackground"] as? Bool == true {
      appearance.configureWithOpaqueBackground()
      appearance.backgroundColor = .systemBackground
    } else {
      appearance.configureWithDefaultBackground()
      // Adjust the public appearance's neutral fill, not private UIKit views
      // or the alpha of labels/the system selection effect.
      appearance.backgroundColor = UIColor.systemBackground.withAlphaComponent(density)
    }
    appearance.shadowColor = .clear
    container.bar.standardAppearance = appearance
    container.bar.scrollEdgeAppearance = appearance
    if let tint = values["tintColor"] as? NSNumber {
      let argb = tint.uint32Value
      container.bar.tintColor = UIColor(
        red: CGFloat((argb >> 16) & 255) / 255,
        green: CGFloat((argb >> 8) & 255) / 255,
        blue: CGFloat(argb & 255) / 255, alpha: 1
      )
    }
    container.setNeedsLayout()
    return true
  }

  func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
    guard let index = tabBar.items?.firstIndex(where: { $0 === item }), index < specs.count else { return }
    if specs[index].id == "search" {
      let previous = specs.firstIndex(where: { $0.id == selectedContentId })
      tabBar.selectedItem = previous.flatMap { tabBar.items?[$0] }
    } else {
      selectedContentId = specs[index].id
    }
    channel.invokeMethod("selected", arguments: specs[index].id)
  }
}
