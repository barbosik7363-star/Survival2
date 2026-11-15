import SwiftUI
import MapKit
import SQLite3
import UniformTypeIdentifiers

// MARK: - Чтение растровых тайлов из MBTiles (один файл SQLite)

final class MBTilesSource {
    let url: URL
    private var db: OpaquePointer?
    private let lock = NSLock()

    init?(url: URL) {
        self.url = url
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    }

    deinit { sqlite3_close(db) }

    var maxZoom: Int {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT MAX(zoom_level) FROM tiles", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 14 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    /// MBTiles хранит строки в TMS (y перевёрнут), переводим из XYZ.
    func tile(z: Int, x: Int, y: Int) -> Data? {
        let tmsY = (1 << z) - 1 - y
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "SELECT tile_data FROM tiles WHERE zoom_level = ? AND tile_column = ? AND tile_row = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        sqlite3_bind_int(stmt, 1, Int32(z))
        sqlite3_bind_int(stmt, 2, Int32(x))
        sqlite3_bind_int(stmt, 3, Int32(tmsY))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(stmt, 0) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
    }
}

// MARK: - Оверлей, который заменяет базовую карту Apple (без интернета)

final class OfflineTileOverlay: MKTileOverlay {
    private let source: MBTilesSource

    init(source: MBTilesSource) {
        self.source = source
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        minimumZ = 0
        maximumZ = source.maxZoom
        tileSize = CGSize(width: 256, height: 256)
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        result(source.tile(z: path.z, x: path.x, y: path.y), nil)
    }
}

// MARK: - Хранилище файла карты

@MainActor
final class MapStore: ObservableObject {
    @Published var source: MBTilesSource?
    @Published var isImporting = false
    @Published var error: String?

    private let fileURL = URL.documentsDirectory.appending(path: "ukraine.mbtiles")

    init() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            source = MBTilesSource(url: fileURL)
        }
    }

    func importMap(from picked: URL) async {
        isImporting = true
        defer { isImporting = false }
        let dest = fileURL
        do {
            try await Task.detached(priority: .userInitiated) {
                let scoped = picked.startAccessingSecurityScopedResource()
                defer { if scoped { picked.stopAccessingSecurityScopedResource() } }
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: picked, to: dest)
            }.value
            source = MBTilesSource(url: fileURL)
            error = source == nil ? String(localized: "Файл не похож на MBTiles") : nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Представление карты (UIKit MKMapView внутри SwiftUI)

struct MapRepresentable: UIViewRepresentable {
    let source: MBTilesSource
    let points: [Waypoint]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.showsCompass = true
        map.pointOfInterestFilter = .excludingAll
        map.setRegion(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 48.9, longitude: 31.2),
            span: MKCoordinateSpan(latitudeDelta: 9, longitudeDelta: 14)), animated: false)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        if c.loadedURL != source.url {
            if let old = c.overlay { map.removeOverlay(old) }
            let o = OfflineTileOverlay(source: source)
            map.addOverlay(o, level: .aboveLabels)
            c.overlay = o
            c.loadedURL = source.url
        }
        let ids = points.map(\.id)
        if ids != c.lastIDs {
            c.lastIDs = ids
            map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
            map.addAnnotations(points.map { p in
                let a = MKPointAnnotation()
                a.title = p.name
                a.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
                return a
            })
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var overlay: MKTileOverlay?
        var loadedURL: URL?
        var lastIDs: [UUID] = []

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let t = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: t) }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Карточка карты с выбором файла и анимациями

struct OfflineMapCard: View {
    @StateObject private var store = MapStore()
    @EnvironmentObject var nav: Nav
    @State private var picking = false

    var body: some View {
        VStack(spacing: 12) {
            if let src = store.source {
                ZStack(alignment: .bottomTrailing) {
                    MapRepresentable(source: src, points: nav.points)
                        .clipShape(.rect(cornerRadius: 24))
                    Text("© OpenStreetMap contributors")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .padding(10)
                }
                .frame(height: 420)
                .transition(.opacity.combined(with: .scale(0.96)))

                Button { picking = true } label: {
                    Label("Заменить файл карты", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass).controlSize(.large)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "map.fill").font(.system(size: 44))
                    Text("Офлайн-карта не загружена")
                        .font(.headline)
                    Text("Выберите файл Ukraine.mbtiles (растровые тайлы OpenStreetMap). Сохраните его в «Файлы» и выберите здесь. Интернет после этого не нужен.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button { picking = true } label: {
                        Label("Выбрать файл карты", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass).controlSize(.large)
                }
                .padding(20)
                .frame(maxWidth: .infinity)
                .glassEffect(.regular, in: .rect(cornerRadius: 24))
            }

            if store.isImporting {
                ProgressView("Копирую файл карты…")
            }
            if let err = store.error {
                Text(err).font(.footnote).foregroundStyle(.red)
            }
        }
        .animation(.smooth, value: store.source != nil)
        .fileImporter(isPresented: $picking,
                      allowedContentTypes: [UTType(filenameExtension: "mbtiles") ?? .data]) { result in
            if case .success(let url) = result {
                Task { await store.importMap(from: url) }
            }
        }
    }
}
