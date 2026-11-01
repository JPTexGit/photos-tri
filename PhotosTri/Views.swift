import SwiftUI
import Photos

// MARK: - Éléments communs

struct Thumb: View {
    let asset: PHAsset
    var side: CGFloat = 64
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.gray.opacity(0.2)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .cornerRadius(6)
        .overlay(alignment: .bottomTrailing) {
            if asset.mediaType == .video {
                Image(systemName: "video.fill")
                    .font(.caption2)
                    .padding(3)
                    .foregroundColor(.white)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(2)
            }
        }
        .onAppear { load() }
    }

    private func load() {
        guard image == nil else { return }
        let scale = UIScreen.main.scale
        let opts = PHImageRequestOptions()
        opts.deliveryMode = .opportunistic
        opts.resizeMode = .fast
        opts.isNetworkAccessAllowed = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side * scale, height: side * scale),
            contentMode: .aspectFill,
            options: opts
        ) { img, _ in
            if let img { DispatchQueue.main.async { self.image = img } }
        }
    }
}

struct ItemRow: View {
    @EnvironmentObject var lib: Library
    let item: Item
    var badge: String? = nil

    var body: some View {
        let on = lib.selected.contains(item.id)
        HStack(spacing: 12) {
            Thumb(asset: item.asset)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(fmt(item.size)).font(.headline).monospacedDigit()
                    if let badge { Text(badge).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.2)).cornerRadius(4) }
                }
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(on ? .red : .secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { lib.toggle(item) }
    }

    private var subtitle: String {
        let a = item.asset
        var parts = [String]()
        if let d = a.creationDate { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        parts.append("\(a.pixelWidth)×\(a.pixelHeight)")
        if a.mediaType == .video {
            let s = Int(a.duration)
            parts.append(String(format: "%d:%02d", s / 60, s % 60))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Racine

struct RootView: View {
    @EnvironmentObject var lib: Library
    @State private var confirm = false

    var body: some View {
        Group {
            if lib.authorized {
                MainTabs()
                    .safeAreaInset(edge: .bottom) { deleteBar }
                    .overlay { if lib.scanning { ScanOverlay() } }
            } else {
                welcome
            }
        }
        .task { await lib.start() }
        .alert("Terminé", isPresented: Binding(get: { lib.message != nil }, set: { if !$0 { lib.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(lib.message ?? "") }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.stack").font(.system(size: 56))
            Text("Photos Tri").font(.largeTitle.bold())
            Text("Trie ta photothèque par taille, lieu et doublons. Tout reste sur ton iPhone.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            if lib.denied {
                Text("Accès refusé. Autorise-le dans Réglages > Photos Tri > Photos.")
                    .font(.footnote).foregroundColor(.red).multilineTextAlignment(.center)
            }
            Button("Analyser ma photothèque") { Task { await lib.requestAccess() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    @ViewBuilder private var deleteBar: some View {
        if !lib.selected.isEmpty {
            HStack {
                Button("Tout désélectionner") { lib.clearSelection() }.font(.footnote)
                Spacer()
                Button(role: .destructive) { confirm = true } label: {
                    Text("Supprimer \(lib.selected.count) · \(fmt(lib.selectedBytes))").bold()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .confirmationDialog("Supprimer \(lib.selected.count) éléments ?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Supprimer", role: .destructive) { Task { await lib.deleteSelected() } }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Ils iront dans « Supprimés récemment » pendant 30 jours. L'espace n'est libéré qu'après avoir vidé cet album.")
            }
        }
    }
}

struct ScanOverlay: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        VStack(spacing: 12) {
            ProgressView(value: lib.progress).frame(width: 200)
            Text("Analyse de la photothèque… \(Int(lib.progress * 100)) %").font(.footnote)
        }
        .padding(24)
        .background(.regularMaterial)
        .cornerRadius(14)
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            SizeView().tabItem { Label("Tailles", systemImage: "externaldrive") }
            PlacesView().tabItem { Label("Lieux", systemImage: "map") }
            DuplicatesView().tabItem { Label("Doublons", systemImage: "square.on.square") }
            SimilarView().tabItem { Label("Similaires", systemImage: "photo.on.rectangle") }
        }
    }
}

// MARK: - Tailles

struct SizeView: View {
    @EnvironmentObject var lib: Library
    enum Kind: String, CaseIterable { case all = "Tout", video = "Vidéos", photo = "Photos" }
    @State private var kind = Kind.video

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(lib.items.count) éléments · \(fmt(lib.totalBytes)) au total · vidéos : \(fmt(lib.videoBytes))")
                        .font(.footnote).foregroundColor(.secondary)
                    Picker("Type", selection: $kind) {
                        ForEach(Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                Section("Les 300 plus lourds") {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { _, it in
                        ItemRow(item: it)
                    }
                }
            }
            .navigationTitle("Par taille")
        }
    }

    private var shown: [Item] {
        Array(lib.bySize.lazy.filter { it in
            switch kind {
            case .all: return true
            case .video: return it.isVideo
            case .photo: return !it.isVideo
            }
        }.prefix(300))
    }
}

// MARK: - Lieux

struct PlacesView: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        NavigationStack {
            List(lib.places) { p in
                NavigationLink(destination: PlaceDetail(placeID: p.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.headline)
                        Text("\(p.items.count) éléments · \(fmt(p.bytes))")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Par lieu")
        }
    }
}

struct PlaceDetail: View {
    @EnvironmentObject var lib: Library
    let placeID: String
    var body: some View {
        let group = lib.places.first { $0.id == placeID }
        List {
            ForEach((group?.items ?? []).sorted { $0.size > $1.size }.prefix(500).map { $0 }, id: \.id) { ItemRow(item: $0) }
        }
        .navigationTitle(group?.name ?? "Lieu")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Doublons

struct DuplicatesView: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Même date à la seconde, mêmes dimensions et même taille : ce sont des copies identiques. Le premier de chaque groupe est conservé.")
                        .font(.footnote).foregroundColor(.secondary)
                    Button("Présélectionner les copies (\(extraCount))") {
                        lib.selectAllButFirst(in: lib.duplicateGroups)
                    }.disabled(lib.duplicateGroups.isEmpty)
                }
                ForEach(Array(lib.duplicateGroups.enumerated()), id: \.offset) { n, g in
                    Section("Groupe \(n + 1) · \(g.count) copies · \(fmt(lib.groupBytes(g)))") {
                        ForEach(Array(g.enumerated()), id: \.element.id) { i, it in
                            ItemRow(item: it, badge: i == 0 ? "À garder" : nil)
                        }
                    }
                }
                if lib.duplicateGroups.isEmpty && !lib.scanning {
                    Text("Aucun doublon exact trouvé.").foregroundColor(.secondary)
                }
            }
            .navigationTitle("Doublons")
        }
    }
    private var extraCount: Int { lib.duplicateGroups.reduce(0) { $0 + $1.count - 1 } }
}

// MARK: - Similaires

struct SimilarView: View {
    @EnvironmentObject var lib: Library
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Photos prises à moins de 2 minutes d'écart et visuellement proches (rafales, séries). La plus lourde de chaque groupe est conservée.")
                        .font(.footnote).foregroundColor(.secondary)
                    if lib.analyzingSimilar {
                        HStack { ProgressView(); Text("Analyse en cours…") }
                    } else {
                        Button(lib.similarDone ? "Relancer l'analyse" : "Analyser les similaires") {
                            Task { await lib.analyzeSimilar() }
                        }
                    }
                    if !lib.similarGroups.isEmpty {
                        Button("Présélectionner les autres") {
                            lib.selectAllButFirst(in: lib.similarGroups)
                        }
                    }
                }
                ForEach(Array(lib.similarGroups.enumerated()), id: \.offset) { n, g in
                    Section("Série \(n + 1) · \(g.count) photos · \(fmt(lib.groupBytes(g)))") {
                        ForEach(Array(g.enumerated()), id: \.element.id) { i, it in
                            ItemRow(item: it, badge: i == 0 ? "À garder" : nil)
                        }
                    }
                }
                if lib.similarDone && lib.similarGroups.isEmpty {
                    Text("Aucune série similaire trouvée.").foregroundColor(.secondary)
                }
            }
            .navigationTitle("Similaires")
        }
    }
}
