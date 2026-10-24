import AVFoundation
import AetherEngine
import Combine
import Flutter
import UIKit

/// Flutter 平台视图工厂：viewType = lanplayer/aether
/// 与安卓的 NativeSurfaceEngine 通道语义保持一致（播放/暂停/拖动/倍速/音量/
/// 音轨/字幕轨/画幅/状态事件），只是底层换成 AetherEngine（FFmpeg 拆、Apple 播）。
final class AetherPlayerPlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    registrar.register(
      AetherPlayerViewFactory(messenger: registrar.messenger()),
      withId: "lanplayer/aether"
    )
  }
}

final class AetherPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let messenger: FlutterBinaryMessenger
  init(messenger: FlutterBinaryMessenger) {
    self.messenger = messenger
    super.init()
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) ->
    FlutterPlatformView
  {
    MainActor.assumeIsolated {
      AetherPlayerPlatformView(frame: frame, viewId: viewId, messenger: messenger, args: args)
    }
  }
}

@MainActor
final class AetherPlayerPlatformView: NSObject, FlutterPlatformView {
  private let controller: AetherPlayerController

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
    controller = AetherPlayerController(
      frame: frame, viewId: viewId, messenger: messenger, args: args)
    super.init()
  }

  nonisolated func view() -> UIView {
    MainActor.assumeIsolated { controller.container }
  }
}

@MainActor
final class AetherPlayerController: NSObject, FlutterStreamHandler {
  let container: UIView
  private let playerView = AetherPlayerView()
  private let overlay = AetherSubtitleOverlay()

  private let engine: AetherEngine?
  private let channel: FlutterMethodChannel
  private let eventChannel: FlutterEventChannel
  private var sink: FlutterEventSink?

  private var cancellables = Set<AnyCancellable>()
  private var ticker: Timer?
  private var isPlaying = false
  private var isBuffering = false
  private var hasFirstFrame = false
  private var durationMs: Int = 0
  private var speed: Double = 1.0
  private var volume: Double = 1.0
  private var fit: BoxFitMode = .contain
  private var errorText: String?
  private var disposed = false

  private enum BoxFitMode: String { case contain, cover, fill }

