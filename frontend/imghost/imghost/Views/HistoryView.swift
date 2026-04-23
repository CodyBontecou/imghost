import SwiftUI

struct HistoryView: View {
    @State private var records: [UploadRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var deletingIds: Set<String> = []
    @State private var selectedRecord: UploadRecord?
    @EnvironmentObject private var subscriptionState: SubscriptionState

    var body: some View {
        NavigationStack {
            ZStack {
                Color.brutalBackground.ignoresSafeArea()

                Group {
                    if isLoading {
                        BrutalLoading(text: String(localized: "state.loading"))
                    } else if let error = errorMessage {
                        BrutalEmptyState(
                            title: String(localized: "history.error.title"),
                            subtitle: error,
                            action: loadHistory,
                            actionTitle: String(localized: "history.error.button.retry")
                        )
                    } else if records.isEmpty {
                        VStack(spacing: 24) {
                            Text("history.empty.title")
                                .font(.system(size: 48, weight: .black))
                                .foregroundStyle(.white)
                                .multilineTextAlignment(.center)

                            VStack(spacing: 8) {
                                Text("history.empty.subtitle.upload")
                                    .brutalTypography(.bodyMedium, color: .brutalTextSecondary)
                                    .multilineTextAlignment(.center)

                                Text("history.empty.subtitle.sync")
                                    .brutalTypography(.bodyMedium, color: .brutalTextTertiary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .padding(32)
                    } else {
                        PhotoGridView(
                            records: records,
                            onSelect: { record in
                                selectedRecord = record
                            },
                            onDelete: { record in
                                deleteRecord(record)
                            }
                        )
                        .refreshable {
                            loadHistory()
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("history.title")
                        .brutalTypography(.mono)
                        .tracking(2)
                }
            }
            .toolbarBackground(Color.brutalBackground, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selectedRecord) { record in
                UploadDetailView(record: record, onDelete: {
                    deleteRecord(record)
                })
            }
            .onAppear {
                loadHistory()
            }
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Banner ad — shown only for free/unsubscribed users
                if subscriptionState.isFree {
                    AdBannerView()
                        .background(Color.brutalBackground)
                }
            }
        }
    }

    private func loadHistory() {
        isLoading = true
        errorMessage = nil

        do {
            records = try HistoryService.shared.loadAll()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func deleteRecord(_ record: UploadRecord) {
        deletingIds.insert(record.id)

        Task {
            // Try to delete from server
            do {
                try await UploadService.shared.delete(record: record)
            } catch {
                // Continue with local deletion even if server delete fails
                print("Server delete failed: \(error)")
            }

            // Delete from local history
            do {
                try HistoryService.shared.delete(id: record.id)
                await MainActor.run {
                    records.removeAll { $0.id == record.id }
                    deletingIds.remove(record.id)
                }
            } catch {
                await MainActor.run {
                    deletingIds.remove(record.id)
                }
            }
        }
    }
}

#Preview {
    HistoryView()
}
