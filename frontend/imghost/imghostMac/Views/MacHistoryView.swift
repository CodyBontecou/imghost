import SwiftUI

struct MacHistoryView: View {
    @State private var records: [UploadRecord] = []
    @State private var isLoading = true
    @State private var selectedRecord: UploadRecord?
    @State private var searchText = ""
    @State private var isSyncing = false

    private let historyService = HistoryService.shared

    private var filteredRecords: [UploadRecord] {
        if searchText.isEmpty {
            return records
        }
        return records.filter { record in
            (record.originalFilename ?? "").localizedCaseInsensitiveContains(searchText) ||
            record.url.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var groupedRecords: [(String, [UploadRecord])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        let grouped = Dictionary(grouping: filteredRecords) { record in
            formatter.string(from: record.createdAt)
        }

        return grouped.sorted { lhs, rhs in
            guard let lhsDate = lhs.value.first?.createdAt,
                  let rhsDate = rhs.value.first?.createdAt else { return false }
            return lhsDate > rhsDate
        }
    }

    var body: some View {
        HSplitView {
            // Left: Grid
            VStack(spacing: 0) {
                // Toolbar
                HStack(spacing: 12) {
                    Text("history.title")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .tracking(2)

                    Spacer()

                    // Search
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)

                        TextField(String(localized: "history.search.placeholder"), text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 140)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.brutalSurface)
                    .overlay(Rectangle().stroke(Color.brutalBorder, lineWidth: 1))

                    // Sync button
                    Button(action: syncImages) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.brutalTextSecondary)
                            .rotationEffect(.degrees(isSyncing ? 360 : 0))
                            .animation(isSyncing ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isSyncing)
                    }
                    .buttonStyle(.plain)

                    Text("\(filteredRecords.count)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.brutalSurface)

                Divider().background(Color.brutalBorder)

                if isLoading {
                    Spacer()
                    BrutalLoading(text: String(localized: "history.loading"))
                    Spacer()
                } else if filteredRecords.isEmpty {
                    Spacer()
                    BrutalEmptyState(
                        title: searchText.isEmpty ? String(localized: "history.empty.title") : String(localized: "history.search.empty.title"),
                        subtitle: searchText.isEmpty ? String(localized: "history.empty.subtitle") : String(localized: "history.search.empty.subtitle")
                    )
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groupedRecords, id: \.0) { date, items in
                                // Date header
                                Text(date.uppercased())
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextTertiary)
                                    .tracking(1.5)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)

                                // Grid
                                LazyVGrid(columns: [
                                    GridItem(.adaptive(minimum: 100, maximum: 140), spacing: 2)
                                ], spacing: 2) {
                                    ForEach(items) { record in
                                        MacThumbnailCell(
                                            record: record,
                                            isSelected: selectedRecord?.id == record.id
                                        )
                                        .onTapGesture {
                                            selectedRecord = record
                                        }
                                    }
                                }
                                .padding(.horizontal, 2)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                }
            }
            .frame(minWidth: 300)
            .background(Color.brutalBackground)

            // Right: Detail
            if let record = selectedRecord {
                MacUploadDetailView(record: record, onDelete: {
                    deleteRecord(record)
                })
                .frame(minWidth: 280, idealWidth: 320)
            } else {
                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.brutalTextTertiary)
                        Text("history.detail.placeholder")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalTextTertiary)
                            .tracking(2)
                    }
                    Spacer()
                }
                .frame(minWidth: 280, idealWidth: 320)
                .background(Color.brutalSurface.opacity(0.5))
            }
        }
        .task {
            loadRecords()
        }
    }

    private func loadRecords() {
        isLoading = true
        do {
            records = try historyService.loadAll()
        } catch {
            print("Failed to load history: \(error)")
        }
        isLoading = false
    }

    private func syncImages() {
        isSyncing = true
        Task {
            do {
                try await ImageSyncService.shared.syncImages()
                await MainActor.run {
                    loadRecords()
                }
            } catch {
                print("Sync failed: \(error)")
            }
            await MainActor.run {
                isSyncing = false
            }
        }
    }

    private func deleteRecord(_ record: UploadRecord) {
        Task {
            do {
                try await MacUploadService.shared.delete(record: record)
                try historyService.delete(id: record.id)
                await MainActor.run {
                    records.removeAll { $0.id == record.id }
                    if selectedRecord?.id == record.id {
                        selectedRecord = nil
                    }
                }
            } catch {
                print("Delete failed: \(error)")
            }
        }
    }
}

// MARK: - Thumbnail Cell

struct MacThumbnailCell: View {
    let record: UploadRecord
    let isSelected: Bool

    var body: some View {
        Color.brutalSurface
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Group {
                    if let data = record.thumbnailData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(Color.brutalTextTertiary)
                    }
                }
            )
            .clipped()
            .overlay(
                Rectangle()
                    .stroke(isSelected ? Color.white : Color.clear, lineWidth: 2)
            )
    }
}
