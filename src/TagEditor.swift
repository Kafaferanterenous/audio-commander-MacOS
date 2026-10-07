import SwiftUI
import AppKit

/// Backing store for the drawer's metadata editor (#21). One instance lives on
/// CommanderStore so edits survive switching drawer tabs. Pure state: reading
/// and writing goes through `ID3`.
@MainActor
final class TagEditorModel: ObservableObject {
    @Published var fields = AudioTagFields()
    @Published private(set) var artwork: NSImage?
    @Published private(set) var loadedURL: URL?
    @Published private(set) var hadTag = false
    @Published var status: String?
    @Published var isError = false
    @Published private(set) var isDirty = false
    private var saved = AudioTagFields()

    /// Loads `url`'s tags, or clears the editor when nil. Reloading the same
    /// file is a no-op so a redraw cannot discard in-progress edits.
    func load(_ url: URL?) {
        guard let url else {
            loadedURL = nil
            fields = AudioTagFields()
            saved = fields
            artwork = nil
            hadTag = false
            isDirty = false
            isError = false
            status = nil
            return
        }
        guard loadedURL != url else { return }
        do {
            let info = try ID3.read(url: url)
            fields = info.fields
            saved = info.fields
            artwork = info.artwork.flatMap { NSImage(data: $0) }
            hadTag = info.hadTag
            loadedURL = url
            isDirty = false
            isError = false
            status = nil
        } catch {
            loadedURL = url
            fields = AudioTagFields()
            saved = fields
            artwork = nil
            hadTag = false
            isDirty = false
            isError = true
            status = error.localizedDescription
        }
    }

    func markDirty() { isDirty = fields != saved }

    func save() {
        guard let url = loadedURL else { return }
        do {
            try ID3.write(fields: fields, to: url)
            saved = fields
            isDirty = false
            isError = false
            status = AppSettings.shared.t("tagsSaved")
        } catch {
            isError = true
            status = AppSettings.shared.t("tagsSaveFailed")
        }
    }

    func reload() {
        let url = loadedURL
        loadedURL = nil
        load(url)
    }
}

/// Metadata editor shown in the Utilities tab of the flyout drawer. Targets the
/// single selected file in the active pane, or the track that is playing.
struct TagEditorPanel: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject var store: CommanderStore
    @ObservedObject var model: TagEditorModel

    private var target: FileItem? { store.tagTarget }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(settings.t("metadataTitle"))
                    .font(settings.scaled(13).weight(.medium))
                Spacer()
                if model.isDirty {
                    Text(settings.t("tagsUnsaved"))
                        .font(settings.scaled(9))
                        .foregroundStyle(.orange)
                }
            }

            if let target {
                if ID3.isEditable(target.url) {
                    editor(target)
                } else {
                    note(settings.t("tagsMp3Only"))
                }
            } else {
                note(settings.t("tagsNoSelection"))
            }
        }
        .task(id: target?.id) { model.load(target?.url) }
        .onChange(of: model.fields) { _ in model.markDirty() }
    }

    @ViewBuilder
    private func editor(_ target: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                artworkView
                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name)
                        .font(settings.scaled(10).weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(settings.t("tagsFormatNote"))
                        .font(settings.scaled(9))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            field(settings.t("tagTitleLabel"), $model.fields.title)
            field(settings.t("tagArtistLabel"), $model.fields.artist)
            field(settings.t("tagAlbumLabel"), $model.fields.album)
            HStack(spacing: 6) {
                field(settings.t("tagTrackLabel"), $model.fields.track)
                field(settings.t("tagYearLabel"), $model.fields.year)
            }
            field(settings.t("tagGenreLabel"), $model.fields.genre)
            field(settings.t("tagCommentLabel"), $model.fields.comment)

            HStack(spacing: 6) {
                Button {
                    model.save()
                } label: {
                    Label(settings.t("tagSave"), systemImage: "square.and.arrow.down")
                        .font(settings.scaled(11))
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.isDirty)

                Button {
                    model.reload()
                } label: {
                    Label(settings.t("tagReload"), systemImage: "arrow.clockwise")
                        .font(settings.scaled(11))
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding(.top, 2)

            if let status = model.status {
                Text(status)
                    .font(settings.scaled(10))
                    .foregroundStyle(model.isError ? .red : .green)
            }
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let art = model.artwork {
            Image(nsImage: art)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .background(settings.palette.cardOpacityFill,
                            in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func field(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(settings.scaled(9))
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .font(settings.scaled(11))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(settings.scaled(11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
