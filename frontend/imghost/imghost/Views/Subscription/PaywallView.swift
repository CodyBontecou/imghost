import SwiftUI
import StoreKit

// MARK: - Tier model

private enum PaidTier: String, CaseIterable, Identifiable {
    case starter  = "pro"         // backend name
    case pro      = "enterprise"  // backend name
    case ultimate = "ultimate"    // backend name

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .starter:  return String(localized: "paywall.tier.starter.name")
        case .pro:      return String(localized: "paywall.tier.pro.name")
        case .ultimate: return String(localized: "paywall.tier.ultimate.name")
        }
    }

    var storageLabel: String {
        switch self {
        case .starter:  return "10 GB"
        case .pro:      return "100 GB"
        case .ultimate: return "1 TB"
        }
    }

    /// Approximate monthly price label shown before StoreKit loads
    var monthlyPriceHint: String {
        switch self {
        case .starter:  return "$2"
        case .pro:      return "$7.50"
        case .ultimate: return "$25"
        }
    }

    var accentColor: Color {
        switch self {
        case .starter:  return .brutalAccent
        case .pro:      return .brutalSuccess
        case .ultimate: return Color.orange
        }
    }
}

// MARK: - PaywallView

struct PaywallView: View {
    @StateObject private var storeKit = StoreKitManager.shared
    @EnvironmentObject var subscriptionState: SubscriptionState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTier: PaidTier = .starter
    @State private var isYearly = false
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?
    @State private var showError = false

    var allowDismiss: Bool = false

    // MARK: - Selected StoreKit product

