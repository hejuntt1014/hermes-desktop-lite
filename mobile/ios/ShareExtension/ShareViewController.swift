import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private let detail = UILabel()
  private let save = UIButton(type: .system)
  private let cancel = UIButton(type: .system)
  private var saved = false

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .systemBackground

    let title = UILabel()
    title.text = NSLocalizedString("Save to Hermes Lite", comment: "")
    title.font = .preferredFont(forTextStyle: .title2)
    title.adjustsFontForContentSizeCategory = true
    title.numberOfLines = 0

    detail.text = NSLocalizedString("Add the shared content to a draft in Hermes Lite.", comment: "")
    detail.font = .preferredFont(forTextStyle: .body)
    detail.adjustsFontForContentSizeCategory = true
    detail.textColor = .secondaryLabel
    detail.numberOfLines = 0

    save.configuration = .filled()
    save.setTitle(NSLocalizedString("Save", comment: ""), for: .normal)
    save.addTarget(self, action: #selector(saveShare), for: .touchUpInside)
    cancel.setTitle(NSLocalizedString("Cancel", comment: ""), for: .normal)
    cancel.addTarget(self, action: #selector(cancelShare), for: .touchUpInside)

    let scroll = UIScrollView()
    scroll.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scroll)
    let stack = UIStackView(arrangedSubviews: [title, detail, save, cancel])
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .vertical
    stack.spacing = 14
    scroll.addSubview(stack)
    let safe = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      scroll.topAnchor.constraint(equalTo: safe.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
      scroll.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
      scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
      stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
      stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
      stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
      stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      stack.widthAnchor.constraint(lessThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
      save.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
      cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
    ])
    let width = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
    width.priority = .defaultHigh
    width.isActive = true
    preferredContentSize = CGSize(width: 420, height: 260)
  }

  @objc private func saveShare() {
    if saved {
      extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
      return
    }
    guard let context = extensionContext else { return }
    save.isEnabled = false
    cancel.isEnabled = false
    isModalInPresentation = true
    save.configuration?.showsActivityIndicator = true

    Task {
      defer {
        save.configuration?.showsActivityIndicator = false
        save.isEnabled = true
        cancel.isEnabled = true
        isModalInPresentation = false
      }
      do {
        try await SharedItems.save(context.inputItems.compactMap { $0 as? NSExtensionItem })
        saved = true
        detail.text = NSLocalizedString("Open Hermes Lite to add the share to a draft.", comment: "")
        detail.textColor = .secondaryLabel
        save.setTitle(NSLocalizedString("Done", comment: ""), for: .normal)
        cancel.isHidden = true
      } catch {
        detail.text = NSLocalizedString("Could not save the shared content.", comment: "")
        detail.textColor = .systemRed
      }
    }
  }

  @objc private func cancelShare() {
    extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
  }
}

private enum SharedItems {
  private enum Value { case text(String), file(String) }

  static func save(_ items: [NSExtensionItem]) async throws {
    let id = UUID()
    let staging = try ShareInbox.staging(id)
    do {
      var text: [String] = []
      var files: [String] = []
      for item in items {
        if let description = item.attributedContentText?.string, !description.isEmpty {
          text.append(description)
        }
        for provider in item.attachments ?? [] {
          switch try await load(provider, staging: staging, index: files.count) {
          case .text(let content): text.append(content)
          case .file(let name): files.append(name)
          }
        }
      }
      var seen = Set<String>()
      let body = text.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
      try ShareInbox.publish(.init(id: id, text: body, files: files), from: staging)
    } catch {
      try? FileManager.default.removeItem(at: staging)
      throw error
    }
  }

  private static func load(_ provider: NSItemProvider, staging: URL, index: Int) async throws -> Value {
    let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
    let data = types.filter { $0.conforms(to: .data) && !$0.conforms(to: .url) }
    let fileRepresentation = data.first(where: { $0 != .data }) ?? data.first
    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
      do {
        return try await loadItem(provider, as: .fileURL) { item in
          guard let url = item as? URL else { throw ShareInbox.Failure.invalidItem }
          return .file(try ShareInbox.copyFile(url, suggested: provider.suggestedName, suffix: nil,
                                              into: staging, index: index))
        }
      } catch {
        guard let fileRepresentation else { throw error }
        return try await loadFile(provider, as: fileRepresentation, into: staging, index: index)
      }
    }
    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      return try await loadItem(provider, as: .url) { item in
        let url = (item as? URL) ?? (item as? String).flatMap { URL(string: $0) }
        guard let url else { throw ShareInbox.Failure.invalidItem }
        if url.isFileURL {
          return .file(try ShareInbox.copyFile(url, suggested: provider.suggestedName, suffix: nil,
                                              into: staging, index: index))
        }
        return .text(url.absoluteString)
      }
    }
    let advertisedName = provider.suggestedName.map { ($0 as NSString).pathExtension } ?? ""
    if advertisedName.isEmpty,
       let plain = data.first(where: { $0.conforms(to: .plainText) }),
       !data.contains(where: { !$0.conforms(to: .text) && $0 != .data }) {
      return try await loadItem(provider, as: plain) { item in
        let value = (item as? String) ?? (item as? NSAttributedString)?.string
          ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        guard let value else { throw ShareInbox.Failure.invalidItem }
        return .text(value)
      }
    }
    guard let fileRepresentation else {
      throw ShareInbox.Failure.invalidItem
    }
    return try await loadFile(provider, as: fileRepresentation, into: staging, index: index)
  }

  private static func loadFile(_ provider: NSItemProvider, as type: UTType,
                               into staging: URL, index: Int) async throws -> Value {
    return try await withCheckedThrowingContinuation { continuation in
      provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
        do {
          guard let url else { throw error ?? ShareInbox.Failure.invalidItem }
          let name = try ShareInbox.copyFile(
            url, suggested: provider.suggestedName, suffix: type.preferredFilenameExtension,
            into: staging, index: index
          )
          continuation.resume(returning: .file(name))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }

  private static func loadItem(_ provider: NSItemProvider, as type: UTType,
                               transform: @escaping (NSSecureCoding) throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
        do {
          guard let item else { throw error ?? ShareInbox.Failure.invalidItem }
          continuation.resume(returning: try transform(item))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