  init(frame: CGRect, viewId: Int64, messenger: FlutterBinaryMessenger, args: Any?) {
    container = UIView(frame: frame)
    container.backgroundColor = .black
    channel = FlutterMethodChannel(
      name: "lanplayer/aether_\(viewId)", binaryMessenger: messenger)
    eventChannel = FlutterEventChannel(
      name: "lanplayer/aether_events_\(viewId)", binaryMessenger: messenger)
    engine = try? AetherEngine()
    super.init()

    playerView.frame = container.bounds
    playerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    overlay.frame = container.bounds
    overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(playerView)
    container.addSubview(overlay)

    if let e = engine {
      e.bind(view: playerView)
      e.videoGravity = .resizeAspect
      e.volume = 1.0
      subscribe(e)
    }

    channel.setMethodCallHandler { [weak self] call, result in
      MainActor.assumeIsolated { self?.handle(call, result: result) }
    }
    eventChannel.setStreamHandler(self)

    ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.tick() }
    }

    if let e = engine {
      let options = (args as? [String: Any]) ?? [:]
      if let url = options["url"] as? String, !url.isEmpty {
        load(url: url, headers: options["headers"] as? [String: String],
             startMs: options["startMs"] as? Int ?? 0,
             autoplay: options["autoPlay"] as? Bool ?? true, result: nil)
      }
      _ = e
    }
  }

  // MARK: - 通道

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = (call.arguments as? [String: Any]) ?? [:]
    switch call.method {
    case "load":
      load(
        url: args["url"] as? String ?? "",
        headers: args["headers"] as? [String: String],
        startMs: args["startMs"] as? Int ?? 0,
        autoplay: args["autoPlay"] as? Bool ?? true,
        result: result)
    case "play":
      engine?.play()
      result(nil)
    case "pause":
      engine?.pause()
      result(nil)
    case "seek":
      let ms = args["positionMs"] as? Int ?? 0
      Task { [weak self] in
        await self?.engine?.seek(to: Double(ms) / 1000.0)
        if let self { self.sendState() }
      }
      result(nil)
    case "setSpeed":
      let v = (args["speed"] as? NSNumber)?.doubleValue ?? 1.0
      speed = v
      engine?.setRate(Float(v))
      result(nil)
    case "setVolume":
      let v = (args["volume"] as? NSNumber)?.doubleValue ?? 1.0
      volume = v
      engine?.volume = Float(v)
      result(nil)
    case "setFit":
      let mode = BoxFitMode(rawValue: args["mode"] as? String ?? "contain") ?? .contain
      fit = mode
      switch mode {
      case .contain: engine?.videoGravity = .resizeAspect
      case .cover: engine?.videoGravity = .resizeAspectFill
      case .fill: engine?.videoGravity = .resize
      }
      result(nil)
    case "selectAudio":
      let ordinal = args["index"] as? Int ?? -1
      if let e = engine, ordinal >= 0, ordinal < e.audioTracks.count {
        e.selectAudioTrack(index: e.audioTracks[ordinal].id)
      }
      result(nil)
    case "selectSubtitle":
      let ordinal = args["index"] as? Int ?? -1
      if let e = engine {
        if ordinal < 0 {
          e.clearSubtitle()
        } else if ordinal < e.subtitleTracks.count {
          e.selectSubtitleTrack(index: e.subtitleTracks[ordinal].id)
        }
      }
      result(nil)
    case "getTracks":
      result(tracksPayload())
    case "dispose":
      dispose()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func tracksPayload() -> [String: Any] {
    let e = engine
    let audio = (e?.audioTracks ?? []).map { t -> [String: Any] in
      [
        "index": t.id,
        "label": t.name.isEmpty ? t.codec : t.name,
        "language": t.language ?? "",
        "codec": t.codec,
        "isDefault": t.isDefault,
        "channels": t.channels,
      ]
    }
    let subs = (e?.subtitleTracks ?? []).map { t -> [String: Any] in
      [
        "index": t.id,
        "label": t.name.isEmpty ? t.codec : t.name,
        "language": t.language ?? "",
        "codec": t.codec,
        "isDefault": t.isDefault,
        "isBitmap": isBitmapCodec(t.codec),
      ]
    }
    return ["audio": audio, "subtitle": subs]
  }

  private func isBitmapCodec(_ codec: String) -> Bool {
    let c = codec.lowercased()
    return c.contains("pgs") || c.contains("dvdsub") || c.contains("dvb_subtitle")
      || c.contains("xsub")
  }

  // MARK: - 加载

  private func load(
    url: String, headers: [String: String]?, startMs: Int, autoplay: Bool,
    result: FlutterResult?
  ) {
    guard let e = engine, let u = URL(string: url) else {
      errorText = "播放地址无效"
      result?(nil)
      sendState()
      return
    }
    errorText = nil
    let options = LoadOptions(httpHeaders: headers ?? [:], autoplay: autoplay)
    Task { [weak self] in
      do {
        try await e.load(
          url: u, startPosition: startMs > 0 ? Double(startMs) / 1000.0 : nil,
          options: options)
      } catch {
        await MainActor.run {
          self?.errorText = error.localizedDescription
          self?.sendState()
        }
      }
    }
    result?(nil)
  }

  // MARK: - 状态与订阅

  private func subscribe(_ e: AetherEngine) {
    e.$state
      .receive(on: RunLoop.main)
      .sink { [weak self] state in
        MainActor.assumeIsolated {
        guard let self else { return }
        switch state {
        case .playing: self.isPlaying = true
        case .paused, .idle, .ended: self.isPlaying = false
        case .error(let message): self.isPlaying = false; self.errorText = message
        default: break
        }
        self.sendState()
        }
      }
      .store(in: &cancellables)
    e.$isBuffering.receive(on: RunLoop.main).sink { [weak self] v in
      MainActor.assumeIsolated { self?.isBuffering = v; self?.sendState() }
    }.store(in: &cancellables)
    e.$duration.receive(on: RunLoop.main).sink { [weak self] v in
      MainActor.assumeIsolated { self?.durationMs = Int(v * 1000); self?.sendState() }
    }.store(in: &cancellables)
    e.$hasFirstFrameReadyForDisplay.receive(on: RunLoop.main).sink { [weak self] v in
      MainActor.assumeIsolated { self?.hasFirstFrame = v; self?.sendState() }
    }.store(in: &cancellables)
    e.$subtitleCues.receive(on: RunLoop.main).sink { [weak self] cues in
      MainActor.assumeIsolated { self?.overlay.cues = cues }
    }.store(in: &cancellables)
  }

  private func tick() {
    if disposed { return }
    overlay.update(currentTime: engine?.currentTime ?? 0, bounds: container.bounds)
    sendState()
  }

  private func sendState() {
    guard !disposed, let sink else { return }
    if let e = engine { overlay.cues = e.subtitleCues }
    sink([
      "isPlaying": isPlaying,
      "isBuffering": isBuffering,
      "positionMs": Int((engine?.currentTime ?? 0) * 1000),
      "durationMs": durationMs,
      "speed": speed,
      "volume": volume,
      "hasFirstFrame": hasFirstFrame,
      "error": errorText ?? "",
    ])
  }

  nonisolated func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    MainActor.assumeIsolated {
      sink = events
      sendState()
    }
    return nil
  }

  nonisolated func onCancel(withArguments arguments: Any?) -> FlutterError? {
    MainActor.assumeIsolated { sink = nil }
    return nil
  }

  private func dispose() {
    guard !disposed else { return }
    disposed = true
    ticker?.invalidate()
    ticker = nil
    cancellables.removeAll()
    if let e = engine {
      e.pause()
      e.stop()
    }
  }

}

