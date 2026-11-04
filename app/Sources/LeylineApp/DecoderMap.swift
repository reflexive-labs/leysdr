// SPDX-License-Identifier: Apache-2.0

// The Decoders page's map: every transmitter whose newest position is known, as a marker turned to
// its heading when it sent one (`DecoderEntity.heading`: `track_deg`, `course_deg`, `cog_deg`),
// its trail of the last positions as a line, and its name beside it; a click shows it in the
// inspector. The map frames the transmitters and never the person: it asks for no location and
// draws no user annotation, so macOS asks for no permission (docs/plans/decoders-app.md,
// "Decisions"). Tiles come from Apple, which would make a staged run's pictures differ from one run
// to the next, so a staged run (`LEYLINE_APP_STAGE`) draws the same markers, trails and names on a
// plain equirectangular canvas instead, unless its stage sets `real_map` (the site's pictures);
// the real map is checked by hand.

import LeylineClient
import LeylineProto
import MapKit
import SwiftUI

/// One transmitter as the map draws it.
struct MapPoint: Identifiable, Equatable {
    var id: String
    var name: String
    var latitude: Double
    var longitude: Double
    var heading: Double?
    var trail: [TrailPoint]
    var selected: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct DecoderMapTab: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        let points: [MapPoint] = d.listedTransmitters.compactMap { e in
            guard let p = e.position, p.latitude.isFinite, p.longitude.isFinite else { return nil }
            return MapPoint(
                id: e.deviceID, name: d.name(of: e.deviceID), latitude: p.latitude,
                longitude: p.longitude, heading: e.heading, trail: e.trail,
                selected: d.selectedTransmitter == e.deviceID)
        }
        // In the table's order, which does not change as records arrive, so neither do the
        // markers' order nor VoiceOver's; the selected one last, so it is drawn on top.
        let drawn = points.filter { !$0.selected } + points.filter(\.selected)
        let select: (String) -> Void = { d.selectedTransmitter = $0 }
        Group {
            if points.isEmpty {
                Text("No transmitter has sent a position yet.").font(Theme.Font.label)
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if stagedPlainMap(session) {
                StagedMap(points: drawn, select: select)
            } else {
                LiveMap(points: drawn, decoder: d.selectedName ?? "", select: select)
            }
        }
        .stageRegion(.map)
        .identifiedGroup("decoders.map")
    }
}

/// MapKit's map, north up (it pans and zooms but does not rotate, so a marker's heading reads
/// true), framing every marker when it opens and whenever another decoder is shown.
struct LiveMap: View {
    let points: [MapPoint]
    let decoder: String
    let select: (String) -> Void
    @State private var camera: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(points.filter { $0.trail.count > 1 }) { p in
                MapPolyline(
                    coordinates: p.trail.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                )
                .stroke(Theme.mapTrail, lineWidth: Theme.Layout.mapTrailWidth)
            }
            ForEach(points) { p in
                Annotation(p.name, coordinate: p.coordinate, anchor: .center) {
                    MapMarkerView(point: p)
                        .onTapGesture { select(p.id) }
                        .mapMarkerAccessibility(p, select: select)
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .onChange(of: decoder) { camera = .automatic }
    }
}

/// The staged run's map: an equirectangular projection framing every position, with a graticule
/// every `mapGraticuleDegrees`, the trails, and the markers and names as views, so the
/// accessibility tree and a click reach them as on the real map.
struct StagedMap: View {
    let points: [MapPoint]
    let select: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let proj = Projection(points: points, size: geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(ctx, size: size, proj: proj)
                }
                ForEach(points) { p in
                    // The marker's centre on the point, its name drawn beside it and outside its
                    // frame, so the frame (and the click) is the marker's.
                    MapMarkerView(point: p)
                        .overlay(alignment: .leading) {
                            Text(p.name).font(Theme.Font.mapLabel)
                                .foregroundStyle(
                                    p.selected ? Theme.mapSelected : Theme.inkSecondary
                                )
                                .lineLimit(1).fixedSize()
                                .offset(x: Theme.Layout.mapSelectedRing + Theme.Layout.mapLabelGap)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { select(p.id) }
                        .mapMarkerAccessibility(p, select: select)
                        .position(proj.point(p.latitude, p.longitude))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Theme.ground)
        .clipped()
    }

