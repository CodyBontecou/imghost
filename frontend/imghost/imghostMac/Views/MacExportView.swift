import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Export State

enum MacExportState {
    case idle
    case starting
    case exporting(progress: Double)
    case downloading(progress: Double)
    case complete
    case error(String)
}

// MARK: - Export View

struct MacExportView: View {
    @Binding var exportState: MacExportState
    let exportedFileURL: URL?
    let onStartExport: () -> Void
    let onCancelExport: () -> Void
    let onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Title bar
                HStack {
                    Text("EXPORT DATA")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .tracking(2)
                    Spacer()
                    Button {
                        onDismiss()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.brutalTextSecondary)
                            .frame(width: 26, height: 26)
                            .background(Color.brutalSurface)
                            .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 4)

                Rectangle()
                    .fill(Color.brutalBorder)
                    .frame(height: 1)
                    .padding(.horizontal, 28)

                // Content
                VStack(spacing: 24) {
                    Spacer()
                    stateView
                    Spacer()
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Per-state content

    @ViewBuilder
    private var stateView: some View {
        switch exportState {
        case .idle:
            idleContent
        case .starting:
            BrutalLoading(text: String(localized: "settings.export.state.starting"))
        case .exporting(let p):
            progressContent(progress: p, label: String(localized: "settings.export.state.exporting"))
        case .downloading(let p):
            progressContent(progress: p, label: String(localized: "settings.export.state.downloading"))
        case .complete:
            completeContent
        case .error(let msg):
            errorContent(message: msg)
        }
    }

    private var idleContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36, weight: .thin))
                .foregroundStyle(Color.white)

            VStack(spacing: 8) {
                Text("settings.export.title")
                    .font(.system(size: 22, weight: .black))
                    .foregroundStyle(Color.white)

                Text("settings.export.description")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brutalTextSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            BrutalPrimaryButton(
                title: String(localized: "settings.export.button.start"),
                action: onStartExport
            )
            .frame(width: 220)
        }
    }

    private func progressContent(progress: Double, label: String) -> some View {
        VStack(spacing: 20) {
            Text(verbatim: "\(Int(progress * 100))%")
                .font(.system(size: 48, weight: .black, design: .monospaced))
                .foregroundStyle(Color.white)

            BrutalProgressBar(progress: progress)
                .frame(width: 260, height: 4)

            Text(label.uppercased())
                .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                .tracking(2)

            BrutalSecondaryButton(
                title: String(localized: "settings.export.button.cancel")
            ) {
                onCancelExport()
                dismiss()
            }
            .frame(width: 140)
        }
    }

    private var completeContent: some View {
        VStack(spacing: 20) {
            Text(String(localized: "settings.export.state.complete.icon"))
                .font(.system(size: 52, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalSuccess)

            Text("settings.export.state.complete.title")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.white)

            VStack(spacing: 10) {
                if exportedFileURL != nil {
                    BrutalPrimaryButton(
                        title: String(localized: "settings.export.mac.button.save_finder"),
                        action: saveToFinder
                    )
                    .frame(width: 220)
                }

                BrutalTextButton(
                    title: String(localized: "settings.export.state.complete.button.done")
                ) {
                    onDismiss()
                    dismiss()
                }
            }
        }
    }

    private func errorContent(message: String) -> some View {
        VStack(spacing: 20) {
            Text(String(localized: "settings.export.state.failed.icon"))
                .font(.system(size: 52, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brutalError)

            Text("settings.export.state.failed.title")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.white)

            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.brutalTextSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(5)
                .padding(.horizontal, 8)

            VStack(spacing: 10) {
                BrutalPrimaryButton(
                    title: String(localized: "settings.export.state.failed.button.retry"),
                    action: onStartExport
                )
                .frame(width: 160)

                BrutalTextButton(
                    title: String(localized: "settings.export.state.failed.button.cancel")
                ) {
                    onDismiss()
                    dismiss()
                }
            }
        }
    }

    // MARK: - Actions

    private func saveToFinder() {
        guard let source = exportedFileURL else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = source.lastPathComponent
        panel.allowedContentTypes = [UTType.zip]
        panel.canCreateDirectories = true
        panel.title = "Save Export Archive"
        panel.prompt = "Save"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            print("[MacExportView] Failed to copy archive: \(error)")
        }
    }
}
