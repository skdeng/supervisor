import Foundation
import Photos

/// When and where one photo was taken.
struct PhotoFix: Equatable, Sendable {
    let date: Date
    let latitude: Double
    let longitude: Double

    /// Whether the coordinates name a point on the globe. A camera with no position fix writes
    /// (0, 0), which is open ocean, so that pair counts as no position.
    var isPlausible: Bool {
        latitude.isFinite && longitude.isFinite
            && (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !(latitude == 0 && longitude == 0)
    }

    /// The great-circle distance to `other`, in metres.
    func distance(to other: PhotoFix) -> Double {
        let earthRadius = 6_371_000.0
        let fromLatitude = latitude * .pi / 180
        let toLatitude = other.latitude * .pi / 180
        let latitudeSpan = toLatitude - fromLatitude
        let longitudeSpan = (other.longitude - longitude) * .pi / 180
        let chord = sin(latitudeSpan / 2) * sin(latitudeSpan / 2)
            + cos(fromLatitude) * cos(toLatitude) * sin(longitudeSpan / 2) * sin(longitudeSpan / 2)
        return 2 * earthRadius * asin(min(1, sqrt(chord)))
    }
}

/// What one read of the library found.
struct PhotoReading: Equatable, Sendable {
    /// The photos that carry a position, in any order.
    let fixes: [PhotoFix]
    /// How many photos the read looked at, with a position or without.
    let scanned: Int
    /// Whether the library held more photos in the range than one read looks at, so the oldest
    /// were left unread.
    let reachedScanLimit: Bool
}

/// Photos taken one after another near the first of them.
struct PhotoStay: Equatable, Sendable {
    let first: Date
    let last: Date
    let count: Int
    /// How many local days between `first` and `last` have a photo in the stay. A stay can run
    /// over days with none.
    let dayCount: Int
    /// The first photo's position, as the photo recorded it.
    let latitude: Double
    let longitude: Double
}

/// A library's photos as a short list of stays, oldest first.
///
/// A library can hold a decade of photos and a reply holds a few hundred lines, so the grouping
/// distance adapts to the range asked for: the finest distance on `radii` that fits the range
/// into `stayLimit` stays is the one used. A week reads as street-level stops and a decade as
/// trips. Past the coarsest distance the oldest stays are dropped and counted in `omitted`.
struct PhotoTrail: Equatable, Sendable {
    /// The grouping distances tried, finest first, in metres.
    static let radii = [50, 500, 5_000, 50_000, 500_000]
    static let stayLimit = 400

    let stays: [PhotoStay]
    /// The grouping distance used, in metres.
    let radius: Int
    /// How many photos with a position the range held.
    let photoCount: Int
    /// How many of the oldest stays were left out.
    let omitted: Int
    let reachedScanLimit: Bool

    /// `timeZone` decides which local day each photo falls on.
    init(_ reading: PhotoReading, timeZone: TimeZone, stayLimit: Int = PhotoTrail.stayLimit) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fixes = reading.fixes.filter(\.isPlausible).sorted { $0.date < $1.date }
        let days = fixes.map { calendar.startOfDay(for: $0.date) }
        var radius = Self.radii[0]
        var stays: [PhotoStay] = []
        for candidate in Self.radii {
            radius = candidate
            stays = Self.stays(fixes, days: days, within: Double(candidate))
            if stays.count <= stayLimit { break }
        }
        self.radius = radius
        photoCount = fixes.count
        omitted = max(0, stays.count - stayLimit)
        self.stays = Array(stays.suffix(stayLimit))
        reachedScanLimit = reading.reachedScanLimit
    }

