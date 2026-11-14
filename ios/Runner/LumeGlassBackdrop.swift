import Flutter
import UIKit

/// 原生系统材质底座：给 Flutter 侧“iOS 原生材质”开关使用。
///
/// iOS 26 使用 UIGlassEffect；旧系统、厚实风格及降低透明度使用磨砂。
/// 普通 UIBlurEffect 不会自动升级为 Liquid Glass。
///
/// 限制：Flutter 平台视图是独立层，不能参与 Flutter 的 `BackdropFilter`
/// 取样，因此 Dart 侧在该模式下会关闭自绘透镜的 Backdrop 折射。
final class LumeGlassBackdropFactory: NSObject, FlutterPlatformViewFactory {
  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
  }

  private let messenger: FlutterBinaryMessenger

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    if let params = args as? [String: Any], let control = params["control"] as? String {
      return LumeNativeControl(frame: frame, viewId: viewId, control: control, params: params, messenger: messenger)
    }
    return LumeGlassBackdropView(
      frame: frame,
      viewId: viewId,
      args: args,
      messenger: messenger
    )
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }
}

/// Real UIKit controls inherit the current OS appearance, including iOS 26 glass.
private final class LumeNativeControl: NSObject, FlutterPlatformView {
  private let container: UIView
  private let control: UIControl
  private let bufferedTrack = UIProgressView(progressViewStyle: .default)
  private let channel: FlutterMethodChannel
  init(frame: CGRect, viewId: Int64, control kind: String, params: [String: Any], messenger: FlutterBinaryMessenger) {
    let host = UIView(frame: frame)
    let widget: UIControl = kind == "switch" ? UISwitch() : UISlider()
    container = host; control = widget
    channel = FlutterMethodChannel(name: "lumebox/glass_control_\(viewId)", binaryMessenger: messenger)
    super.init()
    host.backgroundColor = .clear
    host.addSubview(widget); widget.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([widget.centerXAnchor.constraint(equalTo: host.centerXAnchor), widget.centerYAnchor.constraint(equalTo: host.centerYAnchor)])
    if let slider = widget as? UISlider {
      slider.widthAnchor.constraint(equalTo: host.widthAnchor, constant: -4).isActive = true
      bufferedTrack.isHidden = true
      bufferedTrack.isUserInteractionEnabled = false
      bufferedTrack.isAccessibilityElement = false
      bufferedTrack.translatesAutoresizingMaskIntoConstraints = false
      host.insertSubview(bufferedTrack, belowSubview: slider)
      NSLayoutConstraint.activate([
        bufferedTrack.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
        bufferedTrack.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
        bufferedTrack.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
      ])
    }
    widget.addTarget(self, action: #selector(changed), for: .valueChanged)
    widget.addTarget(self, action: #selector(began), for: .touchDown)
    widget.addTarget(self, action: #selector(ended), for: [.touchUpInside, .touchUpOutside, .touchCancel])
    update(params)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else { result(FlutterMethodNotImplemented); return }
      if let params = call.arguments as? [String: Any] { self?.update(params) }
      result(nil)
    }
  }
  deinit {
    channel.setMethodCallHandler(nil)
    container.removeFromSuperview()
  }
  func view() -> UIView { container }
  private func value() -> Any { (control as? UISwitch).map { $0.isOn as Any } ?? (control as! UISlider).value }
  @objc private func changed() { channel.invokeMethod("changed", arguments: value()) }
  @objc private func began() { channel.invokeMethod("began", arguments: value()) }
  @objc private func ended() { channel.invokeMethod("ended", arguments: value()) }
  private func color(_ value: Any?) -> UIColor? {
    guard let number = value as? NSNumber else { return nil }
    let rgb = number.uint32Value
    return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
      green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255,
      alpha: CGFloat((rgb >> 24) & 255) / 255)
  }

  private func update(_ params: [String: Any]) {
    control.isEnabled = params["enabled"] as? Bool ?? true
    container.overrideUserInterfaceStyle = params["dark"] as? Bool == true ? .dark : .light
    if let tint = color(params["tintColor"]) {
      control.tintColor = tint
      (control as? UISwitch)?.onTintColor = tint
      (control as? UISlider)?.minimumTrackTintColor = tint
    }
    if let toggle = control as? UISwitch { toggle.setOn(params["value"] as? Bool ?? false, animated: false) }
    if let slider = control as? UISlider {
      if params["compact"] as? Bool == true {
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
          UIColor.white.setFill()
          context.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: 16, height: 16))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.setThumbImage(thumb, for: .highlighted)
      } else {
        slider.setThumbImage(nil, for: .normal)
        slider.setThumbImage(nil, for: .highlighted)
      }
      slider.minimumValue = (params["min"] as? NSNumber)?.floatValue ?? 0
      slider.maximumValue = (params["max"] as? NSNumber)?.floatValue ?? 1
      if !slider.isTracking {
        slider.value = (params["value"] as? NSNumber)?.floatValue ?? 0
      }
      let trackColor = color(params["trackColor"])
      let buffered = (params["bufferedValue"] as? NSNumber)?.floatValue
      bufferedTrack.isHidden = buffered == nil
      slider.maximumTrackTintColor = buffered == nil ? trackColor : .clear
      if let buffered, slider.maximumValue > slider.minimumValue {
        bufferedTrack.trackTintColor = trackColor ?? .systemFill
        bufferedTrack.progressTintColor = color(params["bufferedColor"]) ?? .secondaryLabel
        bufferedTrack.progress = min(1, max(0,
          (buffered - slider.minimumValue) / (slider.maximumValue - slider.minimumValue)))
      }
    }
  }
}

