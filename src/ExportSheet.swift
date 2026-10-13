import SwiftUI
import AppKit

/// The Export / Convert sheet (#26). Opened from a pane's context menu, the
/// File menu, or the pane summary when a selection exists.
struct ExportSheet: View {
    @ObservedObject var exporter: Exporter
    @EnvironmentObject private var settings: AppSettings

    private var palette: ThemePalette { settings.palette }
    private var o: ExportOptions { exporter.options }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            sourceList
            optionsForm
            destinationRow
            if exporter.isRunning { progressRow }
            if !exporter.reports.isEmpty { reportList }
            footer
        }
        .padding(18)
        .frame(width: 520)
        .background(LinearGradient(colors: [palette.bgTop, palette.bgBottom],
                                   startPoint: .top, endPoint: .bottom))
        .preferredColorScheme(palette.colorScheme)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(palette.accent)
            Text(settings.t("exportTitle"))
                .font(settings.scaled(15).weight(.semibold))
            Spacer()
            Text(settings.tf("exportSources", exporter.sources.count))
                .font(settings.scaled(11))
                .foregroundStyle(.secondary)
        }
    }

    private var sourceList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(exporter.sources, id: \.path) { url in
                    HStack(spacing: 6) {
                        Image(systemName: "music.note")
                            .font(settings.scaled(10))
                            .foregroundStyle(.secondary)
                        Text(url.lastPathComponent)
                            .font(settings.scaled(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                }
            }
        }
        .frame(maxHeight: 84)
        .padding(8)
        .background(palette.cardOpacityFill, in: RoundedRectangle(cornerRadius: 6))
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeled(settings.t("exportFormat")) {
                Picker("", selection: formatBinding) {
                    ForEach(ExportFormat.allCases) { f in
                        Text(settings.t(f.titleKey)).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            labeled(settings.t("exportDepth")) {
                Picker("", selection: depthBinding) {
                    ForEach(o.format.allowedDepths) { d in
                        Text(settings.t(d.titleKey)).tag(d)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Toggle(settings.t("exportNormalize"), isOn: $exporter.options.normalize)
                .font(settings.scaled(12))
            Toggle(settings.t("exportReplayGain"), isOn: $exporter.options.replayGain)
                .font(settings.scaled(12))
            if !o.depth.isFloat {
                Toggle(settings.t("exportDither"), isOn: $exporter.options.dither)
                    .font(settings.scaled(12))
                Toggle(settings.t("exportShaping"), isOn: $exporter.options.noiseShaping)
                    .font(settings.scaled(12))
                    .disabled(!o.dither)
                    .opacity(o.dither ? 1 : 0.45)
            }
        }
    }

    private func labeled<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(settings.scaled(11).weight(.medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var destinationRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(exporter.destination?.path ?? settings.t("exportSameFolder"))
                .font(settings.scaled(11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(settings.t("exportChoose")) { chooseDestination() }
                .controlSize(.small)
                .disabled(exporter.isRunning)
            if exporter.destination != nil {
                Button {
                    exporter.destination = nil
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain)
                    .disabled(exporter.isRunning)
            }
        }
    }

    private var progressRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: exporter.progress)
                .progressViewStyle(.linear)
            Text(settings.t("exportRunning"))
                .font(settings.scaled(10))
                .foregroundStyle(.secondary)
        }
    }

    private var reportList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(exporter.reports.enumerated()), id: \.offset) { _, report in
                    reportRow(report)
                }
            }
        }
        .frame(maxHeight: 150)
        .padding(8)
        .background(palette.cardOpacityFill, in: RoundedRectangle(cornerRadius: 6))
    }

    private func reportRow(_ r: ExportReport) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(settings.scaled(10))
                    .foregroundStyle(r.ok ? Color.green : Color.orange)
                Text(r.sourceName)
                    .font(settings.scaled(11).weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if r.ok {
                    Text("\(r.format.rawValue.uppercased()) \(r.depth.shortLabel)")
                        .font(settings.scaled(10))
                        .foregroundStyle(.secondary)
                }
            }
            Text(reportDetail(r))
                .font(settings.scaled(10))
                .foregroundStyle(.secondary)
        }
    }

    private func reportDetail(_ r: ExportReport) -> String {
        guard r.ok else { return r.error ?? settings.t("exportWriteFailed") }
        let lufs = r.loudnessLUFS.map { String(format: "%.1f", $0) } ?? "—"
        let peak = r.peakDBFS.isFinite ? String(format: "%.1f", r.peakDBFS) : "—"
        let tp = r.truePeakDBTP.isFinite ? String(format: "%.1f", r.truePeakDBTP) : "—"
        let gain = String(format: "%+.1f", r.gainDB)
        return settings.tf("exportReport", lufs, peak, tp, gain)
    }

    private var footer: some View {
        HStack {
            if let status = exporter.statusText {
                Text(status)
                    .font(settings.scaled(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(settings.t("exportCancel")) { exporter.cancel() }
                .keyboardShortcut(.cancelAction)
                .disabled(exporter.isRunning)
            Button(settings.t("exportStart")) { exporter.run() }
                .keyboardShortcut(.defaultAction)
                .disabled(exporter.isRunning || exporter.sources.isEmpty)
        }
    }

    // MARK: Bindings

    private var formatBinding: Binding<ExportFormat> {
        Binding(get: { o.format }, set: { newValue in
            exporter.options.format = newValue
            if !newValue.supports(exporter.options.depth) {
                exporter.options.depth = newValue.allowedDepths[0]
            }
        })
    }

    private var depthBinding: Binding<ExportBitDepth> {
        Binding(get: { o.depth }, set: { exporter.options.depth = $0 })
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = settings.t("exportChoose")
        if panel.runModal() == .OK, let url = panel.url {
            exporter.destination = url
        }
    }
}
