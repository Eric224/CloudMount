import Foundation

public struct MobileEnumerationPage: Sendable {
  public let nodes: [MobileNode]
  public let next: String?
  public var verifiedRemote: Bool = false
}
/// In-memory snapshots belong to one enumerator. Pagination never recontacts
/// the server and never creates persistent copies of decrypted vault names.
public actor MobileEnumerationPages {
  private struct Snapshot {
    let nodes: [MobileNode]
    let created: ContinuousClock.Instant
  }
  private var snapshots: [UUID: Snapshot] = [:]
  public init() {}
  public func start(_ nodes: [MobileNode], size: Int) throws -> MobileEnumerationPage {
    guard nodes.count < 20_000 else { throw MobileError.incomplete }
    snapshots = snapshots.filter { $0.value.created.duration(to: .now) < .seconds(120) }
    if snapshots.count >= 2,
      let oldest = snapshots.min(by: { $0.value.created < $1.value.created })?.key
    {
      snapshots.removeValue(forKey: oldest)
    }
    let id = UUID()
    snapshots[id] = Snapshot(nodes: nodes, created: .now)
    return try page(id: id, offset: 0, size: size)
  }
  public func next(_ token: String, size: Int) throws -> MobileEnumerationPage {
    let pieces = token.split(separator: ":", omittingEmptySubsequences: false)
    guard pieces.count == 2, let id = UUID(uuidString: String(pieces[0])),
      let offset = Int(pieces[1]), offset > 0
    else { throw MobileError.expiredPage }
    return try page(id: id, offset: offset, size: size)
  }
  private func page(id: UUID, offset: Int, size: Int) throws -> MobileEnumerationPage {
    guard let snapshot = snapshots[id], snapshot.created.duration(to: .now) < .seconds(120),
      offset >= 0, offset <= snapshot.nodes.count
    else {
      snapshots.removeValue(forKey: id)
      throw MobileError.expiredPage
    }
    let end = min(snapshot.nodes.count, offset + max(1, min(200, size)))
    let next = end < snapshot.nodes.count ? "\(id.uuidString):\(end)" : nil
    if next == nil { snapshots.removeValue(forKey: id) }
    return MobileEnumerationPage(nodes: Array(snapshot.nodes[offset..<end]), next: next)
  }
  public func invalidate() { snapshots.removeAll() }
}
