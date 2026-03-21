import SwiftUI
import StoreKit

struct PaywallView: View {
    @StateObject private var storeKit = StoreKitManager.shared
    @EnvironmentObject var subscriptionState: SubscriptionState
    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Hero Section
                heroSection

                // Features Section
                featuresSection

                // Pricing Section
                pricingSection

                // Legal Section
                legalSection
            }
        }
        .background(Color.brutalBackground)
        .task {
            if storeKit.products.isEmpty {
                await storeKit.reloadProducts()
            }
            // Default select monthly
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

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 16) {
            Text("paywall.title.unlock")
                .brutalTypography(.displaySmall)
                .tracking(4)

            Text("paywall.title.pro")
                .brutalTypography(.displayLarge)
                .tracking(8)

            Text("paywall.title.trial")
                .brutalTypography(.mono, color: .brutalSuccess)
                .tracking(2)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Rectangle()
                        .stroke(Color.brutalSuccess, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .padding(.horizontal, 24)
    }

    // MARK: - Features Section

    private var featuresSection: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("paywall.section.features")
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                    .tracking(2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.brutalSurface)
            .overlay(
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.brutalBorder),
                alignment: .bottom
            )

            // Feature List
            VStack(spacing: 0) {
                FeatureRow(icon: "photo.stack", title: String(localized: "paywall.feature.file_size.title"), description: String(localized: "paywall.feature.file_size.desc"))
                FeatureRow(icon: "externaldrive.fill", title: String(localized: "paywall.feature.storage.title"), description: String(localized: "paywall.feature.storage.desc"))
                FeatureRow(icon: "bolt.fill", title: String(localized: "paywall.feature.sharing.title"), description: String(localized: "paywall.feature.sharing.desc"))
                FeatureRow(icon: "lock.fill", title: String(localized: "paywall.feature.private.title"), description: String(localized: "paywall.feature.private.desc"))
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Pricing Section

    private var pricingSection: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("paywall.section.plans")
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                    .tracking(2)
                Spacer()
            }
            .padding(.top, 32)

            if storeKit.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .padding(.vertical, 32)
            } else if storeKit.products.isEmpty {
                VStack(spacing: 16) {
                    Text("paywall.error.loading")
                        .brutalTypography(.bodyMedium, color: .brutalError)

                    if let error = storeKit.error {
                        Text(error.localizedDescription)
                            .brutalTypography(.bodySmall, color: .brutalTextSecondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task {
                            await storeKit.reloadProducts()
                            if selectedProduct == nil {
                                selectedProduct = storeKit.monthlyProduct
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.clockwise")
                            Text("paywall.button.retry")
                        }
                        .brutalTypography(.mono, color: .brutalAccent)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(
                            Rectangle()
                                .stroke(Color.brutalAccent, lineWidth: 1)
                        )
                    }
                }
                .padding(.vertical, 32)
            } else {
                // Product Options
                VStack(spacing: 12) {
                    if let monthly = storeKit.monthlyProduct {
                        ProductCard(
                            product: monthly,
                            isSelected: selectedProduct?.id == monthly.id,
                            badge: nil
                        ) {
                            selectedProduct = monthly
                        }
                    }

                    if let annual = storeKit.annualProduct {
                        ProductCard(
                            product: annual,
                            isSelected: selectedProduct?.id == annual.id,
                            badge: String(localized: "paywall.badge.save")
                        ) {
                            selectedProduct = annual
                        }
                    }
                }

                // Subscribe Button
                BrutalPrimaryButton(
                    title: String(localized: "paywall.button.start_trial"),
                    action: {
                        Task {
                            await purchase()
                        }
                    },
                    isLoading: isPurchasing,
                    isDisabled: selectedProduct == nil
                )
                .padding(.top, 8)

                // Restore Purchases
                BrutalTextButton(title: String(localized: "paywall.button.restore")) {
                    Task {
                        await restore()
                    }
                }
                .padding(.top, 8)
                .opacity(isRestoring ? 0.5 : 1)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Legal Section

    private var legalSection: some View {
        VStack(spacing: 12) {
            Text("paywall.legal.renewal_notice")
                .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link(String(localized: "paywall.legal.button.terms"), destination: URL(string: "https://imghost.isolated.tech/terms")!)
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)

                Text("paywall.legal.separator")
                    .brutalTypography(.monoSmall, color: .brutalTextTertiary)

                Link(String(localized: "paywall.legal.button.privacy"), destination: URL(string: "https://imghost.isolated.tech/privacy")!)
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    // MARK: - Actions

    private func purchase() async {
        guard let product = selectedProduct else { return }

        isPurchasing = true
        errorMessage = nil

        do {
            _ = try await storeKit.purchase(product)
            // Check subscription status after purchase
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

// MARK: - Feature Row

private struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.brutalAccent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .brutalTypography(.bodyLarge)
                Text(description)
                    .brutalTypography(.bodySmall, color: .brutalTextSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.brutalBackground)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.brutalBorder),
            alignment: .bottom
        )
    }
}

// MARK: - Product Card

private struct ProductCard: View {
    let product: Product
    let isSelected: Bool
    let badge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Selection indicator
                Circle()
                    .stroke(isSelected ? Color.white : Color.brutalBorder, lineWidth: 2)
                    .frame(width: 24, height: 24)
                    .overlay(
                        Circle()
                            .fill(isSelected ? Color.white : Color.clear)
                            .frame(width: 12, height: 12)
                    )

                // Product info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(product.displayName)
                            .brutalTypography(.titleSmall)

                        if let badge = badge {
                            Text(badge)
                                .brutalTypography(.monoSmall, color: .brutalSuccess)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Rectangle()
                                        .stroke(Color.brutalSuccess, lineWidth: 1)
                                )
                        }
                    }

                    Text(product.description)
                        .brutalTypography(.bodySmall, color: .brutalTextSecondary)
                        .lineLimit(1)
                }

                Spacer()

                // Price
                VStack(alignment: .trailing, spacing: 0) {
                    Text(product.displayPrice)
                        .brutalTypography(.titleMedium)
                    Text(pricePerMonth(product))
                        .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                }
            }
            .padding(16)
            .background(isSelected ? Color.brutalSurfaceElevated : Color.brutalSurface)
            .overlay(
                Rectangle()
                    .stroke(isSelected ? Color.white : Color.brutalBorder, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func pricePerMonth(_ product: Product) -> String {
        if product.id == StoreKitManager.annualProductID {
            let monthlyPrice = product.price / 12
            return String(format: String(localized: "paywall.price.per_month_format"), monthlyPrice.formatted(.currency(code: product.priceFormatStyle.currencyCode ?? "USD")))
        }
        return String(localized: "paywall.price.per_month_fallback")
    }
}

#Preview {
    PaywallView()
        .environmentObject(SubscriptionState.shared)
}
