// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import AVFoundation

#if os(iOS)
  import Flutter
#elseif os(macOS)
  import FlutterMacOS
#else
  #error("Unsupported platform.")
#endif

#if canImport(video_player_avfoundation_objc)
  import video_player_avfoundation_objc
#endif

// Protocol for an display link factory. Used for injecting display links in tests.
protocol DisplayLinkFactory {
  func displayLink(
    with viewProvider: FVPViewProvider,
    callback: @escaping () -> Void
  ) -> FVPDisplayLink
}

/// Non-test implementation of the display link factory.
final class DefaultDisplayLinkFactory: DisplayLinkFactory {
  func displayLink(
    with viewProvider: FVPViewProvider,
    callback: @escaping () -> Void
  ) -> FVPDisplayLink {
    #if os(iOS)
      return FVPCADisplayLink(viewProvider: viewProvider, callback: callback)
    #elseif os(macOS)
      if #available(macOS 14.0, *) {
        return FVPCADisplayLink(viewProvider: viewProvider, callback: callback)
      }
      return FVPCoreVideoDisplayLink(viewProvider: viewProvider, callback: callback)
    #endif
  }
}

/// Non-test implementation of FVPAssetProvider, wrapping a Flutter plugin
/// registrar.
final class DefaultAssetProvider: NSObject, FVPAssetProvider {
  private weak var registrar: FlutterPluginRegistrar?

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  func lookupKey(forAsset asset: String) -> String? {
    return registrar?.lookupKey(forAsset: asset)
  }

  func lookupKey(forAsset asset: String, fromPackage package: String) -> String? {
    return registrar?.lookupKey(forAsset: asset, fromPackage: package)
  }
}

public final class VideoPlayerPlugin: NSObject, FlutterPlugin, AVFoundationVideoPlayerApi {
  private let binaryMessenger: FlutterBinaryMessenger
  private let textureRegistry: FlutterTextureRegistry
  private let displayLinkFactory: DisplayLinkFactory
  private let avFactory: FVPAVFactory
  private let viewProvider: FVPViewProvider
  private let assetProvider: FVPAssetProvider
  private var nextPlayerIdentifier: Int64 = 1
  var playersByIdentifier: [Int64: FVPVideoPlayer] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = VideoPlayerPlugin(registrar: registrar)
    // Publish the instance so that it receives detachFromEngine.
    registrar.publish(instance)
    #if os(iOS)
      let network = FlutterMethodChannel(name: "lumebox/av_network", binaryMessenger: registrar.messenger())
      network.setMethodCallHandler { [weak instance] call, result in
        guard ["readBytes", "applyBuffering", "readVideoState"].contains(call.method) else { result(FlutterMethodNotImplemented); return }
        guard let args = call.arguments as? [String: Any],
              let identifier = args["playerId"] as? NSNumber,
              let video = instance?.playersByIdentifier[identifier.int64Value], !video.disposed else {
          result(nil); return
        }
        if call.method == "readVideoState" {
          let layer = FVPNativeVideoView.layer(for: video.player)
          result(["inlineLayer": layer != nil,
                  "attached": layer?.superlayer != nil,
                  "readyForDisplay": layer?.isReadyForDisplay ?? false])
          return
        }
        if call.method == "applyBuffering" {
          let seconds = (args["seconds"] as? NSNumber)?.doubleValue ?? 0
          video.player.currentItem?.preferredForwardBufferDuration = max(0, seconds)
          video.player.automaticallyWaitsToMinimizeStalling = (args["wait"] as? NSNumber)?.boolValue ?? false
          result(nil); return
        }
        guard let events = video.player.currentItem?.accessLog()?.events, !events.isEmpty else {
          result(nil); return
        }
        let valid = events.filter { $0.numberOfBytesTransferred >= 0 }
        guard !valid.isEmpty else { result(nil); return }
        result(valid.reduce(Int64(0)) { $0 + $1.numberOfBytesTransferred })
      }
      let presentation = FlutterMethodChannel(name: "lumebox/av_presentation", binaryMessenger: registrar.messenger())
      presentation.setMethodCallHandler { [weak instance] call, result in
        guard let args = call.arguments as? [String: Any],
              let identifier = args["playerId"] as? NSNumber,
              let video = instance?.playersByIdentifier[identifier.int64Value], !video.disposed,
              let item = video.player.currentItem else { result(nil); return }
        LumePresentation.handle(call.method, args: args, player: video.player, item: item, result: result)
      }
      let pip = FlutterMethodChannel(name: "lumebox/av_pip", binaryMessenger: registrar.messenger())
      pip.setMethodCallHandler { [weak instance] call, result in
        guard call.method == "prepare" else { result(FlutterMethodNotImplemented); return }
        guard let args = call.arguments as? [String: Any],
              let identifier = args["playerId"] as? NSNumber,
              let video = instance?.playersByIdentifier[identifier.int64Value], !video.disposed else {
          result(false); return
        }
        let layer = FVPNativeVideoView.layer(for: video.player)
        NotificationCenter.default.post(name: Notification.Name("LumeBox.avplayer.pip"),
                                        object: video.player,
                                        userInfo: layer.map { ["playerLayer": $0] })
        result(true)
      }
    #endif

    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    let factory = NativeVideoViewFactory(
      messenger: messenger,
      playerByIdentifierProvider: {
        [weak instance] (playerIdentifier: Int64) -> FVPVideoPlayer? in
        return instance?.playersByIdentifier[playerIdentifier]
      }
    )
    registrar.register(factory, withId: "plugins.flutter.dev/video_player_ios")

