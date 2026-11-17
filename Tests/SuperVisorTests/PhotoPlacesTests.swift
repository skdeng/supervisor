import Foundation
import Testing

@testable import SuperVisor

/// A photo `minutes` after 2026-11-01T12:00:00Z at the given position.
private func fix(_ minutes: Double, _ latitude: Double, _ longitude: Double) -> PhotoFix {
    PhotoFix(
        date: Date(timeIntervalSince1970: 1_793_534_400 + minutes * 60),
        latitude: latitude,
        longitude: longitude
    )
}

private func trail(_ fixes: [PhotoFix], stayLimit: Int = PhotoTrail.stayLimit) -> PhotoTrail {
    PhotoTrail(
        PhotoReading(fixes: fixes, scanned: fixes.count, reachedScanLimit: false),
        timeZone: .gmt,
        stayLimit: stayLimit
    )
}

/// Lisbon's Praça do Comércio, and points about 30 m, 300 m, and 6 km from it.
private let square = (38.707751, -9.136592)
private let acrossTheSquare = (38.708020, -9.136592)
private let upTheHill = (38.710450, -9.136592)
private let belem = (38.697201, -9.206514)

@Suite("Photo places: positions")
struct PhotoFixTests {
    @Test("A position off the globe, not a number, or at (0, 0) is no position")
    func plausibility() {
        #expect(fix(0, 38.7, -9.1).isPlausible)
        #expect(fix(0, -90, 180).isPlausible)
        #expect(fix(0, 0, 12.5).isPlausible)
        #expect(!fix(0, 0, 0).isPlausible)
        #expect(!fix(0, 90.001, 0).isPlausible)
        #expect(!fix(0, 12, -180.5).isPlausible)
        #expect(!fix(0, .nan, 10).isPlausible)
        #expect(!fix(0, 10, .infinity).isPlausible)
    }

    @Test("Distance follows the globe, across the date line as anywhere else")
    func distance() {
        let origin = fix(0, square.0, square.1)

        #expect(origin.distance(to: origin) == 0)
        #expect(abs(origin.distance(to: fix(0, acrossTheSquare.0, acrossTheSquare.1)) - 30) < 1)
        #expect(abs(origin.distance(to: fix(0, upTheHill.0, upTheHill.1)) - 300) < 2)
        // One degree of longitude on the equator is 111.19 km, whichever side of 180° it spans.
        #expect(abs(fix(0, 0, 179.5).distance(to: fix(0, 0, -179.5)) - 111_195) < 10)
    }
}