final class LumeGlassBackdropView: NSObject, FlutterPlatformView {
  private let container = UIView()
  private let effectView: UIVisualEffectView
  private let channel: FlutterMethodChannel
  private var materialKey = ""

  init(
    frame: CGRect,
    viewId: Int64,
    args: Any?,
    messenger: FlutterBinaryMessenger
  ) {
    effectView = UIVisualEffectView()
    channel = FlutterMethodChannel(
      name: "lumebox/glass_backdrop_\(viewId)",
      binaryMessenger: messenger
    )
    super.init()

    container.frame = frame
    container.backgroundColor = .clear
    container.isUserInteractionEnabled = false
    container.layer.cornerCurve = .continuous

    effectView.frame = container.bounds
    effectView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    effectView.layer.cornerCurve = .continuous
    container.addSubview(effectView)
    update(args)

    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "update" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self else {
        result(nil)
        return
      }
      self.update(call.arguments)
      result(nil)
    }
  }

  deinit {
    channel.setMethodCallHandler(nil)
    effectView.effect = nil
    effectView.removeFromSuperview()
    container.removeFromSuperview()
  }

  func view() -> UIView {
    container
  }

  private func update(_ args: Any?) {
    let params = args as? [String: Any] ?? [:]
    let style = params["style"] as? String ?? "regular"
    let reduced = (params["reduceTransparency"] as? Bool ?? false) || UIAccessibility.isReduceTransparencyEnabled
    let radius = Self.cornerRadius(from: args)
    container.layer.cornerRadius = radius
    effectView.layer.cornerRadius = radius
    // Native traits must follow the app theme, including a manually chosen theme.
    container.overrideUserInterfaceStyle = params["brightness"] as? String == "dark"
      ? .dark : .light
    effectView.clipsToBounds = true
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      effectView.cornerConfiguration = .corners(radius: .fixed(Double(radius)))
      effectView.clipsToBounds = style == "thick" || reduced
    }
    #endif
    let rgba = (params["tintColor"] as? NSNumber)?.uint32Value ?? 0xFFFFFFFF
    let rawOpacity = (params["tintOpacity"] as? NSNumber)?.doubleValue ?? 0
    let materialOpacity = (params["materialOpacity"] as? NSNumber)?.doubleValue ?? 1
    effectView.alpha = CGFloat(materialOpacity.isFinite ? min(1, max(0, materialOpacity)) : 1)
    let opacity = rawOpacity.isFinite ? min(0.5, max(0, rawOpacity)) : 0
    let tint = opacity > 0 ? UIColor(red: CGFloat((rgba >> 16) & 255) / 255,
      green: CGFloat((rgba >> 8) & 255) / 255, blue: CGFloat(rgba & 255) / 255,
      alpha: CGFloat(opacity)) : nil
    let key = "\(style):\(reduced):\(rgba):\(opacity)"
    if key != materialKey {
      materialKey = key
      effectView.effect = Self.effect(style: style, reduced: reduced, tint: tint)
      effectView.contentView.backgroundColor = nil
      #if compiler(>=6.2)
      if #available(iOS 26.0, *), style != "thick", !reduced { return }
      #endif
      effectView.contentView.backgroundColor = tint
    }
  }

  private static func effect(style: String, reduced: Bool, tint: UIColor?) -> UIVisualEffect {
    // Xcode 26 / Swift 6.2 provides the new SDK symbols. Older toolchains can
    // still compile the project and retain the documented material fallback.
    #if compiler(>=6.2)
    if #available(iOS 26.0, *), style != "thick", !reduced {
      let glass = UIGlassEffect(style: style == "thin" ? .clear : .regular)
      glass.tintColor = tint
      // Flutter owns hit testing and pressure animation for this backdrop.
      glass.isInteractive = false
      return glass
    }
    #endif
    if reduced { return UIBlurEffect(style: .systemThickMaterial) }
    switch style {
    case "thin":
      return UIBlurEffect(style: .systemUltraThinMaterial)
    case "thick":
      return UIBlurEffect(style: .systemThickMaterial)
    default:
      return UIBlurEffect(style: .systemMaterial)
    }
  }

  private static func cornerRadius(from args: Any?) -> CGFloat {
    guard
      let params = args as? [String: Any],
      let value = params["cornerRadius"] as? NSNumber
    else {
      return 0
    }
    let radius = value.doubleValue
    return radius.isFinite ? CGFloat(max(0, radius)) : 0
  }
}