    AVFoundationVideoPlayerApiSetup.setUp(binaryMessenger: messenger, api: instance)
  }

  convenience init(registrar: FlutterPluginRegistrar) {
    #if os(iOS)
      let messenger = registrar.messenger()
      let textures = registrar.textures()
    #else
      let messenger = registrar.messenger
      let textures = registrar.textures
    #endif
    self.init(
      avFactory: FVPDefaultAVFactory(),
      displayLinkFactory: DefaultDisplayLinkFactory(),
      binaryMessenger: messenger,
      textureRegistry: textures,
      viewProvider: FVPDefaultViewProvider(registrar: registrar),
      assetProvider: DefaultAssetProvider(registrar: registrar)
    )
  }

  init(
    avFactory: FVPAVFactory,
    displayLinkFactory: DisplayLinkFactory,
    binaryMessenger: FlutterBinaryMessenger,
    textureRegistry: FlutterTextureRegistry,
    viewProvider: FVPViewProvider,
    assetProvider: FVPAssetProvider
  ) {
    self.binaryMessenger = binaryMessenger
    self.textureRegistry = textureRegistry
    self.assetProvider = assetProvider
    self.viewProvider = viewProvider
    self.displayLinkFactory = displayLinkFactory
    self.avFactory = avFactory
    super.init()
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    for player in playersByIdentifier.values {
      // Remove the channel and texture cleanup, and the event listener, to ensure that the player
      // doesn't message the engine that is no longer connected.
      player.onDisposed = nil
      player.eventListener = nil
      var error: FlutterError?
      player.disposeWithError(&error)
    }
    playersByIdentifier.removeAll()
    #if os(iOS)
      let messenger = registrar.messenger()
    #else
      let messenger = registrar.messenger
    #endif
    AVFoundationVideoPlayerApiSetup.setUp(binaryMessenger: messenger, api: nil)
  }

  func initialize() throws {
    #if os(iOS)
      // Allow audio playback when the Ring/Silent switch is set to silent
      upgradeAudioSessionCategory(
        session: avFactory.sharedAudioSession(),
        requestedCategory: .playback,
        options: [],
        clearOptions: []
      )
    #endif

    for player in playersByIdentifier.values {
      var error: FlutterError?
      player.disposeWithError(&error)
    }
    playersByIdentifier.removeAll()
  }

  func createPlatformViewPlayer(options params: CreationOptions) throws -> Int64 {
    let item = try playerItem(with: params)
    let player = FVPVideoPlayer(playerItem: item, avFactory: avFactory, viewProvider: viewProvider)
    return configurePlayer(player, extraDisposeHandler: nil)
  }

  func createTexturePlayer(options creationOptions: CreationOptions) throws -> TexturePlayerIds {
    let item = try playerItem(with: creationOptions)
    let frameUpdater = FVPFrameUpdater(registry: textureRegistry)
    let displayLink = displayLinkFactory.displayLink(with: viewProvider) {
      frameUpdater.displayLinkFired()
    }

    let player = FVPTextureBasedVideoPlayer(
      playerItem: item,
      frameUpdater: frameUpdater,
      displayLink: displayLink,
      avFactory: avFactory,
      viewProvider: viewProvider
    )

    let textureId = textureRegistry.register(player)
    player.setTextureIdentifier(textureId)

    let playerId = configurePlayer(player) { [weak self] in
      self?.textureRegistry.unregisterTexture(textureId)
    }

    return TexturePlayerIds(playerId: playerId, textureId: textureId)
  }

  func setMixWithOthers(_ mixWithOthers: Bool) throws {
    #if os(iOS)
      let session = avFactory.sharedAudioSession()
      if mixWithOthers {
        upgradeAudioSessionCategory(
          session: session,
          requestedCategory: session.category,
          options: .mixWithOthers,
          clearOptions: []
        )
      } else {
        upgradeAudioSessionCategory(
          session: session,
          requestedCategory: session.category,
          options: [],
          clearOptions: .mixWithOthers
        )
      }
    #endif
    // AVAudioSession doesn't exist on macOS, and audio always mixes, so just no-op.
  }

  func fileURLForAsset(name asset: String, package: String?) throws -> String? {
    let resource =
      if let package = package {
        assetProvider.lookupKey(forAsset: asset, fromPackage: package)
      } else {
        assetProvider.lookupKey(forAsset: asset)
      }

    var path = Bundle.main.path(forResource: resource, ofType: nil)
    #if os(macOS)
      // See https://github.com/flutter/flutter/issues/135302
      // TODO(stuartmorgan): Remove this if the asset APIs are adjusted to work better for macOS.
      if path == nil, let resource = resource {
        path = URL(string: resource, relativeTo: Bundle.main.bundleURL)?.path
      }
    #endif

    guard let validPath = path else {
      return nil
    }
    return URL(fileURLWithPath: validPath).absoluteString
  }

  // MARK: - Private

  private func configurePlayer(
    _ player: FVPVideoPlayer,
    extraDisposeHandler: (() -> Void)?
  ) -> Int64 {
    let playerId = nextPlayerIdentifier
    nextPlayerIdentifier += 1
    playersByIdentifier[playerId] = player

    let channelSuffix = "\(playerId)"
    // Set up the player-specific API handler, and its onDispose unregistration.
    SetUpFVPVideoPlayerInstanceApiWithSuffix(binaryMessenger, player, channelSuffix)

    player.onDisposed = { [weak self] in
      guard let strongSelf = self else { return }
      SetUpFVPVideoPlayerInstanceApiWithSuffix(strongSelf.binaryMessenger, nil, channelSuffix)
      extraDisposeHandler?()
      strongSelf.playersByIdentifier.removeValue(forKey: playerId)
    }

    // Set up the event channel.
    let eventBridge = FVPEventBridge(
      messenger: binaryMessenger,
      channelName: "flutter.dev/videoPlayer/videoEvents\(channelSuffix)"
    )
    player.eventListener = eventBridge

    return playerId
  }

  private func playerItem(with options: CreationOptions) throws -> FVPAVPlayerItem {
    let headers = options.httpHeaders
    let itemOptions = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
    guard let url = URL(string: options.uri) else {
      throw PigeonError(code: "video_player", message: "Invalid URI", details: nil)
    }
    let asset = avFactory.urlAsset(with: url, options: itemOptions)
    return avFactory.playerItem(with: asset)
  }
}