@Suite("Photo places: the trail")
struct PhotoTrailTests {
    @Test("Photos taken in a row near the first are one stay, with the first photo's own position")
    func groupsNearbyPhotos() {
        let found = trail([
            fix(0, square.0, square.1),
            fix(10, acrossTheSquare.0, acrossTheSquare.1),
            fix(25, square.0, square.1),
            fix(90, belem.0, belem.1),
        ])

        #expect(found.radius == 50)
        #expect(found.photoCount == 4)
        #expect(found.omitted == 0)
        #expect(found.stays == [
            PhotoStay(
                first: fix(0, 0, 0).date,
                last: fix(25, 0, 0).date,
                count: 3,
                dayCount: 1,
                latitude: 38.707751,
                longitude: -9.136592
            ),
            PhotoStay(
                first: fix(90, 0, 0).date,
                last: fix(90, 0, 0).date,
                count: 1,
                dayCount: 1,
                latitude: 38.697201,
                longitude: -9.206514
            ),
        ])
    }

    @Test("The trail is in time order whatever order the library gave, and a place returned to is a new stay")
    func ordersAndKeepsReturns() {
        let found = trail([
            fix(120, square.0, square.1),
            fix(0, square.0, square.1),
            fix(60, belem.0, belem.1),
        ])

        #expect(found.stays.map(\.first) == [fix(0, 0, 0).date, fix(60, 0, 0).date, fix(120, 0, 0).date])
        #expect(found.stays.map(\.count) == [1, 1, 1])
    }

    @Test("Distance is measured from a stay's first photo, so a walk in small steps leaves it")
    func anchorsOnTheFirstPhoto() {
        // Six photos 30 m apart going north: each is within 50 m of the one before, and the
        // third is 60 m from the first.
        let walk = (0..<6).map { step in
            fix(Double(step), square.0 + Double(step) * 0.000269, square.1)
        }

        let found = trail(walk)

        #expect(found.radius == 50)
        #expect(found.stays.map(\.count) == [2, 2, 2])
        #expect(found.stays.map(\.latitude) == [walk[0].latitude, walk[2].latitude, walk[4].latitude])
    }

    @Test("A stay counts the local days that have a photo in it, which can be fewer than it spans")
    func countsDaysWithPhotos() {
        // Noon on 1 November, twice; 23:30 that day and 00:30 the next; then noon a month on.
        let home = [0.0, 5, 690, 750, 43_200].map { fix($0, square.0, square.1) }

        let utc = trail(home)
        #expect(utc.stays.count == 1)
        #expect(utc.stays[0].count == 5)
        #expect(utc.stays[0].dayCount == 3)

        // Nine hours ahead, the 23:30 and 00:30 photos share 2 November and the first two keep
        // 1 November. Ten hours behind, the first four all fall on 1 November.
        let tokyo = PhotoTrail(
            PhotoReading(fixes: home, scanned: 5, reachedScanLimit: false),
            timeZone: TimeZone(identifier: "Asia/Tokyo")!
        )
        #expect(tokyo.stays[0].dayCount == 3)
        let honolulu = PhotoTrail(
            PhotoReading(fixes: Array(home.prefix(4)), scanned: 4, reachedScanLimit: false),
            timeZone: TimeZone(identifier: "Pacific/Honolulu")!
        )
        #expect(honolulu.stays[0].dayCount == 1)
    }

    @Test("A photo with no usable position is left out of the trail and its count")
    func dropsImplausible() {
        let found = trail([fix(0, 0, 0), fix(1, .nan, 4), fix(2, square.0, square.1)])

        #expect(found.photoCount == 1)
        #expect(found.stays.count == 1)
    }

    @Test("A range with more stays than fit is grouped by the finest distance that does fit")
    func coarsensToFit() {
        // Two spots 300 m apart, visited in turn: four stays at 50 m, one at 500 m.
        let alternating = [
            fix(0, square.0, square.1),
            fix(10, upTheHill.0, upTheHill.1),
            fix(20, square.0, square.1),
            fix(30, upTheHill.0, upTheHill.1),
        ]

        let fine = trail(alternating, stayLimit: 4)
        #expect(fine.radius == 50)
        #expect(fine.stays.count == 4)

        let coarse = trail(alternating, stayLimit: 3)
        #expect(coarse.radius == 500)
        #expect(coarse.stays.count == 1)
        #expect(coarse.stays[0].count == 4)
        #expect(coarse.stays[0].latitude == square.0)
        #expect(coarse.omitted == 0)
    }

    @Test("Past the coarsest distance the newest stays are kept and the rest counted")
    func keepsNewestWhenNothingFits() {
        // Lisbon, Sydney, Lisbon, Sydney, Lisbon: no distance on the list joins them.
        let far = (0..<5).map { index in
            index.isMultiple(of: 2)
                ? fix(Double(index) * 1_440, square.0, square.1)
                : fix(Double(index) * 1_440, -33.8568, 151.2153)
        }

        let found = trail(far, stayLimit: 2)

        #expect(found.radius == 500_000)
        #expect(found.photoCount == 5)
        #expect(found.omitted == 3)
        #expect(found.stays.map(\.first) == [far[3].date, far[4].date])
    }

    @Test("An empty library is an empty trail at the finest distance")
    func empty() {
        let found = trail([])

        #expect(found.stays.isEmpty)
        #expect(found.photoCount == 0)
        #expect(found.radius == 50)
        #expect(found.omitted == 0)
    }

    @Test("The trail says when the read stopped at its scan limit")
    func carriesScanLimit() {
        let found = PhotoTrail(
            PhotoReading(fixes: [fix(0, square.0, square.1)], scanned: 1, reachedScanLimit: true),
            timeZone: .gmt
        )

        #expect(found.reachedScanLimit)
    }
}
