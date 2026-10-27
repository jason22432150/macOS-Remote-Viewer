import XCTest
@testable import MacRemoteViewerCore

final class GuestPointerMappingTests: XCTestCase {
    func testAspectFitCentersLetterboxedDisplay() {
        let mapping = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: 1920, height: 1080),
            drawableSize: CGSize(width: 1600, height: 1200)
        )
        XCTAssertEqual(mapping.viewportScale, 1600.0 / 1920.0, accuracy: 0.0001)

        let topLeft = mapping.guestPoint(fromPixelPoint: CGPoint(x: 0, y: 150))
        XCTAssertEqual(topLeft?.x ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(topLeft?.y ?? -1, 0, accuracy: 0.5)

        let center = mapping.guestPoint(fromPixelPoint: CGPoint(x: 800, y: 600))
        XCTAssertEqual(center?.x ?? -1, 960, accuracy: 0.5)
        XCTAssertEqual(center?.y ?? -1, 540, accuracy: 0.5)
    }

    func testDoesNotInvertYWhenPixelOriginIsTopLeft() {
        let mapping = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: 100, height: 100),
            drawableSize: CGSize(width: 200, height: 200)
        )
        let top = mapping.guestPoint(fromPixelPoint: CGPoint(x: 100, y: 0))
        let bottom = mapping.guestPoint(fromPixelPoint: CGPoint(x: 100, y: 200))
        XCTAssertEqual(top?.y ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(bottom?.y ?? -1, 100, accuracy: 0.5)
    }

    func testViewPointUsesBackingScale() {
        let mapping = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: 100, height: 100),
            drawableSize: CGSize(width: 200, height: 200)
        )
        let guest = mapping.guestPoint(
            fromViewPoint: CGPoint(x: 50, y: 25),
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100)
        )
        XCTAssertEqual(guest?.x ?? -1, 50, accuracy: 0.5)
        XCTAssertEqual(guest?.y ?? -1, 25, accuracy: 0.5)
    }

    func testLetterboxPixelsDoNotMapToGuest() {
        // 1920x1080 等比縮放到 1600x1200：上下各 150px 黑邊。
        let mapping = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: 1920, height: 1080),
            drawableSize: CGSize(width: 1600, height: 1200)
        )

        XCTAssertNil(mapping.guestPoint(fromPixelPoint: CGPoint(x: 800, y: 0)))
        XCTAssertNil(mapping.guestPoint(fromPixelPoint: CGPoint(x: 800, y: 149)))
        XCTAssertNil(mapping.guestPoint(fromPixelPoint: CGPoint(x: 800, y: 1051)))
        XCTAssertNil(mapping.guestPoint(fromPixelPoint: CGPoint(x: 800, y: 1200)))
        XCTAssertFalse(mapping.contains(pixelPoint: CGPoint(x: 800, y: 0)))
        XCTAssertTrue(mapping.contains(pixelPoint: CGPoint(x: 800, y: 150)))
        XCTAssertTrue(mapping.contains(pixelPoint: CGPoint(x: 800, y: 1050)))
    }

    func testPillarboxPixelsDoNotMapToGuest() {
        // 800x600 等比放到 1000x600：左右各 100px 黑邊。
        let mapping = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: 800, height: 600),
            drawableSize: CGSize(width: 1000, height: 600)
        )

        XCTAssertNil(mapping.guestPoint(fromPixelPoint: CGPoint(x: 0, y: 300)))
        XCTAssertNil(mapping.guestPoint(fromPixelPoint: CGPoint(x: 99, y: 300)))
        XCTAssertNil(mapping.guestPoint(fromPixelPoint: CGPoint(x: 901, y: 300)))
        XCTAssertFalse(mapping.contains(pixelPoint: CGPoint(x: 50, y: 300)))
        XCTAssertTrue(mapping.contains(pixelPoint: CGPoint(x: 100, y: 300)))
        XCTAssertTrue(mapping.contains(pixelPoint: CGPoint(x: 900, y: 300)))

        let leftEdge = mapping.guestPoint(fromPixelPoint: CGPoint(x: 100, y: 300))
        XCTAssertEqual(leftEdge?.x ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(leftEdge?.y ?? -1, 300, accuracy: 0.5)
    }

    func testViewPointOutsideFittedDisplayReturnsNil() {
        let mapping = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: 1920, height: 1080),
            drawableSize: CGSize(width: 1600, height: 1200)
        )
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        // view y=0 對應 drawable y=0，落在上黑邊。
        XCTAssertNil(mapping.guestPoint(fromViewPoint: CGPoint(x: 400, y: 0), bounds: bounds))
        XCTAssertFalse(mapping.contains(viewPoint: CGPoint(x: 400, y: 0), bounds: bounds))
        // view y=75 對應 drawable y=150，落在畫面頂緣。
        XCTAssertTrue(mapping.contains(viewPoint: CGPoint(x: 400, y: 75), bounds: bounds))
    }

    func testClampToDisplayMapsLetterboxToEdge() {
        let mapping = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: 1920, height: 1080),
            drawableSize: CGSize(width: 1600, height: 1200)
        )
        let top = mapping.guestPoint(
            fromPixelPoint: CGPoint(x: 800, y: 0),
            clampToDisplay: true
        )
        XCTAssertEqual(top?.x ?? -1, 960, accuracy: 0.5)
        XCTAssertEqual(top?.y ?? -1, 0, accuracy: 0.5)

        let bottom = mapping.guestPoint(
            fromPixelPoint: CGPoint(x: 800, y: 1200),
            clampToDisplay: true
        )
        XCTAssertEqual(bottom?.x ?? -1, 960, accuracy: 0.5)
        XCTAssertEqual(bottom?.y ?? -1, 1080, accuracy: 0.5)
    }
}
