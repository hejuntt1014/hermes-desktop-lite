import CoreFoundation
import Flutter
import SafariServices
import UIKit
import UniformTypeIdentifiers
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate, UIDocumentPickerDelegate,
                        SFSafariViewControllerDelegate {
  private var exportReply: FlutterResult?
  private var notificationChannel: FlutterMethodChannel?
  private var openedNotification: String?
  private var lastOpenedNotification: String?
  private var fileDrop: MobileFileDrop?
  private var incomingSharesChannel: FlutterMethodChannel?
  private var incomingSharesNotification: CFNotificationName?
  private var loginBrowser: (url: URL, view: SFSafariViewController, reply: FlutterResult)?

  deinit {
    if let incomingSharesNotification {
      CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
        incomingSharesNotification, nil
      )
    }
  }

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let drop = engineBridge.pluginRegistry.registrar(forPlugin: "HermesMobileFileDrop") {
      fileDrop = MobileFileDrop(registrar: drop)
    }
    if let shares = engineBridge.pluginRegistry.registrar(forPlugin: "HermesMobileShares") {
      let channel = FlutterMethodChannel(
        name: "hermes_lite/incoming_share", binaryMessenger: shares.messenger()
      )
      channel.setMethodCallHandler { call, reply in
        do {
          switch call.method {
          case "peek":
            guard let item = try? ShareInbox.next() else {
              reply(nil)
              return
            }
            reply(["id": item.id.uuidString.lowercased(), "text": item.text,
                   "files": item.files.count])
          case "copy", "finish":
            guard let args = call.arguments as? [String: Any],
                  let rawID = args["id"] as? String, let id = UUID(uuidString: rawID) else {
              throw ShareInbox.Failure.invalidItem
            }
            if call.method == "copy" {
              reply(try ShareInbox.paths(id))
            } else {
              if args["consumed"] as? Bool == true { try ShareInbox.finish(id) }
              reply(nil)
            }
          default:
            reply(FlutterMethodNotImplemented)
          }
        } catch {
          reply(FlutterError(code: "share_unavailable", message: nil, details: nil))
        }
      }
      observeIncomingShares(channel)
    }
    if let login = engineBridge.pluginRegistry.registrar(forPlugin: "HermesMobileLoginBrowser") {
      let channel = FlutterMethodChannel(name: "hermes_lite/login_browser", binaryMessenger: login.messenger())
      channel.setMethodCallHandler { [weak self] call, reply in
        guard let self else {
          reply(FlutterError(code: "unavailable", message: nil, details: nil))
          return
        }
        self.handleLoginBrowser(call, reply: reply)
      }
    }
    if let alerts = engineBridge.pluginRegistry.registrar(forPlugin: "HermesMobileNotifications") {
      let channel = FlutterMethodChannel(name: "hermes_lite/notifications", binaryMessenger: alerts.messenger())
      notificationChannel = channel
      channel.setMethodCallHandler { [weak self] call, reply in
        guard let self else {
          reply(FlutterError(code: "unavailable", message: nil, details: nil))
          return
        }
        self.handleNotification(call, reply: reply)
      }
    }
    guard let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "HermesFileExport")
    else { return }
    FlutterMethodChannel(name: "hermes_lite/file_export", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [weak self] call, reply in
        guard call.method == "save" else {
          reply(FlutterMethodNotImplemented)
          return
        }
        self?.presentExport(call, reply: reply)
      }
    FlutterMethodChannel(name: "hermes_lite/image_clipboard", binaryMessenger: registrar.messenger())
      .setMethodCallHandler { [weak self] call, reply in
        guard let self else {
          reply(FlutterError(code: "clipboard_unavailable", message: nil, details: nil))
          return
        }
        self.readClipboardImages(call, reply: reply)
      }
  }

  private var modalPresenter: UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.windows }
      .flatMap { $0 }
    guard var presenter = windows.first(where: { $0.isKeyWindow })?.rootViewController else {
      return nil
    }
    while let next = presenter.presentedViewController { presenter = next }
    return presenter
  }

  private func observeIncomingShares(_ channel: FlutterMethodChannel) {
    incomingSharesChannel = channel
    guard incomingSharesNotification == nil, let name = ShareInbox.changeNotification else { return }
    incomingSharesNotification = name
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDarwinNotifyCenter(), Unmanaged.passUnretained(self).toOpaque(),
      { _, observer, _, _, _ in
        guard let observer else { return }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async { [weak delegate] in
          delegate?.incomingSharesChannel?.invokeMethod("changed", arguments: nil)
        }
      },
      name.rawValue, nil, .deliverImmediately
    )
  }

  private func handleLoginBrowser(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    guard let raw = call.arguments as? String, let url = URL(string: raw) else {
      reply(FlutterError(code: "invalid_url", message: nil, details: nil))
      return
    }
    switch call.method {
    case "open":
      guard loginBrowser == nil, let presenter = modalPresenter else {
        reply("unavailable")
        return
      }
      // Keep the loopback listener active while the system browser displays authorization.
      let browser = SFSafariViewController(url: url)
      browser.delegate = self
      loginBrowser = (url, browser, reply)
      presenter.present(browser, animated: true)
    case "close":
      if let attempt = loginBrowser, attempt.url == url {
        loginBrowser = nil
        attempt.view.dismiss(animated: true)
        attempt.reply("closed")
      }
      reply(nil)
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
    guard let attempt = loginBrowser, attempt.view === controller else { return }
    loginBrowser = nil
    attempt.reply("cancelled")
  }

  private enum ClipboardImage {
    case encoded(Data)
    case bitmap(UIImage)
  }

  private func readClipboardImages(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    guard call.method == "readImages" else {
      reply(FlutterMethodNotImplemented)
      return
    }
    let manager = FileManager.default
    guard let args = call.arguments as? [String: Any],
          let path = args["directory"] as? String,
          let limit = args["limit"] as? Int, (0...10).contains(limit) else {
      reply(FlutterError(code: "clipboard_unavailable", message: nil, details: nil))
      return
    }
    let directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
    let temporaryRoots = manager.urls(for: .cachesDirectory, in: .userDomainMask)
      + [manager.temporaryDirectory]
    guard directory.lastPathComponent.hasPrefix("hermes-clipboard-"),
          temporaryRoots.contains(where: {
            $0.resolvingSymlinksInPath().path == directory.deletingLastPathComponent().path
          }) else {
      reply(FlutterError(code: "clipboard_unavailable", message: nil, details: nil))
      return
    }

    let clipboard = UIPasteboard.general
    guard clipboard.hasImages else {
      reply([String]())
      return
    }
    let originalTypes = [UTType.png.identifier, UTType.jpeg.identifier,
                         "org.webmproject.webp", UTType.gif.identifier]
    var images: [ClipboardImage] = clipboard.items.compactMap { item in
      let imageTypes = originalTypes + item.keys.filter {
        !originalTypes.contains($0) && UTType($0)?.conforms(to: .image) == true
      }.sorted()
      for type in imageTypes {
        if let bytes = item[type] as? Data, !bytes.isEmpty { return .encoded(bytes) }
        if let image = item[type] as? UIImage { return .bitmap(image) }
      }
      return nil
    }
    if images.isEmpty { images = (clipboard.images ?? []).map(ClipboardImage.bitmap) }
    guard !images.isEmpty, images.count <= limit else {
      let code = images.isEmpty ? "clipboard_unavailable" : "too_many_images"
      reply(FlutterError(code: code, message: nil, details: nil))
      return
    }
    let representations = images
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        var names: [String] = []
        for (index, image) in representations.enumerated() {
          let bytes: Data?
          switch image {
          case .encoded(let original): bytes = original
          case .bitmap(let bitmap): bytes = bitmap.pngData()
          }
          guard let bytes, !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
          let name = "clipboard-\(index + 1)"
          try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
          names.append(name)
        }
        DispatchQueue.main.async { reply(names) }
      } catch {
        DispatchQueue.main.async {
          reply(FlutterError(code: "clipboard_unavailable", message: nil, details: nil))
        }
      }
    }
  }

  private func handleNotification(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    let center = UNUserNotificationCenter.current()
    switch call.method {
    case "status":
      center.getNotificationSettings { settings in
        DispatchQueue.main.async {
          reply(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
        }
      }
    case "request":
      center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async { reply(granted) }
      }
    case "settings":
      let settings: String
      if #available(iOS 16.0, *) {
        settings = UIApplication.openNotificationSettingsURLString
      } else {
        settings = UIApplication.openSettingsURLString
      }
      if let url = URL(string: settings) {
        UIApplication.shared.open(url)
      }
      reply(nil)
    case "post":
      guard let args = call.arguments as? [String: String],
            let id = args["id"], let title = args["title"], let body = args["body"] else {
        reply(false)
        return
      }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      content.userInfo = ["hermesLocal": true]
      if let route = args["route"] { content.userInfo["route"] = route }
      center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { error in
        DispatchQueue.main.async { reply(error == nil) }
      }
    case "remove":
      if let id = call.arguments as? String {
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
      }
      reply(nil)
    case "takeOpened":
      let route = openedNotification
      openedNotification = nil
      reply(route)
    default:
      reply(FlutterMethodNotImplemented)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if notification.request.content.userInfo["hermesLocal"] as? Bool == true {
      completionHandler([.banner, .list, .sound])
    } else {
      super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let info = response.notification.request.content.userInfo
    guard info["hermesLocal"] as? Bool == true else {
      super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
      return
    }
    DispatchQueue.main.async { [weak self] in
      self?.captureNotificationResponse(response)
      completionHandler()
    }
  }

  func captureNotificationResponse(_ response: UNNotificationResponse) {
    let info = response.notification.request.content.userInfo
    guard info["hermesLocal"] as? Bool == true,
          response.actionIdentifier == UNNotificationDefaultActionIdentifier,
          let route = info["route"] as? String,
          !route.isEmpty,
          lastOpenedNotification != route else {
      return
    }
    lastOpenedNotification = route
    openedNotification = route
    notificationChannel?.invokeMethod("opened", arguments: nil)
  }

  private func presentExport(_ call: FlutterMethodCall, reply: @escaping FlutterResult) {
    guard exportReply == nil else {
      reply(FlutterError(code: "export_in_progress", message: nil, details: nil))
      return
    }
    guard let path = (call.arguments as? [String: String])?["file"],
          FileManager.default.isReadableFile(atPath: path) else {
      reply(FlutterError(code: "file_unavailable", message: nil, details: nil))
      return
    }
    guard let presenter = modalPresenter else {
      reply(FlutterError(code: "picker_unavailable", message: nil, details: nil))
      return
    }
    let picker = UIDocumentPickerViewController(forExporting: [URL(fileURLWithPath: path)], asCopy: true)
    picker.delegate = self
    exportReply = reply
    presenter.present(picker, animated: true)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    completeExport(!urls.isEmpty)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    completeExport(false)
  }

  private func completeExport(_ saved: Bool) {
    let reply = exportReply
    exportReply = nil
    reply?(saved)
  }
}
