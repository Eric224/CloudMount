import Combine
import Foundation

/// LaunchServices and remote URLs belong in a disposable helper, never in a
/// SwiftUI body or on the main actor. A missing acknowledgement is not a mount
/// failure: Finder can continue opening the folder after this request returns.
@MainActor
final class FinderOpener: ObservableObject {
    enum Outcome: Equatable { case accepted, unconfirmed, notMounted, unavailable }
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var outcome: Outcome?
    private var lastPath = ""
    private var nextAllowed: TimeInterval = 0
    private var workerUnresponsive = false

    static func interpret(_ result: CommandResult) -> Outcome {
        struct Reply: Decodable { let status: String }
        guard result.succeeded,
              let reply = try? JSONDecoder().decode(Reply.self, from: Data(result.stdout.utf8)) else {
            return result.status == -1 ? .unavailable : .unconfirmed
        }
        switch reply.status {
        case "accepted": return .accepted
        case "not-mounted": return .notMounted
        default: return .unconfirmed
        }
    }

    func open(path: String, helper: String,
              execute: ((String, String) async -> CommandResult)? = nil) async {
        // One request for the whole app, including vaults. Never pile up helper
        // processes if LaunchServices or a filesystem is unresponsive.
        guard !busy, !workerUnresponsive,
              lastPath != path || ProcessInfo.processInfo.systemUptime >= nextAllowed else { return }
        busy = true; lastPath = path
        outcome = nil; message = L10n.string("正在請 Finder 開啟資料夾…")
        defer { busy = false; nextAllowed = ProcessInfo.processInfo.systemUptime + 3 }
        let result: CommandResult
        if let execute { result = await execute(helper, path) }
        else {
            result = await CommandRunner.execute(helper, arguments: ["open-finder", path], timeout: 5, outputLimit: 4096)
        }
        // An unkillable helper must not be replaced by more helpers this run.
        workerUnresponsive = result.stillRunning
        let value = Self.interpret(result)
        outcome = value
        switch value {
        case .accepted:
            message = L10n.string("已請 Finder 開啟資料夾；首次顯示內容可能需要等候雲端回應。")
        case .notMounted:
            message = L10n.string("此位置目前沒有掛載。請重新整理掛載狀態後再試。")
        case .unavailable:
            message = L10n.string("無法啟動 Finder 開啟工具。請重新開啟 CloudMount 或重新安裝 app。")
        case .unconfirmed:
            message = L10n.string("尚未收到 Finder 的開啟確認。這不代表掛載失敗；請先查看 Finder，勿重複掛載。")
        }
    }
    func dismiss() { if !busy { message = nil } }
}
