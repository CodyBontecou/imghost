import SwiftUI
import StoreKit

struct MacPaywallView: View {
    @StateObject private var storeKit = StoreKitManager.shared
    @EnvironmentObject var subscriptionState: SubscriptionState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var showError = false

    var allowDismiss: Bool = false

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    // Hero
                    VStack(spacing: 12) {
                        Text("paywall.title.unlock")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .tracking(4)

                        Text("paywall.title.pro")
                            .font(.system(size: 64, weight: .black))
                            .foregroundStyle(Color.white)
                            .tracking(8)

                        Text("paywall.title.trial")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalSuccess)
                            .tracking(2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Color.brutalSuccess, lineWidth: 1))
                    }

                    // Tier comparison
                    MacTierComparisonView()

                    // Products
                    if storeKit.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if storeKit.products.isEmpty {
                        VStack(spacing: 12) {
                            Text("paywall.error.loading")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.brutalError)

                            Button(action: { Task { await storeKit.reloadProducts() } }) {
                                Text("paywall.button.retry")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.brutalAccent)
                                    .tracking(1)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .overlay(Rectangle().stroke(Color.brutalAccent, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        HStack(spacing: 16) {
                            if let monthly = storeKit.monthlyProduct {
                                MacProductCard(product: monthly, isSelected: selectedProduct?.id == monthly.id, badge: nil) {
                                    selectedProduct = monthly
                                }
                            }

                            if let annual = storeKit.annualProduct {
                                MacProductCard(product: annual, isSelected: selectedProduct?.id == annual.id, badge: String(localized: "paywall.badge.save")) {
                                    selectedProduct = annual
                                }
                            }
                        }
                        .frame(maxWidth: 500)

                        // Subscribe button
                        Button(action: { Task { await purchase() } }) {
                            HStack {
                                if isPurchasing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                        .scaleEffect(0.7)
                                } else {
                                    Text("paywall.button.start_trial")
                                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                                        .tracking(1)
                                }
                            }
                            .foregroundStyle(Color.black)
                            .frame(width: 280, height: 48)
                            .background(selectedProduct != nil ? Color.white : Color.brutalTextTertiary)
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedProduct == nil || isPurchasing)

                        // Restore
                        Button(action: { Task { await restore() } }) {
                            Text("paywall.button.restore")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                                .tracking(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRestoring)

                        // Continue with Free
                        if allowDismiss || subscriptionState.isFree {
                            Button(action: { dismiss() }) {
                                Text("paywall.button.continue_free")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextTertiary)
                                    .tracking(1)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Legal
                    VStack(spacing: 8) {
                        Text("paywall.legal.renewal_notice")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.brutalTextTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)

                        HStack(spacing: 12) {
                            Button(action: { MacURLOpener.open("https://imghost.isolated.tech/terms") }) {
                                Text("paywall.legal.button.terms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextSecondary)
                            }
                            .buttonStyle(.plain)

                            Text("|")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.brutalTextTertiary)

                            Button(action: { MacURLOpener.open("https://imghost.isolated.tech/privacy") }) {
                                Text("paywall.legal.button.privacy")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextSecondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Spacer()
            }
        }
        .task {
            if storeKit.products.isEmpty {
                await storeKit.reloadProducts()
            }
            if selectedProduct == nil {
                selectedProduct = storeKit.monthlyProduct
            }
        }
        .alert(String(localized: "paywall.error.alert.title"), isPresented: $showError) {
            Button(String(localized: "paywall.error.alert.button.ok")) { showError = false }
        } message: {
            Text(verbatim: errorMessage ?? String(localized: "paywall.error.alert.message_fallback"))
        }
    }

    private func purchase() async {
        guard let product = selectedProduct else { return }
        isPurchasing = true
        errorMessage = nil

        do {
            _ = try await storeKit.purchase(product)
            await subscriptionState.checkStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isPurchasing = false
    }

    private func restore() async {
        isRestoring = true
        errorMessage = nil

        do {
            try await storeKit.restorePurchases()
            await subscriptionState.checkStatus()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
        isRestoring = false
    }
}

// MARK: - Tier Comparison Grid

struct MacTierComparisonView: View {
    private let rows: [(label: String, freeKey: String, proKey: String)] = [
        ("paywall.comparison.row.storage",    "paywall.comparison.free.storage",    "paywall.comparison.pro.storage"),
        ("paywall.comparison.row.file_size",  "paywall.comparison.free.file_size",  "paywall.comparison.pro.file_size"),
        ("paywall.comparison.row.link_ttl",   "paywall.comparison.free.link_ttl",   "paywall.comparison.pro.link_ttl"),
        ("paywall.comparison.row.export",     "paywall.comparison.free.export",     "paywall.comparison.pro.export"),
        ("paywall.comparison.row.transforms", "paywall.comparison.free.transforms", "paywall.comparison.pro.transforms"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text(String(localized: "paywall.comparison.free.label"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .tracking(2)
                    .frame(width: 72, alignment: .center)
                Text(String(localized: "paywall.comparison.pro.label"))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .tracking(2)
                    .frame(width: 72, alignment: .center)
            }
            .padding(.bottom, 6)

            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)

            ForEach(rows, id: \.label) { row in
                let free = String(localized: String.LocalizationValue(row.freeKey))
                let pro  = String(localized: String.LocalizationValue(row.proKey))
                let label = String(localized: String.LocalizationValue(row.label))
                HStack {
                    Text(label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(free)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(free == "✕" ? Color.white.opacity(0.2) : Color.brutalTextSecondary)
                        .frame(width: 72, alignment: .center)
                    Text(pro)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(pro == "✓" ? Color.green : Color.white)
                        .frame(width: 72, alignment: .center)
                }
                .padding(.vertical, 7)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            }
        }
        .frame(maxWidth: 420)
    }
}

// MARK: - Feature Item

struct MacFeatureItem: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(Color.white)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.brutalTextSecondary)
                .tracking(1)
        }
        .frame(width: 100)
    }
}

// MARK: - Product Card

struct MacProductCard: View {
    let product: Product
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let badge = badge {
                    Text(badge)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.brutalSuccess)
                        .tracking(1)
                }

                Text(product.displayName)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.white)

                Text(product.displayPrice)
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(Color.white)

                if product.id == StoreKitManager.annualProductID {
                    let monthlyPrice = product.price / 12
                    Text(verbatim: String(format: String(localized: "paywall.price.per_month_format"), monthlyPrice.formatted(.currency(code: product.priceFormatStyle.currencyCode ?? "USD"))))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                } else {
                    Text("paywall.price.per_month_fallback")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(isSelected ? Color.brutalSurfaceElevated : Color.brutalSurface)
            .overlay(
                Rectangle()
                    .stroke(isSelected ? Color.white : Color.brutalBorder, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
