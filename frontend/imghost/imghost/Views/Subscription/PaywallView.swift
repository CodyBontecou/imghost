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
            await storeKit.loadProducts()
            // Default select monthly
            if selectedProduct == nil {
                selectedProduct = storeKit.monthlyProduct
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage ?? "An error occurred")
        }
    }

    // MARK: - Hero Section

    private var heroSection: some View {
        VStack(spacing: 16) {
            Text("UNLOCK")
                .brutalTypography(.displaySmall)
                .tracking(4)

            Text("PRO")
                .brutalTypography(.displayLarge)
                .tracking(8)

            Text("7-DAY FREE TRIAL")
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
                Text("WHAT YOU GET")
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
                FeatureRow(icon: "photo.stack", title: "500MB File Size", description: "Upload large files, videos, and more")
                FeatureRow(icon: "externaldrive.fill", title: "10GB Storage", description: "Pro storage limit during trial")
                FeatureRow(icon: "bolt.fill", title: "Fast Sharing", description: "Instant links for your images")
                FeatureRow(icon: "lock.fill", title: "Private by Default", description: "Secure, encrypted storage")
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Pricing Section

    private var pricingSection: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Text("CHOOSE YOUR PLAN")
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
                Text("Unable to load subscription options")
                    .brutalTypography(.bodyMedium, color: .brutalError)
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
                            badge: "SAVE 30%"
                        ) {
                            selectedProduct = annual
                        }
                    }
                }

                // Subscribe Button
                BrutalPrimaryButton(
                    title: "Start Free Trial",
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
                BrutalTextButton(title: "Restore Purchases") {
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
            Text("After your 7-day free trial, your subscription will automatically renew at the selected price unless cancelled at least 24 hours before the end of the trial period. Payment will be charged to your Apple ID account at confirmation of purchase. Your subscription automatically renews unless auto-renew is turned off at least 24 hours before the end of the current period. You can manage and cancel your subscriptions by going to your App Store account settings after purchase.")
                .brutalTypography(.bodySmall, color: .brutalTextTertiary)
                .multilineTextAlignment(.center)

            HStack(spacing: 16) {
                Link("Terms of Use (EULA)", destination: URL(string: "https://imghost.isolated.tech/terms")!)
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)

                Text("|")
                    .brutalTypography(.monoSmall, color: .brutalTextTertiary)

                Link("Privacy Policy", destination: URL(string: "https://imghost.isolated.tech/privacy")!)
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
            return "\(monthlyPrice.formatted(.currency(code: product.priceFormatStyle.currencyCode ?? "USD")))/mo"
        }
        return "/month"
    }
}

#Preview {
    PaywallView()
        .environmentObject(SubscriptionState.shared)
}
