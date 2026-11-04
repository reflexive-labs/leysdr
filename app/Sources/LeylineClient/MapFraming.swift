// SPDX-License-Identifier: Apache-2.0

// Where the Decoders map's camera goes. The map frames every transmitter with a position once,
// when a decoder's page first has positions; after that it moves only to zoom out, when a
// transmitter would fall outside the region it shows, and never zooms in or moves because one went
// quiet. Once the person pans or zooms, the map stops framing itself until Fit All. A page keeps
// one per decoder for the session, so a tab switch or another decoder leaves the person's camera
// where it was. MapKit's map and the staged run's plain canvas both draw `region`.

import Foundation

/// A point on the map, in degrees.
public struct MapCoordinate: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

/// A rectangle of the map: its centre and its spans, in degrees.
public struct MapRegion: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    public var latitudeSpan: Double
    public var longitudeSpan: Double

    public init(latitude: Double, longitude: Double, latitudeSpan: Double, longitudeSpan: Double) {
        self.latitude = latitude
        self.longitude = longitude
        self.latitudeSpan = latitudeSpan
        self.longitudeSpan = longitudeSpan
    }

    public var south: Double { latitude - latitudeSpan / 2 }
    public var north: Double { latitude + latitudeSpan / 2 }
    public var west: Double { longitude - longitudeSpan / 2 }
    public var east: Double { longitude + longitudeSpan / 2 }

    init(south: Double, north: Double, west: Double, east: Double) {
        self.init(
            latitude: (south + north) / 2, longitude: (west + east) / 2,
            latitudeSpan: north - south, longitudeSpan: east - west)
    }

    /// The smallest region holding every point, grown by `padding` of its span on each side and
    /// at least `least` degrees each way; nil for no point.
    public static func fitting(_ points: [MapCoordinate], padding: Double, least: Double)
        -> MapRegion?
    {
        guard let first = points.first else { return nil }
        var s = first.latitude
        var n = first.latitude
        var w = first.longitude
        var e = first.longitude
        for p in points.dropFirst() {
            s = min(s, p.latitude)
            n = max(n, p.latitude)
            w = min(w, p.longitude)
            e = max(e, p.longitude)
        }
        let latSpan = max(least, (n - s) * (1 + 2 * padding))
        let lonSpan = max(least, (e - w) * (1 + 2 * padding))
        return MapRegion(
            latitude: (s + n) / 2, longitude: (w + e) / 2, latitudeSpan: latSpan,
            longitudeSpan: lonSpan)
    }

    /// Whether `p` lies inside the region less `margin` of its span on each side.
    public func holds(_ p: MapCoordinate, margin: Double) -> Bool {
        let dLat = latitudeSpan * margin
        let dLon = longitudeSpan * margin
        return p.latitude >= south + dLat && p.latitude <= north - dLat
            && p.longitude >= west + dLon && p.longitude <= east - dLon
    }

    /// The smallest region holding both.
    public func union(_ o: MapRegion) -> MapRegion {
        MapRegion(
            south: min(south, o.south), north: max(north, o.north), west: min(west, o.west),
            east: max(east, o.east))
    }
}

/// One decoder page's camera rule.
public struct MapFraming: Sendable, Equatable {
    /// The region the map shows: the one the rule chose, or the person's once they moved it; nil
    /// until the page has a position.
    public private(set) var region: MapRegion?
    /// Whether the rule moves the camera: true until the person pans or zooms, and again after
    /// Fit All.
    public private(set) var following = true

    /// The room around the transmitters when the rule frames them, as a fraction of their span
    /// on each side.
    public static let padding = 0.15
    /// A transmitter this close to the edge, as a fraction of the region's span, counts as
    /// outside, so a marker is never drawn half off the map.
    public static let margin = 0.05
    /// The least the rule frames each way, in degrees, so one transmitter is not a street map.
    public static let leastSpan = 0.1

    public init() {}

    /// The transmitters' positions now. Returns the region to move the camera to, or nil to
    /// leave it: the first positions are framed, and after that the region only grows, to hold a
    /// transmitter that would fall outside it. A transmitter gone changes nothing.
    @discardableResult
    public mutating func update(_ points: [MapCoordinate]) -> MapRegion? {
        guard following else { return nil }
        guard let fit = MapRegion.fitting(points, padding: Self.padding, least: Self.leastSpan)
        else { return nil }
        guard let r = region else {
            region = fit
            return fit
        }
        if points.allSatisfy({ r.holds($0, margin: Self.margin) }) { return nil }
        let grown = r.union(fit)
        region = grown
        return grown
    }

    /// The person moved the camera to `visible`: the rule stops until Fit All.
    public mutating func personMoved(to visible: MapRegion) {
        region = visible
        following = false
    }

    /// Fit All: frames the positions once, closer or wider, and the rule follows again.
    @discardableResult
    public mutating func fitAll(_ points: [MapCoordinate]) -> MapRegion? {
        following = true
        guard let fit = MapRegion.fitting(points, padding: Self.padding, least: Self.leastSpan)
        else { return nil }
        region = fit
        return fit
    }
}