    /// Walks `fixes` in time order, starting a new stay at each photo farther than `radius`
    /// metres from the first photo of the stay under way. A place returned to later is a new
    /// stay, so the list reads as a route. `days` holds the start of each photo's local day.
    static func stays(_ fixes: [PhotoFix], days: [Date], within radius: Double) -> [PhotoStay] {
        var stays: [PhotoStay] = []
        var anchor: PhotoFix?
        var last = Date.distantPast
        var lastDay = Date.distantPast
        var count = 0
        var dayCount = 0

        func close() {
            guard let anchor else { return }
            stays.append(PhotoStay(
                first: anchor.date,
                last: last,
                count: count,
                dayCount: dayCount,
                latitude: anchor.latitude,
                longitude: anchor.longitude
            ))
        }

        for (fix, day) in zip(fixes, days) {
            if let current = anchor, current.distance(to: fix) <= radius {
                count += 1
                if day != lastDay { dayCount += 1 }
            } else {
                close()
                anchor = fix
                count = 1
                dayCount = 1
            }
            last = fix.date
            lastDay = day
        }
        close()
        return stays
    }
}

/// Reads when and where the photos in the user's Photos library were taken, and nothing else
/// about them: no image, file name, caption, album, or face leaves this type.
///
/// The library is reached through PhotoKit, which macOS allows only after the user grants the
/// app access to Photos. The members are closures so that tests supply a library of their own;
/// the test runner has no bundle for the system to ask about.
struct PhotoPlaces: Sendable {
    enum Access: Equatable, Sendable {
        case notAsked
        case allowed
        case denied
    }

    enum Failure: Error {
        case notAllowed
    }

    /// The most photos one read looks at, newest first.
    static let scanLimit = 500_000

    /// Whether the user has let the app read Photos. It never asks.
    var access: @Sendable () -> Access
    /// Asks the user, which the system does once; later calls answer with what they chose.
    var requestAccess: @Sendable () async -> Access
    /// The photos taken from `start` up to, and not including, `end`; a nil bound is open.
    /// It scans the library, so it is called off the main actor, and it throws
    /// `CancellationError` when the task it runs in is cancelled.
    var read: @Sendable (_ start: Date?, _ end: Date?) throws -> PhotoReading

    /// The user's own Photos library.
    static let library = PhotoPlaces(
        access: { access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite)) },
        requestAccess: { access(for: await PHPhotoLibrary.requestAuthorization(for: .readWrite)) },
        read: { start, end in try readLibrary(from: start, to: end) }
    )

    private static func access(for status: PHAuthorizationStatus) -> Access {
        switch status {
        case .authorized, .limited: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// Photos and videos in the user's own library, leaving out shared albums and hidden
    /// photos. What other people added to a shared library counts as the user's own.
    private static func readLibrary(from start: Date?, to end: Date?) throws -> PhotoReading {
        guard access(for: PHPhotoLibrary.authorizationStatus(for: .readWrite)) == .allowed else {
            throw Failure.notAllowed
        }
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary]
        options.includeHiddenAssets = false
        options.wantsIncrementalChangeDetails = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        // One more than a read looks at, which is how a library holding more is told from one
        // holding exactly that many.
        options.fetchLimit = scanLimit + 1
        var clauses: [NSPredicate] = []
        if let start {
            clauses.append(NSPredicate(format: "creationDate >= %@", start as NSDate))
        }
        if let end {
            clauses.append(NSPredicate(format: "creationDate < %@", end as NSDate))
        }
        if !clauses.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: clauses)
        }

        let assets = PHAsset.fetchAssets(with: options)
        var fixes: [PhotoFix] = []
        var scanned = 0
        assets.enumerateObjects { asset, index, stop in
            guard index < scanLimit, !Task.isCancelled else {
                stop.pointee = true
                return
            }
            scanned += 1
            // Each position is an autoreleased object; the pool keeps a long walk from holding
            // them all until it ends.
            autoreleasepool {
                guard let date = asset.creationDate,
                      let coordinate = asset.location?.coordinate
                else { return }
                fixes.append(PhotoFix(
                    date: date,
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                ))
            }
        }
        try Task.checkCancellation()
        return PhotoReading(
            fixes: fixes,
            scanned: scanned,
            reachedScanLimit: assets.count > scanLimit
        )
    }
}
