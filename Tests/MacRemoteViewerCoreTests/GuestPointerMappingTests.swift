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
}
