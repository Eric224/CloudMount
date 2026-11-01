import Foundation

struct DirectoryReceipt: Codable {
  let date: Date
  let generation: Int64
}

/// One enumerator owns one scan. It never holds a location lock while waiting
/// for the OS to request the next page. An incomplete scan never deletes items.
public actor MobileProviderDirectoryPages {
  private let service: MobileService
  private let location: UUID
  private let parent: String
  private let snapshots = MobileEnumerationPages()
  private struct Scan {
    let id: UUID
    let path: String
    let baseline: [MobileNode]
    let started: ContinuousClock.Instant
    var continuation: String?
    var seen = Set<String>()
    var names = Set<String>()
    var tokens = Set<String>()
    var page = 0
  }
  private var scan: Scan?
  private var invalidated = false
  private var busy = false
  public init(service: MobileService, location: UUID, parent: String) {
    self.service = service; self.location = location; self.parent = parent
  }
  public func invalidate() async { invalidated = true; scan = nil; await snapshots.invalidate() }
  public func first(size: Int, byDate: Bool = false) async throws -> MobileEnumerationPage {
    guard !busy, !invalidated else { throw MobileError.busy }
    busy = true; defer { busy = false }
    scan = nil
    if let cached = try await service.cachedProviderDirectory(parent, location: location) {
      return try await snapshots.start(sorted(cached, byDate: byDate), size: size)
    }
    let context = try await service.providerScanContext(parent, location: location)
    if context.paged {
      return try await load(Scan(id: UUID(), path: context.path, baseline: context.baseline, started: .now), size: size)
    }
    let nodes = try await MobileDeadline.run(seconds: 20) { try await self.service.list(self.parent, location: self.location) }
    try Task.checkCancellation()
    guard !invalidated else { throw CancellationError() }
    var result = try await snapshots.start(sorted(nodes, byDate: byDate), size: size)
    result.verifiedRemote = true
    return result
  }
  public func next(_ token: String, size: Int) async throws -> MobileEnumerationPage {
    guard !busy, !invalidated else { throw MobileError.busy }
    busy = true; defer { busy = false }
    try await service.validateProviderAccess(location)
    if let current = scan {
      guard token == "remote:\(current.id):\(current.page)", current.started.duration(to: .now) < .seconds(120) else {
        scan = nil; throw MobileError.expiredPage
      }
      return try await load(current, size: size)
    }
    return try await snapshots.next(token, size: size)
  }
  private func load(_ previous: Scan, size: Int) async throws -> MobileEnumerationPage {
    var current = previous
    let result = try await service.providerDirectoryPage(parent, location: location,
      path: current.path, continuation: current.continuation, limit: size)
    try Task.checkCancellation()
    guard !invalidated else { throw CancellationError() }
    for node in result.nodes {
      guard current.names.insert(node.name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
        current.seen.insert(node.id).inserted, current.seen.count < 20_000 else { throw MobileError.incomplete }
    }
    current.page += 1
    if let next = result.next {
      guard current.tokens.insert(next).inserted, current.page <= 400 else { throw MobileError.incomplete }
      current.continuation = next; scan = current
    } else {
      try await service.completeProviderScan(parent, location: location, path: current.path,
        baseline: current.baseline, seen: current.seen)
      scan = nil
    }
    return MobileEnumerationPage(nodes: result.nodes,
      next: result.next == nil ? nil : "remote:\(current.id):\(current.page)", verifiedRemote: true)
  }
  private func sorted(_ nodes: [MobileNode], byDate: Bool) -> [MobileNode] {
    nodes.sorted { a, b in
      if byDate, a.modified != b.modified { return a.modified > b.modified }
      return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
  }
}
