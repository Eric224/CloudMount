import Foundation
import XCTest
@testable import CloudMountMobileCore

final class WebDAVRedirectTests: XCTestCase {
  func testCanonicalSlashRedirectNeverChangesOriginOrResource() {
    let from = URL(string:"https://dav.example.com/home/box/")!
    XCTAssertTrue(DAVRedirectPolicy.permits(from:from,to:URL(string:"https://dav.example.com/home/box")!))
    XCTAssertTrue(DAVRedirectPolicy.permits(from:from,to:URL(string:"https://dav.example.com:443/home/box")!))
    XCTAssertTrue(DAVRedirectPolicy.permits(from:URL(string:"https://dav.example.com/home/%E8%B3%87")!,to:URL(string:"https://dav.example.com/home/%e8%b3%87/")!))
    XCTAssertTrue(DAVRedirectPolicy.permits(from:URL(string:"https://dav.example.com/home/%E8%B3%87")!,to:URL(string:"https://dav.example.com/home/%e8%b3%87")!))
    XCTAssertFalse(DAVRedirectPolicy.permits(from:URL(string:"https://dav.example.com/home/A/")!,to:URL(string:"https://dav.example.com/home/a")!))
    for target in ["http://dav.example.com/home/box", "https://other.example.com/home/box", "https://dav.example.com:8443/home/box", "https://dav.example.com/home/other", "https://dav.example.com/home/box?token=x", "https://user:pass@dav.example.com/home/box", "https://dav.example.com/home/box#x", "https://dav.example.com/home%2Fbox", "https://dav.example.com/home/box/"] {
      XCTAssertFalse(DAVRedirectPolicy.permits(from:from,to:URL(string:target)!),target)
    }
  }
}
