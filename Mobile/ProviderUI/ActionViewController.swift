import CloudMountMobileCore
import FileProviderUI
import SwiftUI
import UIKit

final class ActionViewController: FPUIActionExtensionViewController {
  private func location() async throws -> MobileLocation {
    guard let text = extensionContext.domainIdentifier?.rawValue, let id = UUID(uuidString: text),
      let location = try await MobileEnvironment.service().configuration().locations.first(where: {
        $0.id == id
      })
    else { throw MobileError.missing }
    return location
  }
  override func prepare(forError error: Error) {
    if (error as NSError).userInfo["CloudMountReason"] as? String == "deviceLocked" {
      showError(MobileError.deviceLocked)
      return
    }
    if (error as NSError).userInfo["CloudMountReason"] as? String == "cloudCredentials" {
      presentCredentials()
    } else {
      Task { @MainActor in
        do {
          if try await location().isVault { presentUnlock() } else { presentCredentials() }
        } catch { showError(error) }
      }
    }
  }
  private func presentCredentials() {
    Task { @MainActor in
      do {
        let value = try await location()
        let service = try MobileEnvironment.service()
        guard
          let connection = try await service.configuration().connections.first(where: {
            $0.id == value.connectionID
          })
        else { throw MobileError.missing }
        let host = UIHostingController(
          rootView: CredentialsView(
            connection: connection,
            completion: { [weak self] in self?.extensionContext.completeRequest() },
            cancellation: { [weak self] in
              self?.extensionContext.cancelRequest(
                withError: NSError(domain: FPUIErrorDomain, code: 0))
            }).environment(\.locale, MobileText.locale))
        embed(host)
      } catch { showError(error) }
    }
  }
  private func embed(_ host: UIViewController) {
    addChild(host)
    view.addSubview(host.view)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    host.didMove(toParent: self)
  }
  override func prepare(
    forAction actionIdentifier: String, itemIdentifiers: [NSFileProviderItemIdentifier]
  ) {
    if actionIdentifier == "com.codex.cloudmount.lock" {
      Task { @MainActor in
        do {
          let value = try await location()
          guard value.isVault else { throw MobileError.unsupported }
          try await MobileEnvironment.lock(value)
          extensionContext.completeRequest()
        } catch { showError(error) }
      }
    } else {
      presentUnlock()
    }
  }
  private func presentUnlock() {
    Task { @MainActor in
      do {
        let value = try await location()
        if try MobileEnvironment.service().isUnlocked(value.id) {
          await MobileEnvironment.didUnlock(value.id)
          extensionContext.completeRequest()
          return
        }
        let host = UIHostingController(
          rootView: UnlockView(
            location: value,
            completion: { [weak self] in
              await MainActor.run { self?.extensionContext.completeRequest() }
            },
            cancellation: { [weak self] in
              self?.extensionContext.cancelRequest(
                withError: NSError(domain: FPUIErrorDomain, code: 0))
            }).environment(\.locale, MobileText.locale))
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
          host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
          host.view.topAnchor.constraint(equalTo: view.topAnchor),
          host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
      } catch { showError(error) }
    }
  }
  private func showError(_ error: Error) {
    let alert = UIAlertController(
      title: T("無法完成操作", "无法完成操作", "Could not complete"), message: MobileMessage.describe(error),
      preferredStyle: .alert)
    alert.addAction(
      UIAlertAction(title: T("完成", "完成", "Done"), style: .default) { _ in
        self.extensionContext.cancelRequest(withError: NSError(domain: FPUIErrorDomain, code: 1))
      })
    present(alert, animated: true)
  }
}