/// 原生字幕叠加层：文本用 UILabel，位图（PGS/DVB/DVD）用 UIImageView 按
/// 引擎给的归一化位置铺在视频区域上（canvasSize 与视频一致时直接按容器映射）。
final class AetherSubtitleOverlay: UIView {
  var cues: [SubtitleCue] = [] {
    didSet { setNeedsLayout() }
  }

  private let textLabel = UILabel()
  private let imageView = UIImageView()

  override init(frame: CGRect) {
    super.init(frame: frame)
    isUserInteractionEnabled = false
    backgroundColor = .clear
    textLabel.numberOfLines = 0
    textLabel.textAlignment = .center
    textLabel.textColor = .white
    textLabel.font = .systemFont(ofSize: 18, weight: .semibold)
    textLabel.layer.shadowColor = UIColor.black.cgColor
    textLabel.layer.shadowOpacity = 0.85
    textLabel.layer.shadowRadius = 2
    textLabel.layer.shadowOffset = .zero
    addSubview(textLabel)
    imageView.contentMode = .scaleAspectFit
    addSubview(imageView)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  func update(currentTime: Double, bounds: CGRect) {
    let active = cues.filter { $0.startTime <= currentTime && currentTime < $0.endTime }
    var texts: [String] = []
    var image: SubtitleImage?
    for cue in active {
      switch cue.body {
      case .text(let s): texts.append(s)
      case .richText(let runs): texts.append(runs.map(\.text).joined())
      case .image(let img): image = img
      }
    }
    let text = texts.joined(separator: "\n")
    if textLabel.text != text { textLabel.text = text }
    textLabel.isHidden = text.isEmpty
    if textLabel.isHidden == false {
      let width = bounds.width * 0.92
      let size = textLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
      textLabel.frame = CGRect(
        x: (bounds.width - width) / 2, y: bounds.height - size.height - bounds.height * 0.06,
        width: width, height: size.height)
    }
    if let img = image {
      imageView.isHidden = false
      imageView.image = UIImage(cgImage: img.cgImage)
      let rect = img.position
      imageView.frame = CGRect(
        x: rect.minX * bounds.width, y: rect.minY * bounds.height,
        width: rect.width * bounds.width, height: rect.height * bounds.height)
    } else {
      imageView.isHidden = true
    }
  }
}
