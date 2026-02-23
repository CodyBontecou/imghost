import SwiftUI
import StoreKit

struct MacPaywallView: View {
    @StateObject private var storeKit = StoreKitManager.shared
    @EnvironmentObject var subscriptionState: SubscriptionState
    @State private var selectedProduct: Product?
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        ZStack {
            Color.brutalBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 32) {
                    // Hero
                    VStack(spacing: 12) {
                        Text("UNLOCK")
                            .font(.system(size: 16, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.white)
                            .tracking(4)

                        Text("PRO")
                            .font(.system(size: 64, weight: .black))
                            .foregroundStyle(Color.white)
                            .tracking(8)

                        Text("7-DAY FREE TRIAL")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.brutalSuccess)
                            .tracking(2)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Color.brutalSuccess, lineWidth: 1))
                    }

                    // Features
                    HStack(spacing: 24) {
                        MacFeatureItem(icon: "photo.stack", title: "500MB Files")
                        MacFeatureItem(icon: "externaldrive.fill", title: "10GB Storage")
                        MacFeatureItem(icon: "bolt.fill", title: "Fast Sharing")
                        MacFeatureItem(icon: "lock.fill", title: "Private")
                    }

                    // Products
                    if storeKit.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else if storeKit.products.isEmpty {
                        VStack(spacing: 12) {
                            Text("Unable to load subscription options")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.brutalError)

                            Button(action: { Task { await storeKit.reloadProducts() } }) {
                                Text("RETRY")
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
                                MacProductCard(product: annual, isSelected: selectedProduct?.id == annual.id, badge: "SAVE 30%") {
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
                                    Text("START FREE TRIAL")
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
                            Text("RESTORE PURCHASES")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.brutalTextSecondary)
                                .tracking(1)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRestoring)
                    }

                    // Legal
                    VStack(spacing: 8) {
                        Text("After your 7-day free trial, your subscription will automatically renew. Cancel anytime in Settings.")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.brutalTextTertiary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)

                        HStack(spacing: 12) {
                            Button(action: { MacURLOpener.open("https://imghost.isolated.tech/terms") }) {
                                Text("Terms")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.brutalTextSecondary)
                            }
                            .buttonStyle(.plain)

                            Text("|")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.brutalTextTertiary)

                            Button(action: { MacURLOpener.open("https://imghost.isolated.tech/privacy") }) {
                                Text("Privacy")
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
        .alert("Error", isPresented: $showError) {
            Button("OK") { showError = false }
        } message: {
            Text(errorMessage ?? "An error occurred")
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
                    Text("\(monthlyPrice.formatted(.currency(code: product.priceFormatStyle.currencyCode ?? "USD")))/mo")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.brutalTextSecondary)
                } else {
                    Text("/month")
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