    private var selectedProduct: Product? {
        isYearly
            ? storeKit.yearlyProduct(for: selectedTier.rawValue)
            : storeKit.monthlyProduct(for: selectedTier.rawValue)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroSection
                tierPickerSection
                billingToggleSection
                comparisonTableSection
                ctaSection
                legalSection
            }
        }
        .background(Color.brutalBackground)
        .task {
            if storeKit.products.isEmpty {
                await storeKit.reloadProducts()
            }
        }
        .alert(String(localized: "paywall.error.alert.title"), isPresented: $showError) {
            Button(String(localized: "paywall.error.alert.button.ok")) { showError = false }
        } message: {
            Text(verbatim: errorMessage ?? String(localized: "paywall.error.alert.message_fallback"))
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        VStack(spacing: 12) {
            Text("paywall.title.unlock")
                .brutalTypography(.displaySmall)
                .tracking(4)

            Text("paywall.title.pro")
                .brutalTypography(.displayLarge)
                .tracking(8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }

    // MARK: - Tier picker

    private var tierPickerSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("paywall.section.plans")
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                    .tracking(2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.brutalSurface)
            .overlay(Rectangle().frame(height: 1).foregroundColor(.brutalBorder), alignment: .bottom)

            HStack(spacing: 10) {
                ForEach(PaidTier.allCases) { tier in
                    TierCard(
                        tier: tier,
                        isSelected: selectedTier == tier,
                        product: storeKit.monthlyProduct(for: tier.rawValue)
                    ) {
                        selectedTier = tier
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Billing toggle

    private var billingToggleSection: some View {
        HStack(spacing: 0) {
            billingButton(title: String(localized: "paywall.billing.monthly"), isActive: !isYearly) {
                isYearly = false
            }
            billingButton(title: String(localized: "paywall.billing.yearly"), badge: String(localized: "paywall.badge.save"), isActive: isYearly) {
                isYearly = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func billingButton(title: String, badge: String? = nil, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .brutalTypography(.mono, color: isActive ? .black : .brutalTextSecondary)
                if let badge = badge {
                    Text(badge)
                        .brutalTypography(.monoSmall, color: isActive ? Color.brutalSuccess : .brutalTextTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(isActive ? Color.white : Color.brutalSurface)
            .overlay(Rectangle().stroke(isActive ? Color.white : Color.brutalBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Comparison table

    private var comparisonTableSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("paywall.section.comparison")
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                    .tracking(2)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.brutalSurface)
            .overlay(Rectangle().frame(height: 1).foregroundColor(.brutalBorder), alignment: .bottom)

            // Column headers
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("paywall.comparison.free.label")
                    .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                    .tracking(1)
                    .frame(width: 68, alignment: .center)
                Text(selectedTier.displayName.uppercased())
                    .brutalTypography(.mono, color: selectedTier.accentColor)
                    .tracking(1)
                    .frame(width: 68, alignment: .center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.brutalBackground)
            .overlay(Rectangle().frame(height: 1).foregroundColor(.brutalBorder), alignment: .bottom)

            // Rows
            comparisonRow("paywall.comparison.row.storage",    free: "1 GB",       paid: selectedTier.storageLabel)
            comparisonRow("paywall.comparison.row.file_size",  free: "50 MB",      paid: "500 MB")
            comparisonRow("paywall.comparison.row.link_ttl",   free: "paywall.comparison.free.link_ttl", paid: "paywall.comparison.pro.link_ttl", localizeValues: true)
            comparisonRow("paywall.comparison.row.export",     free: "✕",          paid: "✓")
            comparisonRow("paywall.comparison.row.transforms", free: "✕",          paid: "✓")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func comparisonRow(_ labelKey: String, free: String, paid: String, localizeValues: Bool = false) -> some View {
        let freeText  = localizeValues ? String(localized: String.LocalizationValue(free))  : free
        let paidText  = localizeValues ? String(localized: String.LocalizationValue(paid))  : paid
        let labelText = String(localized: String.LocalizationValue(labelKey))
        return HStack {
            Text(labelText)
                .brutalTypography(.bodySmall, color: .brutalTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(freeText)
                .brutalTypography(.monoSmall, color: freeText == "✕" ? .brutalTextTertiary : .brutalTextSecondary)
                .frame(width: 68, alignment: .center)
            Text(paidText)
                .brutalTypography(.mono, color: paidText == "✓" ? selectedTier.accentColor : .white)
                .frame(width: 68, alignment: .center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.brutalBackground)
        .overlay(Rectangle().frame(height: 1).foregroundColor(.brutalBorder), alignment: .bottom)
    }

    // MARK: - CTA

    private var ctaSection: some View {
        VStack(spacing: 12) {
            if storeKit.isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .padding(.vertical, 20)
            } else {
                // Price summary
                if let product = selectedProduct {
                    VStack(spacing: 2) {
                        Text(product.displayPrice)
                            .brutalTypography(.titleMedium)
                        Text(isYearly
                             ? String(format: String(localized: "paywall.price.per_month_format"),
                                      (product.price / 12).formatted(.currency(code: product.priceFormatStyle.currencyCode ?? "USD")))
                             : String(localized: "paywall.price.per_month_fallback"))
                            .brutalTypography(.monoSmall, color: .brutalTextSecondary)
                    }
                }

                BrutalPrimaryButton(
                    title: String(localized: "paywall.button.subscribe"),
                    action: { Task { await purchase() } },
                    isLoading: isPurchasing,
                    isDisabled: selectedProduct == nil
                )

                BrutalTextButton(title: String(localized: "paywall.button.restore")) {
                    Task { await restore() }
                }
                .opacity(isRestoring ? 0.5 : 1)

                if allowDismiss || subscriptionState.isFree {
                    BrutalTextButton(title: String(localized: "paywall.button.continue_free")) {
                        dismiss()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
    }

    // MARK: - Legal

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

// MARK: - TierCard

private struct TierCard: View {
    let tier: PaidTier
    let isSelected: Bool
    let product: Product?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(tier.displayName)
                    .brutalTypography(.mono, color: isSelected ? tier.accentColor : .brutalTextSecondary)
                    .tracking(1)

                Text(tier.storageLabel)
                    .brutalTypography(.titleMedium, color: isSelected ? .white : .brutalTextTertiary)

                if let product = product {
                    Text(product.displayPrice + String(localized: "paywall.price.per_month_fallback"))
                        .brutalTypography(.monoSmall, color: isSelected ? .brutalTextSecondary : .brutalTextTertiary)
                } else {
                    Text(tier.monthlyPriceHint + "/mo")
                        .brutalTypography(.monoSmall, color: .brutalTextTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isSelected ? Color.brutalSurfaceElevated : Color.brutalSurface)
            .overlay(
                Rectangle()
                    .stroke(isSelected ? tier.accentColor : Color.brutalBorder, lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    PaywallView()
        .environmentObject(SubscriptionState.shared)
}
