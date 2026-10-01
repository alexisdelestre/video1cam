import SwiftUI
import RecorderCore

struct MainView: View {
    @ObservedObject var state: AppState
    let actions: MainActions

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if !state.screenPermission {
                    Section {
                        Label {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Autorisation « Enregistrement de l'écran » requise").bold()
                                Text("Activez Video1Cam dans Réglages Système › Confidentialité et sécurité › Enregistrement de l'écran et de l'audio système, puis relancez l'app.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Ouvrir les Réglages…", action: actions.openScreenSettings)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }

                Section("Source") {
                    Picker("Capturer", selection: $state.mode) {
                        ForEach(CaptureMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if state.mode == .fullScreen {
                        Picker("Écran", selection: $state.displayID) {
                            ForEach(state.screens) { Text($0.name).tag($0.id) }
                        }
                    } else {
                        HStack {
                            if let r = state.region {
                                Text("\(Int(r.rect.width)) × \(Int(r.rect.height)) pt sur \(state.screens.first { $0.id == r.displayID }?.name ?? "écran")")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Aucune zone sélectionnée").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(state.region == nil ? "Sélectionner…" : "Changer…", action: actions.selectRegion)
                        }
                    }
                }

                Section("Caméra") {
                    Toggle("Bulle caméra", isOn: $state.cameraEnabled)
                    if state.cameraEnabled {
                        Picker("Caméra", selection: $state.cameraID) {
                            Text("Par défaut").tag("")
                            ForEach(state.cameras) { Text($0.name).tag($0.id) }
                        }
                        Picker("Taille", selection: $state.bubbleSize) {
                            ForEach(BubbleSize.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text("Déplacez la bulle à la souris. Elle est incluse dans la vidéo.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Audio") {
                    Toggle("Micro", isOn: $state.micEnabled)
                    if state.micEnabled {
                        Picker("Micro", selection: $state.micID) {
                            Text("Par défaut du système").tag("")
                            ForEach(state.microphones) { Text($0.name).tag($0.id) }
                        }
                    }
                    Toggle("Son du Mac (audio système)", isOn: $state.systemAudioEnabled)
                }

                Section("Vidéo") {
                    Picker("Qualité", selection: $state.quality) {
                        ForEach(Quality.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Images/s", selection: $state.fps) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                    }
                    .pickerStyle(.segmented)
                    Picker("Format", selection: $state.codec) {
                        Text("H.264 (compatible partout)").tag(VideoSettings.Codec.h264)
                        Text("HEVC (≈ 35 % plus léger)").tag(VideoSettings.Codec.hevc)
                    }
                    Toggle("Mettre en évidence les clics", isOn: $state.showClicks)
                    Toggle("Compte à rebours de 3 s", isOn: $state.countdown)
                }

                Section("Dossier des vidéos") {
                    HStack {
                        Text(state.outputFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(state.outputFolder.path)
                        Spacer()
                        Button("Choisir…", action: actions.chooseFolder)
                        Button("Ouvrir", action: actions.openFolder)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(state.status.isBusy)

            Divider()
            HStack {
                Text("⌥⇧⌘R démarrer/arrêter  •  ⌥⇧⌘P pause")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: actions.toggleRecording) {
                    Label(state.status == .idle ? "Enregistrer" : "Arrêter", systemImage: state.status == .idle ? "record.circle" : "stop.fill")
                        .frame(minWidth: 110)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .tint(.red)
                .buttonStyle(.borderedProminent)
                .disabled(state.status == .preparing || state.status == .finalizing)
            }
            .padding(14)
        }
        .frame(minWidth: 440, idealWidth: 440, maxWidth: 440, minHeight: 420)
    }
}

struct MainActions {
    var toggleRecording: () -> Void
    var selectRegion: () -> Void
    var chooseFolder: () -> Void
    var openFolder: () -> Void
    var openScreenSettings: () -> Void
}

// MARK: - After recording

@MainActor
final class PostRecordingModel: ObservableObject {
    enum Phase: Equatable { case finalizing(Double), done(URL), failed(String) }
    @Published var phase: Phase = .finalizing(0)
    @Published var title = ""
    @Published var renameError: String?
    let startDate: Date
    let duration: TimeInterval
    init(startDate: Date, duration: TimeInterval) {
        self.startDate = startDate
        self.duration = duration
    }
    var proposedName: String { FileNaming.baseName(date: startDate, title: title) + ".mp4" }
}

struct PostRecordingView: View {
    @ObservedObject var model: PostRecordingModel
    var onSave: () -> Void
    var onReveal: () -> Void
    var onOpen: () -> Void
    var onCopyPath: () -> Void
    var onTrash: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .finalizing(let p):
                Text("Finalisation de la vidéo…").font(.headline)
                ProgressView(value: p)
                Text("Durée : \(formatDuration(model.duration))").font(.caption).foregroundStyle(.secondary)
                titleField
            case .done(let url):
                Label("Vidéo enregistrée", systemImage: "checkmark.circle.fill")
                    .font(.headline).foregroundStyle(.green)
                Text(url.lastPathComponent).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("\(formatDuration(model.duration)) • \(fileSize(url))").font(.caption).foregroundStyle(.secondary)
                titleField
                if let e = model.renameError { Text(e).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Afficher dans le Finder", action: onReveal)
                    Button("Lire", action: onOpen)
                    Button("Copier le chemin", action: onCopyPath)
                    Spacer()
                    Button(role: .destructive, action: onTrash) { Image(systemName: "trash") }
                        .help("Placer dans la corbeille")
                }
                HStack {
                    Spacer()
                    Button("Fermer", action: onClose)
                    Button("Renommer", action: onSave)
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.proposedName == url.lastPathComponent)
                }
            case .failed(let msg):
                Label("La finalisation a échoué", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline).foregroundStyle(.orange)
                Text(msg).font(.callout).textSelection(.enabled)
                HStack {
                    Button("Afficher dans le Finder", action: onReveal)
                    Spacer()
                    Button("Fermer", action: onClose).keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Titre (ex. « Passation module facturation »)", text: $model.title)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if case .done = model.phase { onSave() } }
            Text("Nom du fichier : \(model.proposedName)")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func fileSize(_ url: URL) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
