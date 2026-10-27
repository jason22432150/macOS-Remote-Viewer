import XCTest

final class InfoPlistDocumentTypeTests: XCTestCase {
    func testDeclaresVVAsOwnedDocumentType() throws {
        let plist = try loadInfoPlist()
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(types.count, 1)

        let document = try XCTUnwrap(types.first)
        XCTAssertEqual(document["CFBundleTypeRole"] as? String, "Editor")
        XCTAssertEqual(document["LSHandlerRank"] as? String, "Owner")
        XCTAssertEqual(document["CFBundleTypeExtensions"] as? [String], ["vv"])
        XCTAssertEqual(
            document["CFBundleTypeMIMETypes"] as? [String],
            ["application/x-virt-viewer"]
        )
        XCTAssertEqual(
            document["LSItemContentTypes"] as? [String],
            ["com.macremoteviewer.virt-viewer"]
        )
        XCTAssertNil(
            document["NSDocumentClass"],
            "NSDocumentClass 應已移除，殘留空字串會讓 Launch Services 忽略此文件類型"
        )
    }

    func testExportsVVFilenameAndVirtViewerMIMEType() throws {
        let plist = try loadInfoPlist()
        let exported = try XCTUnwrap(plist["UTExportedTypeDeclarations"] as? [[String: Any]])
        let declaration = try XCTUnwrap(exported.first)
        XCTAssertEqual(declaration["UTTypeIdentifier"] as? String, "com.macremoteviewer.virt-viewer")

        let tags = try XCTUnwrap(declaration["UTTypeTagSpecification"] as? [String: Any])
        XCTAssertTrue(tagList(tags["public.filename-extension"]).contains("vv"))
        XCTAssertTrue(tagList(tags["public.mime-type"]).contains("application/x-virt-viewer"))
    }

    private func loadInfoPlist() throws -> [String: Any] {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plistURL = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("MacRemoteViewer/App/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func tagList(_ value: Any?) -> [String] {
        if let values = value as? [String] {
            return values
        }
        if let value = value as? String {
            return [value]
        }
        return []
    }
}