    private func draw(_ ctx: GraphicsContext, size: CGSize, proj: Projection) {
        // The graticule over the whole canvas.
        let step = Theme.Layout.mapGraticuleDegrees
        let corner0 = proj.coordinate(CGPoint(x: 0, y: size.height))
        let corner1 = proj.coordinate(CGPoint(x: size.width, y: 0))
        var grid = Path()
        var lat = (corner0.lat / step).rounded(.down) * step
        while lat <= corner1.lat {
            let y = proj.point(lat, corner0.lon).y
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
            lat += step
        }
        var lon = (corner0.lon / step).rounded(.down) * step
        while lon <= corner1.lon {
            let x = proj.point(corner0.lat, lon).x
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
            lon += step
        }
        ctx.stroke(grid, with: .color(Theme.mapGraticule), lineWidth: 1)
        for p in points where p.trail.count > 1 {
            var path = Path()
            for (i, t) in p.trail.enumerated() {
                let at = proj.point(t.latitude, t.longitude)
                if i == 0 { path.move(to: at) } else { path.addLine(to: at) }
            }
            ctx.stroke(
                path, with: .color(p.selected ? Theme.mapSelected : Theme.mapTrail),
                lineWidth: Theme.Layout.mapTrailWidth)
        }
    }

    /// Degrees to points: longitude scaled by the cosine of the middle latitude, so a degree
    /// reads the same distance both ways, and the whole fitted inside the inset with its aspect.
    struct Projection {
        let midLat: Double
        let midLon: Double
        let kx: Double
        let scale: Double
        let centre: CGPoint

        init(points: [MapPoint], size: CGSize) {
            var lats: [Double] = []
            var lons: [Double] = []
            for p in points {
                lats.append(p.latitude)
                lons.append(p.longitude)
                for t in p.trail {
                    lats.append(t.latitude)
                    lons.append(t.longitude)
                }
            }
            let least = 0.02
            let lat0 = lats.min() ?? 0
            let lat1 = lats.max() ?? 0
            let lon0 = lons.min() ?? 0
            let lon1 = lons.max() ?? 0
            midLat = (lat0 + lat1) / 2
            midLon = (lon0 + lon1) / 2
            kx = max(0.01, cos(midLat * .pi / 180))
            let inset = Theme.Layout.mapCanvasInset
            // The names are drawn to the right of their markers, so the right keeps room for one.
            let room = Theme.Layout.mapLabelRoom
            let w = max(1, Double(size.width - 2 * inset - room))
            let h = max(1, Double(size.height - 2 * inset))
            let spanLon = max(least, lon1 - lon0) * kx
            let spanLat = max(least, lat1 - lat0)
            scale = min(w / spanLon, h / spanLat)
            centre = CGPoint(x: (size.width - room) / 2, y: size.height / 2)
        }

        func point(_ lat: Double, _ lon: Double) -> CGPoint {
            CGPoint(
                x: centre.x + CGFloat((lon - midLon) * kx * scale),
                y: centre.y - CGFloat((lat - midLat) * scale))
        }

        func coordinate(_ p: CGPoint) -> (lat: Double, lon: Double) {
            (
                lat: midLat - Double(p.y - centre.y) / scale,
                lon: midLon + Double(p.x - centre.x) / (kx * scale)
            )
        }
    }
}

/// A transmitter's marker: an arrow turned to its heading, or a dot when it sent none, in
/// `mapMarker`, the selected one in `mapSelected` inside a ring.
struct MapMarkerView: View {
    let point: MapPoint

    var body: some View {
        let ink = point.selected ? Theme.mapSelected : Theme.mapMarker
        ZStack {
            if point.selected {
                Circle().stroke(Theme.mapSelected, lineWidth: 1.5)
                    .frame(
                        width: Theme.Layout.mapSelectedRing, height: Theme.Layout.mapSelectedRing)
            }
            if let h = point.heading {
                Image(systemName: "location.north.fill").font(Theme.Font.mapGlyph)
                    .foregroundStyle(ink)
                    .rotationEffect(.degrees(h))
            } else {
                Circle().fill(ink)
                    .frame(
                        width: Theme.Layout.mapMarkerSize / 2,
                        height: Theme.Layout.mapMarkerSize / 2)
            }
        }
        .frame(width: Theme.Layout.mapSelectedRing, height: Theme.Layout.mapSelectedRing)
    }
}

extension View {
    /// A marker as one accessibility button named by its transmitter, whose press selects it.
    fileprivate func mapMarkerAccessibility(_ p: MapPoint, select: @escaping (String) -> Void)
        -> some View
    {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(p.name)
            .accessibilityValue(p.heading.map { "heading \(Int($0.rounded()))°" } ?? "")
            .accessibilityIdentifier("decoders.map.\(ViewIdentifier.slug(p.id))")
            .pressable { select(p.id) }
    }
}
