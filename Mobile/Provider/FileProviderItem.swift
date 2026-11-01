import CloudMountMobileCore
import CryptoKit
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class FileProviderItem: NSObject, NSFileProviderItem {
  let node: MobileNode
  let vault: Bool
  let readOnly: Bool
  init(_ node: MobileNode, vault: Bool = false, readOnly: Bool = false) {
    self.node = node
    self.vault = vault
    self.readOnly = readOnly
  }
  var itemIdentifier: NSFileProviderItemIdentifier {
    node.id == "root" ? .rootContainer : NSFileProviderItemIdentifier(node.id)
  }
  var parentItemIdentifier: NSFileProviderItemIdentifier {
    node.parent == "root" ? .rootContainer : NSFileProviderItemIdentifier(node.parent)
  }
  var filename: String { node.name }
  var contentType: UTType {
    node.directory
      ? .folder : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
  }
  var contentPolicy: NSFileProviderContentPolicy { .downloadLazilyAndEvictOnRemoteUpdate }
  var isUploaded: Bool { true }
  var documentSize: NSNumber? { NSNumber(value: node.size) }
  var contentModificationDate: Date? { node.modified }
  var capabilities: NSFileProviderItemCapabilities {
    if readOnly {
      return node.directory
        ? [.allowsReading, .allowsContentEnumerating, .allowsEvicting]
        : [.allowsReading, .allowsEvicting]
    }
    if node.id == "root" {
      return [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsEvicting]
    }
    if node.directory {
      return [
        .allowsReading, .allowsContentEnumerating, .allowsAddingSubItems, .allowsEvicting,
        .allowsRenaming, .allowsReparenting, .allowsDeleting,
      ]
    }
    return [
      .allowsEvicting, .allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting,
      .allowsDeleting,
    ]
  }
  var itemVersion: NSFileProviderItemVersion {
    NSFileProviderItemVersion(
      contentVersion: Data(SHA256.hash(data: Data(node.version.utf8))),
      metadataVersion: Data(
        SHA256.hash(
          data: Data(("mobile-policy-4:\(readOnly):" + node.path + ":" + node.version).utf8))))
  }
  var userInfo: [AnyHashable: Any]? { ["cloudmountNode": node.id, "isVault": vault] }
}
