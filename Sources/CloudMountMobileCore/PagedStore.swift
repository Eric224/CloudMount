import CloudMountVaultCore
import Foundation

public struct CipherDirectoryPage: Sendable {
  public let items: [CipherItem]
  public let next: String?
  public init(items: [CipherItem], next: String?) { self.items = items; self.next = next }
}
protocol PagedCiphertextStore: CiphertextStore {
  func listPage(_ path: String, continuation: String?, limit: Int) async throws -> CipherDirectoryPage
}
