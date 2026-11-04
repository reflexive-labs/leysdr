// SPDX-License-Identifier: Apache-2.0

// The Decoders page's map: every transmitter whose newest position is known, as a marker turned to
// its heading when it sent one (`DecoderEntity.heading`: `track_deg`, `course_deg`, `cog_deg`),
// its trail of the last positions as a line, and its name beside it, dimmed once it has been quiet
// for half of `entity_silence_s`; a click shows it in the inspector. The camera follows the page's
// `MapFraming`: every transmitter framed once, then only zoomed out to hold one that would leave
// the map, and left alone once the person pans or zooms, until Fit All. The map frames the
// transmitters and never the person: it asks for no location and draws no user annotation, so
// macOS asks for no permission (docs/plans/decoders-app.md, "Decisions"). Tiles come from Apple, which would make a staged run's pictures differ from one run
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
    /// Quiet for half its silence window: drawn dimmed until it ages out.
    var fading: Bool = false

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
                selected: d.selectedTransmitter == e.deviceID, fading: d.fading(e))
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
                StagedMap(points: drawn, region: d.framing.region, select: select)
            } else {
                // One map per decoder, so each opens on its own camera.
                LiveMap(points: drawn, framing: d.framing, select: select)
                    .id(d.selectedName ?? "")
            }
        }
        .overlay(alignment: .topTrailing) {
            if !points.isEmpty { FitAllButton { d.fitAllOnMap() } }
        }
        .stageRegion(.map)
        .identifiedGroup("decoders.map")
    }
}

/// MapKit's map, north up (it pans and zooms but does not rotate, so a marker's heading reads
/// true). It opens on the decoder's region, the rule's or the person's, moves to the rule's next
/// one while the rule follows, and hands a pan or zoom of the person's back as theirs.
struct LiveMap: View {
    let points: [MapPoint]
    let framing: MapFraming
    let select: (String) -> Void
    @Environment(AppSession.self) private var session
    @State private var camera: MapCameraPosition

    init(points: [MapPoint], framing: MapFraming, select: @escaping (String) -> Void) {
        self.points = points
        self.framing = framing
        self.select = select
        _camera = State(initialValue: framing.region.map { .region($0.mapKit) } ?? .automatic)
    }

    var body: some View {
        Map(position: $camera, interactionModes: [.pan, .zoom]) {
            ForEach(points.filter { $0.trail.count > 1 }) { p in
                MapPolyline(
                    coordinates: p.trail.map {
                        CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                    }
                )
                .stroke(
                    p.fading ? Theme.mapTrailFaded : Theme.mapTrail,
                    lineWidth: Theme.Layout.mapTrailWidth)
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
        .onMapCameraChange(frequency: .onEnd) { context in
            // The rule's own moves are not the person's; a pan or zoom is.
            guard camera.positionedByUser else { return }
            session.decoders.personMovedMap(to: MapRegion(context.region))
        }
        .onChange(of: framing) { _, f in
            guard f.following, let r = f.region else { return }
            withAnimation(Theme.mapCameraMove) { camera = .region(r.mapKit) }
        }
    }
}

/// Fit All, in the map's corner as Apple Maps draws its controls: frames every transmitter once
/// and has the map follow them again.
struct FitAllButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.left.and.arrow.down.right").font(Theme.Font.mapControl)
                .foregroundStyle(Theme.inkSecondary)
                .frame(width: Theme.Layout.mapControlSize, height: Theme.Layout.mapControlSize)
                .background(
                    Theme.panel,
                    in: RoundedRectangle(cornerRadius: Theme.Layout.mapControlRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Layout.mapControlRadius)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Fit All")
        .accessibilityLabel("Fit All")
        .accessibilityIdentifier("decoders.map-fit")
        .padding(Theme.Layout.mapControlInset)
    }
}

extension MapRegion {
    init(_ r: MKCoordinateRegion) {
        self.init(
            latitude: r.center.latitude, longitude: r.center.longitude,
            latitudeSpan: r.span.latitudeDelta, longitudeSpan: r.span.longitudeDelta)
    }

    var mapKit: MKCoordinateRegion {
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            span: MKCoordinateSpan(latitudeDelta: latitudeSpan, longitudeDelta: longitudeSpan))
    }
}

/// The staged run's map: an equirectangular projection of the page's `MapFraming` region, the
/// same rule as the real map's camera, with a graticule every `mapGraticuleDegrees`, the trails,
/// and the markers and names as views, so the accessibility tree and a click reach them as on the
/// real map.
struct StagedMap: View {
    let points: [MapPoint]
    let region: MapRegion?
    let select: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let proj = Projection(region: region, points: points, size: geo.size)
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
                                .opacity(p.fading ? Theme.mapFadedOpacity : 1)
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
            let ink =
                p.selected ? Theme.mapSelected : p.fading ? Theme.mapTrailFaded : Theme.mapTrail
            ctx.stroke(path, with: .color(ink), lineWidth: Theme.Layout.mapTrailWidth)
        }
    }

    /// Degrees to points: longitude scaled by the cosine of the middle latitude, so a degree
    /// reads the same distance both ways, and the region fitted inside the inset with its aspect.
    struct Projection {
        let midLat: Double
        let midLon: Double
        let kx: Double
        let scale: Double
        let centre: CGPoint

        /// The region the rule chose, else every point fitted as the rule fits them.
        init(region: MapRegion?, points: [MapPoint], size: CGSize) {
            let r =
                region
                ?? MapRegion.fitting(
                    points.map { MapCoordinate(latitude: $0.latitude, longitude: $0.longitude) },
                    padding: MapFraming.padding, least: MapFraming.leastSpan)
                ?? MapRegion(
                    latitude: 0, longitude: 0, latitudeSpan: MapFraming.leastSpan,
                    longitudeSpan: MapFraming.leastSpan)
            midLat = r.latitude
            midLon = r.longitude
            kx = max(0.01, cos(midLat * .pi / 180))
            let inset = Theme.Layout.mapCanvasInset
            // The names are drawn to the right of their markers, so the right keeps room for one.
            let room = Theme.Layout.mapLabelRoom
            let w = max(1, Double(size.width - 2 * inset - room))
            let h = max(1, Double(size.height - 2 * inset))
            let spanLon = max(1e-6, r.longitudeSpan) * kx
            let spanLat = max(1e-6, r.latitudeSpan)
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
        .opacity(point.fading && !point.selected ? Theme.mapFadedOpacity : 1)
    }
}

extension View {
    /// A marker as one accessibility button named by its transmitter, whose press selects it.
    fileprivate func mapMarkerAccessibility(_ p: MapPoint, select: @escaping (String) -> Void)
        -> some View
    {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(p.name)
            .accessibilityValue(
                [p.heading.map { "heading \(Int($0.rounded()))°" }, p.fading ? "quiet" : nil]
                    .compactMap { $0 }.joined(separator: ", ")
            )
            .accessibilityIdentifier("decoders.map.\(ViewIdentifier.slug(p.id))")
            .pressable { select(p.id) }
    }
}
