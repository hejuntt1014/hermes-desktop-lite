import Flutter
import UIKit
import UniformTypeIdentifiers

final class MobileFileDrop: NSObject, UIDropInteractionDelegate {
  private struct Target {
    let id: Int
    let bounds: CGRect
  }

  private struct Drop {
    let folder: URL
    var paths: [String?]
    var remaining: Int
  }

  private let channel: FlutterMethodChannel
  private weak var registrar: FlutterPluginRegistrar?
  private var interaction: UIDropInteraction?
  private var target: Target?
  private var hoveredID: Int?
  private var reading: [Int: Drop] = [:]

  init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    channel = FlutterMethodChannel(name: "hermes_lite/file_drop", binaryMessenger: registrar.messenger())
    super.init()
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self, call.method == "target",
            let args = call.arguments as? [String: Any], let id = args["id"] as? Int
      else {
        reply(FlutterMethodNotImplemented)
        return
      }
      self.setTarget(id, args: args)
      reply(nil)
    }
  }

  private func setTarget(_ id: Int, args: [String: Any]) {
    guard let left = args["left"] as? Double, let top = args["top"] as? Double,
          let right = args["right"] as? Double, let bottom = args["bottom"] as? Double,
          [left, top, right, bottom].allSatisfy(\.isFinite), right > left, bottom > top
    else {
      if target?.id == id {
        target = nil
        hover(nil)
      }
      return
    }
    if let view = registrar?.viewController?.viewIfLoaded, interaction?.view !== view {
      if let interaction { interaction.view?.removeInteraction(interaction) }
      let next = UIDropInteraction(delegate: self)
      view.addInteraction(next)
      interaction = next
    }
    if target?.id != id { hover(nil) }
    target = Target(id: id, bounds: CGRect(x: left, y: top, width: right - left, height: bottom - top))
  }

  private func hover(_ id: Int?) {
    guard id != hoveredID else { return }
    if let hoveredID { channel.invokeMethod("hover", arguments: ["id": hoveredID, "on": false]) }
    hoveredID = id
    if let id { channel.invokeMethod("hover", arguments: ["id": id, "on": true]) }
  }

  private func owner(for session: UIDropSession, in interaction: UIDropInteraction) -> Int? {
    guard let target, let view = interaction.view, reading[target.id] == nil,
          target.bounds.contains(session.location(in: view))
    else { return nil }
    return target.id
  }

  private static func fileType(_ provider: NSItemProvider) -> UTType? {
    let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
    if types.contains(where: { $0.conforms(to: .directory) }) { return nil }
    if types.contains(.fileURL), provider.canLoadObject(ofClass: NSURL.self) { return .fileURL }
    return fileRepresentation(types)
  }

  private nonisolated static func fileRepresentation(_ types: [UTType]) -> UTType? {
    let data = types.filter { $0.conforms(to: .data) && !$0.conforms(to: .url) }
    return data.first(where: { $0 != .data }) ?? data.first
  }

  func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
    target != nil && session.localDragSession == nil && !session.items.isEmpty &&
      session.items.allSatisfy { Self.fileType($0.itemProvider) != nil }
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession) -> UIDropProposal {
    let id = dropInteraction(interaction, canHandle: session) ? owner(for: session, in: interaction) : nil
    hover(id)
    return UIDropProposal(operation: id == nil ? .cancel : .copy)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidExit session: UIDropSession) {
    hover(nil)
  }

  func dropInteraction(_ interaction: UIDropInteraction, sessionDidEnd session: UIDropSession) {
    hover(nil)
  }

  func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
    hover(nil)
    guard session.localDragSession == nil, let id = owner(for: session, in: interaction) else { return }
    let items = session.items.compactMap { item -> (NSItemProvider, UTType)? in
      let provider = item.itemProvider
      return Self.fileType(provider).map { (provider, $0) }
    }
    guard !items.isEmpty, items.count == session.items.count else { return }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-drop-\(UUID())", isDirectory: true)
    reading[id] = Drop(folder: folder, paths: .init(repeating: nil, count: items.count), remaining: items.count)
    channel.invokeMethod("reading", arguments: ["id": id])
    for (index, (provider, type)) in items.enumerated() {
      let parent = folder.appendingPathComponent(String(index), isDirectory: true)
      Self.load(provider, type: type, into: parent) { [weak self] path in
        DispatchQueue.main.async {
          self?.finishItem(path, index: index, id: id)
        }
      }
    }
  }

  private func finishItem(_ path: String?, index: Int, id: Int) {
    guard var drop = reading[id] else { return }
    drop.paths[index] = path
    drop.remaining -= 1
    reading[id] = drop
    guard drop.remaining == 0 else { return }
    let files = drop.paths.compactMap { $0 }
    let complete = files.count == drop.paths.count
    var arguments: [String: Any] = ["id": id]
    if complete { arguments["paths"] = files }
    channel.invokeMethod(complete ? "files" : "failed", arguments: arguments) { [weak self] _ in
      self?.reading.removeValue(forKey: id)
      try? FileManager.default.removeItem(at: drop.folder)
    }
  }

  private nonisolated static func load(_ provider: NSItemProvider, type: UTType, into parent: URL,
                                       completion: @escaping (String?) -> Void) {
    let suggested = provider.suggestedName
    if type == .fileURL {
      provider.loadObject(ofClass: NSURL.self) { object, _ in
        if let source = object as? URL,
           let staged = try? ShareInbox.stageFile(source, suggested: suggested, suffix: nil, into: parent) {
          completion(staged.path)
        } else if let fallback = fileRepresentation(provider.registeredTypeIdentifiers.compactMap { UTType($0) }) {
          load(provider, type: fallback, into: parent, completion: completion)
        } else {
          completion(nil)
        }
      }
    } else {
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { source, _ in
        // The item's temporary representation is removed as soon as this callback returns.
        completion(source.flatMap {
          try? ShareInbox.stageFile($0, suggested: suggested, suffix: type.preferredFilenameExtension,
                                    into: parent).path
        })
      }
    }
  }
}
