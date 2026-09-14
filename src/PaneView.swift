import SwiftUI
import UniformTypeIdentifiers

enum PaneSide { case leftPane, rightPane }

struct PaneView: View {
    @ObservedObject var pane: PaneState
    let side: PaneSide
    @FocusState.Binding var focusedPane: PaneSide?
    @EnvironmentObject var settings: AppSettings
    @State private var showImporter = false
    var onCopySelection: (() -> Void)?
    var onMoveSelection: (() -> Void)?
    var onTrashSelection: (() -> Void)?

    private var palette: ThemePalette { settings.palette }
    private var sideTitle: String {
        settings.t(side == .leftPane ? "left" : "right")
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            headerRow
            Divider().overlay(palette.divider)
            list
            Divider().overlay(palette.divider)
            summaryBar
        }
        .background(palette.cardOpacityFill)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder],
                      onCompletion: { result in
            if case .success(let url) = result {
                pane.navigate(to: url)
            }
        })
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(sideTitle)
                .font(settings.scaled(11).weight(.bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)

            opButtons

            Button {
                pane.navigateUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.bordered)
            .help(settings.t("up"))

            Button {
                Task { await pane.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help(settings.t("refresh"))

            Button {
                showImporter = true
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(.bordered)
            .help(settings.t("chooseFolder"))

            if !pane.recentFolders.isEmpty {
                Menu {
                    ForEach(pane.recentFolders, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            pane.navigate(to: url)
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(settings.t("recentFolders"))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(pane.folder.lastPathComponent.isEmpty ? "/" : pane.folder.lastPathComponent)
                    .font(settings.scaled(13).weight(.semibold))
                    .lineLimit(1)
                Text(pane.folder.path)
                    .font(settings.scaled(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    // Mirrored operation buttons: arrows point toward the other pane.
    @ViewBuilder
    private var opButtons: some View {
        let forward = side == .leftPane
        let copyArrow = forward ? "arrow.right.circle.fill" : "arrow.left.circle.fill"
        let moveArrow = forward ? "rectangle.portrait.and.arrow.right"
                                : "rectangle.portrait.and.arrow.left"
        let enabled = !pane.selectedIDs.isEmpty

        Group {
            Button(action: { onCopySelection?() }) {
                HStack(spacing: 3) {
                    Image(systemName: "doc.on.doc").font(settings.scaled(10))
                    Image(systemName: copyArrow).font(settings.scaled(12))
                }
            }
            .buttonStyle(.bordered)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(settings.t("copyToOther"))

            Button(action: { onMoveSelection?() }) {
                Image(systemName: moveArrow).font(settings.scaled(12))
            }
            .buttonStyle(.bordered)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(settings.t("moveToOther"))

            Button(action: { onTrashSelection?() }) {
                Image(systemName: "trash").font(settings.scaled(12))
            }
            .buttonStyle(.bordered)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(settings.t("trashSel"))
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 20, height: 1)
            sortHeader(settings.t("name"), field: .name, width: nil)
            sortHeader(settings.t("size"), field: .size, width: 88)
            sortHeader(settings.t("duration"), field: .duration, width: 84)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private func sortHeader(_ title: String, field: SortField, width: CGFloat?) -> some View {
        Button {
            pane.setSort(field)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                if pane.sortField == field {
                    Text(pane.sortAscending ? "▲" : "▼")
                        .font(settings.scaled(9))
                        .foregroundStyle(palette.accent)
                }
            }
            .font(settings.scaled(11).weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .trailing)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .help(settings.tf("sortHelp", title))
    }

    // MARK: List

    private var list: some View {
        List(pane.items) { item in
            row(item)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 12))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .focused($focusedPane, equals: side)
    }

    private func row(_ item: FileItem) -> some View {
        let isSelected = pane.selectedIDs.contains(item.id)
        return HStack(spacing: 8) {
            Button {
                pane.toggleSelection(item)
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(settings.scaled(13))
                    .foregroundStyle(isSelected ? palette.accent : Color.secondary.opacity(0.55))
            }
            .buttonStyle(.plain)
            .frame(width: 18)
            .help(isSelected ? settings.t("deselect") : settings.t("select"))

            Image(systemName: item.isDirectory ? "folder.fill" : (item.isAudio ? "music.note" : "doc"))
                .font(settings.scaled(12))
                .foregroundStyle(item.isDirectory
                                 ? palette.folderColor
                                 : (item.isAudio ? palette.accent : Color.secondary))
                .frame(width: 18)

            Text(item.name)
                .font(settings.scaled(13))
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(AudioFormats.sizeText(item.size, isDirectory: item.isDirectory))
                .font(settings.scaled(11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 88, alignment: .trailing)

            Text(AudioFormats.durationText(item.duration))
                .font(settings.scaled(11).monospacedDigit())
                .foregroundStyle(item.duration == nil ? Color.secondary.opacity(0.5) : Color.primary.opacity(0.85))
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? palette.accent.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isDirectory { pane.open(item) }
        }
        .onTapGesture(count: 1) {
            if !item.isDirectory { pane.open(item) }
        }
        .contextMenu {
            Button(settings.t("openCtx")) {
                if item.isDirectory { pane.open(item) }
                else if item.isAudio { pane.onAudioToggle?(item) }
            }
            Button(settings.t("finderCtx")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button(isSelected ? settings.t("deselect") : settings.t("select")) {
                pane.toggleSelection(item)
            }
        }
    }

    // MARK: Summary bar

    private var summaryBar: some View {
        HStack(spacing: 8) {
            if pane.totals.songs > 0 {
                Button {
                    if let playlist = pane.audioPlaylist(startingAt: nil) {
                        pane.onPlayRequest?(playlist.items, playlist.startIndex)
                    }
                } label: {
                    Label(settings.t("playAll"), systemImage: "play.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(settings.scaled(11).weight(.medium))
                        .foregroundStyle(palette.accent)
                }
                .buttonStyle(.borderless)
                .help(settings.t("playAllHelp"))
            }
            if pane.isLoadingDurations {
                ProgressView()
                    .controlSize(.mini)
            }
            Text(pane.statusMessage ?? summaryText)
                .font(settings.scaled(11))
                .foregroundStyle(pane.statusMessage == nil ? Color.secondary : Color.orange)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(palette.divider.opacity(0.35))
    }

    private var summaryText: String {
        let s = AppSettings.shared
        var parts: [String] = []
        if pane.totals.folders > 0 {
            parts.append("\(pane.totals.folders) \(s.t("foldersN"))")
        }
        parts.append("\(pane.totals.files) \(s.t("filesN"))")
        if pane.totals.songs > 0 {
            parts.append("\(pane.totals.songs) \(s.t("audioN"))")
        }
        parts.append(ByteCountFormatter.string(fromByteCount: pane.totals.bytes, countStyle: .file))
        if pane.totals.knownCount > 0 {
            parts.append(s.tf("playedLength",
                              AudioFormats.durationText(pane.totals.knownDuration),
                              "\(pane.totals.knownCount)"))
        }
        return parts.joined(separator: " · ")
    }
}