#if os(iOS)
  // This function, although slightly modified, is also in camera_avfoundation.
  // Both need to do the same thing and run on the same thread (for example main thread).
  // Do not overwrite PlayAndRecord with Playback which causes inability to record
  // audio, do not overwrite all options.
  // Only change category if it is considered an upgrade which means it can only enable
  // ability to play in silent mode or ability to record audio but never disables it,
  // that could affect other plugins which depend on this global state. Only change
  // category or options if there is change to prevent unnecessary lags and silence.
  private func upgradeAudioSessionCategory(
    session: FVPAVAudioSession,
    requestedCategory: AVAudioSession.Category,
    options: AVAudioSession.CategoryOptions,
    clearOptions: AVAudioSession.CategoryOptions
  ) {
    let playCategories: Set<AVAudioSession.Category> = [.playback, .playAndRecord]
    let recordCategories: Set<AVAudioSession.Category> = [.record, .playAndRecord]
    let requiredCategories: Set<AVAudioSession.Category> = [requestedCategory, session.category]

    let requiresPlay = !requiredCategories.isDisjoint(with: playCategories)
    let requiresRecord = !requiredCategories.isDisjoint(with: recordCategories)

    var finalCategory = requestedCategory
    if requiresPlay && requiresRecord {
      finalCategory = .playAndRecord
    } else if requiresPlay {
      finalCategory = .playback
    } else if requiresRecord {
      finalCategory = .record
    }

    let newOptions = session.categoryOptions.subtracting(clearOptions).union(options)

    if finalCategory == session.category && newOptions == session.categoryOptions {
      return
    }

    try? session.setCategory(finalCategory, with: newOptions)
  }
#endif

#if os(iOS)
/// Operates on the existing player; it never opens a second playback session.
private enum LumePresentation {
  static func fourCC(_ value: FourCharCode) -> String {
    String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "unknown"
  }
  static func audioCodecs(_ option: AVMediaSelectionOption) -> [String] {
    option.mediaSubTypes.map { fourCC($0.uint32Value) }
  }
  static func handle(_ method: String, args: [String: Any], player: AVPlayer, item: AVPlayerItem, result: @escaping FlutterResult) {
    Task { @MainActor in
      await handleAsync(method, args: args, player: player, item: item, result: result)
    }
  }

