import CoreFoundation
import Foundation

enum ShareInbox {
  enum Failure: Error { case unavailable, invalidItem, emptyShare }

  struct Entry: Codable {
    let id: UUID
    let text: String
    let files: [String]
  }

  private static let manager = FileManager.default

  private static var appGroup: String? {
    Bundle.main.object(forInfoDictionaryKey: "HermesShareAppGroup") as? String
  }

  static var changeNotification: CFNotificationName? {
    appGroup.map { CFNotificationName(rawValue: "\($0).incoming-shares.changed" as CFString) }
  }

  private static func root() throws -> URL {
    guard let group = appGroup,
          let container = manager.containerURL(forSecurityApplicationGroupIdentifier: group) else {
      throw Failure.unavailable
    }
    let directory = container.appendingPathComponent("IncomingShares", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private static func ready(_ id: UUID) throws -> URL {
    try root().appendingPathComponent(id.uuidString, isDirectory: true)
  }

  static func staging(_ id: UUID) throws -> URL {
    let directory = try root().appendingPathComponent(".\(id.uuidString)", isDirectory: true)
    try manager.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
  }

  static func publish(_ entry: Entry, from staging: URL) throws {
    guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !entry.files.isEmpty else { throw Failure.emptyShare }
    let data = try JSONEncoder().encode(entry)
    try data.write(to: staging.appendingPathComponent("entry.json"), options: .atomic)
    try manager.moveItem(at: staging, to: ready(entry.id))
    if let changeNotification {
      CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(), changeNotification, nil, nil, true
      )
    }
  }

  static func next() throws -> Entry? {
    let directories = try manager.contentsOfDirectory(
      at: root(), includingPropertiesForKeys: [.creationDateKey],
      options: [.skipsHiddenFiles]
    )
    let ready = directories.compactMap { directory -> (UUID, Date)? in
      guard let id = UUID(uuidString: directory.lastPathComponent),
            let date = try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate else {
        return nil
      }
      return (id, date)
    }.sorted { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 < $1.1 }
    for (id, _) in ready {
      if let item = try? entry(id) { return item }
    }
    return nil
  }

  private static func entry(_ id: UUID) throws -> Entry {
    let manifest = try ready(id).appendingPathComponent("entry.json")
    let item = try JSONDecoder().decode(Entry.self, from: Data(contentsOf: manifest))
    guard item.id == id else { throw Failure.invalidItem }
    return item
  }

  static func paths(_ id: UUID) throws -> [String] {
    let directory = try ready(id)
    return try entry(id).files.enumerated().map { index, name in
      guard name == cleanName(name), !name.isEmpty, name != ".", name != ".." else {
        throw Failure.invalidItem
      }
      let file = directory.appendingPathComponent(String(index), isDirectory: true)
        .appendingPathComponent(name, isDirectory: false)
      guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        throw Failure.invalidItem
      }
      return file.path
    }
  }

  static func finish(_ id: UUID) throws {
    try manager.removeItem(at: ready(id))
  }

  static func copyFile(_ source: URL, suggested: String?, suffix: String?,
                       into staging: URL, index: Int) throws -> String {
    let directory = staging.appendingPathComponent(String(index), isDirectory: true)
    return try stageFile(source, suggested: suggested, suffix: suffix, into: directory,
                         fallbackName: "attachment-\(index + 1)").lastPathComponent
  }

  static func stageFile(_ source: URL, suggested: String?, suffix: String?,
                        into directory: URL, fallbackName: String = "attachment") throws -> URL {
    guard source.isFileURL else { throw Failure.invalidItem }
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
    let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
    guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else {
      throw Failure.invalidItem
    }
    let candidates: [String?] = [suggested.map(cleanName), cleanName(source.lastPathComponent)]
    var name = candidates.compactMap { $0 }.first { !["", ".", ".."].contains($0) } ?? fallbackName
    if (name as NSString).pathExtension.isEmpty {
      let ext = source.pathExtension.isEmpty ? suffix : source.pathExtension
      if let ext, !ext.isEmpty { name += "." + cleanName(ext) }
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let staged = directory.appendingPathComponent(name)
    try manager.copyItem(at: source, to: staged)
    return staged
  }

  private static func cleanName(_ value: String) -> String {
    value.components(separatedBy: CharacterSet(charactersIn: "/\\").union(.controlCharacters))
      .joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
