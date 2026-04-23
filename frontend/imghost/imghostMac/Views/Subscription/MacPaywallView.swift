import SwiftUI
import StoreKit

struct MacPaywallView: View {
    @StateObject private var storeKit = StoreKitManager.shared
    @EnvironmentObject var subscriptionState: SubscriptionState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedProduct: Product?
    @State private var isYearly = false
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
                        // Tier selector
                        HStack(spacing: 12) {
                            MacTierButton(label: String(localized: "paywall.tier.starter.name"), storage: "10 GB",
                                          product: storeKit.starterMonthlyProduct,
                                          isSelected: selectedProduct?.id == storeKit.starterMonthlyProduct?.id ||
                                                      selectedProduct?.id == storeKit.starterYearlyProduct?.id) {
                                selectedProduct = isYearly ? storeKit.starterYearlyProduct : storeKit.starterMonthlyProduct
                            }
                            MacTierButton(label: String(localized: "paywall.tier.pro.name"), storage: "100 GB",
                                          product: storeKit.proMonthlyProduct,
                                          isSelected: selectedProduct?.id == storeKit.proMonthlyProduct?.id ||
                                                      selectedProduct?.id == storeKit.proYearlyProduct?.id) {
                                selectedProduct = isYearly ? storeKit.proYearlyProduct : storeKit.proMonthlyProduct
                            }
                            MacTierButton(label: String(localized: "paywall.tier.ultimate.name"), storage: "1 TB",
                                          product: storeKit.ultimateMonthlyProduct,
                                          isSelected: selectedProduct?.id == storeKit.ultimateMonthlyProduct?.id ||
                                                      selectedProduct?.id == storeKit.ultimateYearlyProduct?.id) {
                                selectedProduct = isYearly ? storeKit.ultimateYearlyProduct : storeKit.ultimateMonthlyProduct
                            }
                        }
                        .frame(maxWidth: 500)

                        // Billing toggle
                        HStack(spacing: 0) {
                            Button(action: { isYearly = false; updateProductForBilling() }) {
                                Text(String(localized: "paywall.billing.monthly"))
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(!isYearly ? Color.black : Color.brutalTextSecondary)
                                    .padding(.horizontal, 20).padding(.vertical, 8)
                                    .background(!isYearly ? Color.white : Color.brutalSurface)
                                    .overlay(Rectangle().stroke(!isYearly ? Color.white : Color.brutalBorder, lineWidth: 1))
                            }.buttonStyle(.plain)
                            Button(action: { isYearly = true; updateProductForBilling() }) {
                                HStack(spacing: 6) {
                                    Text(String(localized: "paywall.billing.yearly"))
                                    Text(String(localized: "paywall.badge.save"))
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(isYearly ? Color.brutalSuccess : Color.brutalTextTertiary)
                                }
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(isYearly ? Color.black : Color.brutalTextSecondary)
                                .padding(.horizontal, 20).padding(.vertical, 8)
                                .background(isYearly ? Color.white : Color.brutalSurface)
                                .overlay(Rectangle().stroke(isYearly ? Color.white : Color.brutalBorder, lineWidth: 1))
                            }.buttonStyle(.plain)
                        }

                        // Subscribe button
                        Button(action: { Task { await purchase() } }) {
                            HStack {
                                if isPurchasing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                        .scaleEffect(0.7)
                                } else {
                                    Text("paywall.button.subscribe")
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
                selectedProduct = storeKit.starterMonthlyProduct
            }
        }
        .alert(String(localized: "paywall.error.alert.title"), isPresented: $showError) {
            Button(String(localized: "paywall.error.alert.button.ok")) { showError = false }
        } message: {
            Text(verbatim: errorMessage ?? String(localized: "paywall.error.alert.message_fallback"))
        }
    }

    private func updateProductForBilling() {
        guard let current = selectedProduct else { return }
        let tier = StoreKitManager.backendTier(for: current.id)
        selectedProduct = isYearly
            ? storeKit.yearlyProduct(for: tier)
            : storeKit.monthlyProduct(for: tier)
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

// MARK: - Tier Comparison Grid (4 columns: Free | Starter | Pro | Ultimate)

struct MacTierComparisonView: View {
    // (label, free, starter, pro, ultimate)
    private let rows: [(String, String, String, String, String)] = [
        ("paywall.comparison.row.storage",    "1 GB",  "10 GB",   "100 GB",    "1 TB"),
        ("paywall.comparison.row.file_size",  "50 MB", "500 MB",  "500 MB",   "500 MB"),
        ("paywall.comparison.row.link_ttl",   "•",     "•",       "•",         "•"),
        ("paywall.comparison.row.export",     "✕",     "✓",       "✓",         "✓"),
        ("paywall.comparison.row.transforms", "✕",     "✓",       "✓",         "✓"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                colHeader(String(localized: "paywall.comparison.free.label"),    dim: true)
                colHeader(String(localized: "paywall.tier.starter.name"),        dim: false)
                colHeader(String(localized: "paywall.tier.pro.name"),            dim: false)
                colHeader(String(localized: "paywall.tier.ultimate.name"),       dim: false)
            }
            .padding(.bottom, 6)

            Rectangle().fill(Color.white.opacity(0.15)).frame(height: 1)

            ForEach(rows, id: \.0) { row in
                let label = String(localized: String.LocalizationValue(row.0))
                let isLinkRow = (row.2 == "•")
                HStack {
                    Text(label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    cell(row.1)
                    cell(row.2)
                    cell(row.3)
                    cell(row.4)
                }
                .padding(.vertical, 7)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
            }
        }
        .frame(maxWidth: 520)
    }

    private func colHeader(_ text: String, dim: Bool) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(dim ? Color.white.opacity(0.35) : Color.white)
            .tracking(1)
            .frame(width: 60, alignment: .center)
    }

    private func cell(_ value: String) -> some View {
        let color: Color = value == "✕" ? Color.white.opacity(0.2)
                         : value == "✓" ? Color.green
                         : Color.brutalTextSecondary
        return Text(value)
            .font(.system(size: 11, weight: value == "✓" ? .bold : .regular, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 60, alignment: .center)
    }
}

// MARK: - MacTierButton

struct MacTierButton: View {
    let label: String
    let storage: String
    let product: Product?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(isSelected ? Color.white : Color.brutalTextSecondary)
                Text(storage)
                    .font(.system(size: 16, weight: .black))
                    .foregroundStyle(isSelected ? Color.white : Color.brutalTextTertiary)
                if let product = product {
                    Text(product.displayPrice + "/mo")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.brutalTextSecondary : Color.brutalTextTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSelected ? Color.brutalSurfaceElevated : Color.brutalSurface)
            .overlay(Rectangle().stroke(isSelected ? Color.white : Color.brutalBorder, lineWidth: isSelected ? 2 : 1))
        }
        .buttonStyle(.plain)
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