  @MainActor
  private static func handleAsync(_ method: String, args: [String: Any], player: AVPlayer, item: AVPlayerItem, result: FlutterResult) async {
    // Asset inspection may fetch HLS metadata. Never synchronously load it on
    // the platform thread, and never inspect subtitle groups for status polls.
    var group: AVMediaSelectionGroup?
    if ["subtitleTracks", "selectSubtitle", "configure"].contains(method) {
      group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
    }
    guard player.currentItem === item else { result(nil); return }
    switch method {
    case "subtitleTracks":
      guard let group = group else { result([]); return }
      let selected = item.currentMediaSelection.selectedMediaOption(in: group)
      result(group.options.enumerated().map { index, option -> [String: Any] in
        ["id": String(index), "label": option.displayName,
         "language": option.extendedLanguageTag ?? option.locale?.identifier ?? "",
         "selected": selected == option]
      })
    case "selectSubtitle":
      guard let group = group else { result(nil); return }
      let index = (args["id"] as? String).flatMap(Int.init)
      if let index = index, group.options.indices.contains(index) { item.select(group.options[index], in: group) }
      else { item.select(nil, in: group) }
      result(nil)
    case "configure":
      if let group = group {
        if args["subtitlesEnabled"] as? Bool == false { item.select(nil, in: group) }
        else if item.currentMediaSelection.selectedMediaOption(in: group) == nil {
          item.select(group.defaultOption ?? group.options.first, in: group)
        }
      }
      if args["originalStyle"] as? Bool == false {
        let color = (args["color"] as? NSNumber)?.uint32Value ?? 0xffffffff
        let rgba: [Double] = [Double((color >> 16) & 255) / 255, Double((color >> 8) & 255) / 255, Double(color & 255) / 255, Double((color >> 24) & 255) / 255]
        var attributes: [String: Any] = [
          kCMTextMarkupAttribute_ForegroundColorARGB as String: [rgba[3], rgba[0], rgba[1], rgba[2]],
          kCMTextMarkupAttribute_BackgroundColorARGB as String: [(args["background"] as? Double) ?? 0.45, 0, 0, 0],
          kCMTextMarkupAttribute_RelativeFontSize as String: ((args["fontSize"] as? Double) ?? 24) / 24 * 100
        ]
        if let font = args["font"] as? String, !font.isEmpty { attributes[kCMTextMarkupAttribute_FontFamilyName as String] = font }
        item.textStyleRules = AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] } ?? []
      } else { item.textStyleRules = [] }
      if args["selectAudio"] as? Bool == true,
         let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
        guard player.currentItem === item else { result(nil); return }
        let preferDolby = args["dolbyAudio"] as? Bool != false
        let option = audio.options.first { option in
          let dolby = audioCodecs(option).contains { ["ac-3", "ec-3", "ac-4"].contains($0) }
          return dolby == preferDolby
        }
        if let option = option, item.currentMediaSelection.selectedMediaOption(in: audio) != option {
          item.select(option, in: audio)
        }
      }
      result(nil)
    case "status":
      var status: [String] = []
      if let track = (try? await item.asset.loadTracks(withMediaType: .video))?.first,
         let descriptions = try? await track.load(.formatDescriptions),
         let description = descriptions.first {
        let codec = fourCC(CMFormatDescriptionGetMediaSubType(description))
        let transfer = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String ?? ""
        let hdr = track.hasMediaCharacteristic(.containsHDRVideo)
        let atoms = CMFormatDescriptionGetExtension(description, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] ?? [:]
        let dolby = ["dvh1", "dvhe"].contains(codec) || atoms["dvcC"] != nil || atoms["dvvC"] != nil
        let type = dolby ? "Dolby Vision" : transfer.contains("2084") ? "HDR（PQ）" : transfer.contains("HLG") ? "HLG" : hdr ? "HDR" : "SDR"
        status.append("片源：\(type) · \(codec.uppercased())")
      }
      status.append(AVPlayer.eligibleForHDRPlayback ? "设备：具备 HDR 播放条件" : "设备：当前无 HDR 播放条件")
      if let audio = try? await item.asset.loadMediaSelectionGroup(for: .audible),
         let selected = item.currentMediaSelection.selectedMediaOption(in: audio) {
        status.append("音轨：\(selected.displayName) · \(audioCodecs(selected).joined(separator: "/"))")
      }
      let route = AVAudioSession.sharedInstance().currentRoute.outputs
      status.append("输出设备：\(route.map { $0.portName }.joined(separator: " / "))")
      status.append(route.contains { $0.isSpatialAudioEnabled } ? "系统空间音频：可用且用户已允许（不代表 Atmos 音轨）" : "系统空间音频：当前未启用")
      result(status)
    default: result(FlutterMethodNotImplemented)
    }
  }
}
#endif
