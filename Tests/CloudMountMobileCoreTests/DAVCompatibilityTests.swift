import XCTest
@testable import CloudMountMobileCore

final class DAVCompatibilityTests: XCTestCase {
  func testWeakAndStrongEntityIdentityAreStableButDifferentEntitiesStayDifferent() {
    XCTAssertEqual(DAVRevision.normalized("W/\"same\""), DAVRevision.normalized("\"same\""))
    XCTAssertNotEqual(DAVRevision.normalized("W/\"first\""), DAVRevision.normalized("\"second\""))
    let base = URL(string: "https://dav.example.com/file")!
    let xml = "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/file</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>3</d:getcontentlength><d:getetag>W/\"same\"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
    XCTAssertEqual(try DAVParser(data:Data(xml.utf8),base:base,requested:base).parse()[0].item.version,"\"same\"")
    XCTAssertEqual(try DAVParser(data:Data(xml.utf8),base:base,requested:base,rawETag:true).parse()[0].item.version,"W/\"same\"")
  }
  func testSynologyDirectoryOptionalContentLength404IsNotAFailedListing() throws {
    let base = URL(string: "https://nas.example.com/")!
    let xml = """
      <d:multistatus xmlns:d="DAV:"><d:response><d:href>/</d:href>
      <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:getetag>"root"</d:getetag></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
      <d:response><d:href>https://nas.example.com:443/home/</d:href>
      <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
      <d:propstat><d:prop><d:getcontentlength/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response></d:multistatus>
      """
    let result = try DAVParser(data: Data(xml.utf8), base: base, requested: base).parse()
    XCTAssertEqual(result.count, 2)
    XCTAssertTrue(result.allSatisfy { $0.item.isDirectory && $0.item.size == 0 })
  }
  func testFailedRequiredPropertyOrMissingSelfNeverBecomesEmptySuccess() {
    let base = URL(string: "https://nas.example.com/")!
    for xml in [
      "<d:multistatus xmlns:d=\"DAV:\"/>",
      "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 403 Forbidden</d:status></d:propstat></d:response></d:multistatus>",
      "<d:multistatus xmlns:d=\"DAV:\"><d:response><d:href>/</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>bad</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"
    ] {
      XCTAssertThrowsError(try DAVParser(data: Data(xml.utf8), base: base, requested: base).parse())
    }
  }
}
