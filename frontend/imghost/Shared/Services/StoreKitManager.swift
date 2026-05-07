import Foundation
import StoreKit

/// Manages StoreKit 2 subscriptions for the app
@MainActor
final class StoreKitManager: ObservableObject {
    static let shared = StoreKitManager()

    // Product IDs configured in App Store Connect
    // Starter — 10 GB @ $2/mo (legacy IDs kept for existing subscribers)
    static let starterMonthlyID = "imghost.pro.monthly"
    static let starterYearlyID  = "imghost.pro.yearly"
    // Pro — 100 GB @ $7.50/mo
    static let proMonthlyID     = "imghost.enterprise.monthly"
    static let proYearlyID      = "imghost.enterprise.yearly"
    // Ultimate — 1 TB @ $25/mo
    static let ultimateMonthlyID = "imghost.ultimate.monthly"
    static let ultimateYearlyID  = "imghost.ultimate.yearly"

    // Legacy aliases kept so PaywallView's `monthlyProduct` / `annualProduct` still compile
    static let monthlyProductID = starterMonthlyID
    static let annualProductID  = starterYearlyID

    #if os(macOS)
    // The current macOS App Store submission only references the submitted Starter products.
    // Higher tiers stay available to iOS builds until their macOS IAPs are submitted for review.
    static let allProductIDs: Set<String> = [starterMonthlyID, starterYearlyID]
    #else
    static let allProductIDs: Set<String> = [
        starterMonthlyID, starterYearlyID,
        proMonthlyID, proYearlyID,
        ultimateMonthlyID, ultimateYearlyID,
    ]
    #endif

    @Published private(set) var products: [Product] = []
    @Published private(set) var purchasedProductIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var error: Error?

    private var updateListenerTask: Task<Void, Error>?

    private init() {}

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Public Methods

    /// Load products from App Store with automatic retry
    func loadProducts() async {
        // Skip if we already have products loaded
        guard products.isEmpty else { return }

        isLoading = true
        error = nil

        let maxRetries = 3

        for attempt in 1...maxRetries {
            do {
                let storeProducts = try await Product.products(for: Self.allProductIDs)

                if storeProducts.isEmpty && attempt < maxRetries {
                    // Products returned empty — retry after a delay
                    print("StoreKit returned 0 products (attempt \(attempt)/\(maxRetries)), retrying...")
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000) // 2s, 4s backoff
                    continue
                }

                // Sort products by price (monthly first, then annual)
                products = storeProducts.sorted { product1, product2 in
                    if product1.id == Self.monthlyProductID {
                        return true
                    }
                    if product2.id == Self.monthlyProductID {
                        return false
                    }
                    return product1.price < product2.price
                }

                if !storeProducts.isEmpty {
                    self.error = nil
                }

                isLoading = false
                return
            } catch {
                print("Failed to load products (attempt \(attempt)/\(maxRetries)): \(error)")

                if attempt < maxRetries {
                    try? await Task.sleep(nanoseconds: UInt64(attempt) * 2_000_000_000)
                    continue
                }

                self.error = error
                isLoading = false
            }
        }
    }

    /// Force reload products (ignores cache, used by retry button)
    func reloadProducts() async {
        products = []
        await loadProducts()
    }

    /// Purchase a subscription product
    func purchase(_ product: Product) async throws -> Transaction? {
        isLoading = true
        error = nil

        do {
            let result = try await product.purchase()

            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)

                // Verify with backend using JWS representation
                let jwsRepresentation = verification.jwsRepresentation
                try await verifyWithBackend(jwsRepresentation: jwsRepresentation, transaction: transaction)

                // Finish the transaction
                await transaction.finish()

                // Update purchased IDs
                await updatePurchasedProducts()

                isLoading = false
                return transaction

            case .userCancelled:
                isLoading = false
                return nil

            case .pending:
                isLoading = false
                return nil

            @unknown default:
                isLoading = false
                return nil
            }
        } catch {
            self.error = error
            isLoading = false
            throw error
        }
    }

    /// Restore purchases from App Store
    func restorePurchases() async throws {
        isLoading = true
        error = nil

        do {
            // Sync with App Store
            try await AppStore.sync()

            // Update purchased products
            await updatePurchasedProducts()

            // Get all transactions and verify with backend
            var transactions: [String] = []
            for await result in Transaction.currentEntitlements {
                if (try? checkVerified(result)) != nil {
                    let jwsRepresentation = result.jwsRepresentation
                    transactions.append(jwsRepresentation)
                }
            }

            // Restore with backend if we have transactions
            if !transactions.isEmpty {
                try await SubscriptionService.shared.restorePurchases(transactions: transactions)
            }

            isLoading = false
        } catch {
            self.error = error
            isLoading = false
            throw error
        }
    }

    /// Check current entitlements
    func checkEntitlements() async {
        await updatePurchasedProducts()
    }

    /// Start listening for transaction updates
    func startListening() {
        guard updateListenerTask == nil else { return }
        updateListenerTask = listenForTransactions()
    }

    /// Start listening for transaction updates (returns task for manual management)
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached { [weak self] in
            for await result in Transaction.updates {
                await self?.handleTransactionUpdate(result)
            }
        }
    }

    // MARK: - Private Methods

    private func updatePurchasedProducts() async {
        var purchased: Set<String> = []

        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                purchased.insert(transaction.productID)
            }
        }

        purchasedProductIDs = purchased
    }

    private func handleTransactionUpdate(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result) else { return }

        // Verify with backend using JWS representation
        let jwsRepresentation = result.jwsRepresentation
        do {
            try await verifyWithBackend(jwsRepresentation: jwsRepresentation, transaction: transaction)
        } catch {
            print("Failed to verify transaction with backend: \(error)")
        }

        await transaction.finish()
        await updatePurchasedProducts()

        // Update subscription state
        await SubscriptionState.shared.checkStatus()
    }

    private func checkVerified(_ result: VerificationResult<Transaction>) throws -> Transaction {
        switch result {
        case .unverified(_, let error):
            throw StoreKitError.verificationFailed(error)
        case .verified(let transaction):
            return transaction
        }
    }

    /// Verify transaction with backend using the JWS representation
    private func verifyWithBackend(jwsRepresentation: String, transaction: Transaction) async throws {
        try await SubscriptionService.shared.verifyPurchase(
            signedTransaction: jwsRepresentation,
            productId: transaction.productID,
            originalTransactionId: String(transaction.originalID),
            expiresDate: transaction.expirationDate
        )
    }

    // MARK: - Helper Properties

    // MARK: - Per-tier product accessors

    /// Starter products (10 GB)
    var starterMonthlyProduct: Product? { products.first { $0.id == Self.starterMonthlyID } }
    var starterYearlyProduct:  Product? { products.first { $0.id == Self.starterYearlyID  } }

    /// Pro products (100 GB)
    var proMonthlyProduct: Product? { products.first { $0.id == Self.proMonthlyID } }
    var proYearlyProduct:  Product? { products.first { $0.id == Self.proYearlyID  } }

    /// Ultimate products (1 TB)
    var ultimateMonthlyProduct: Product? { products.first { $0.id == Self.ultimateMonthlyID } }
    var ultimateYearlyProduct:  Product? { products.first { $0.id == Self.ultimateYearlyID  } }

    /// Legacy aliases (used by old PaywallView code; resolve to Starter)
    var monthlyProduct: Product? { starterMonthlyProduct }
    var annualProduct:  Product? { starterYearlyProduct  }

    /// Returns the monthly product for the given tier string (as returned by the backend)
    func monthlyProduct(for tier: String) -> Product? {
        switch tier {
        case "pro":        return starterMonthlyProduct
        case "enterprise": return proMonthlyProduct
        case "ultimate":   return ultimateMonthlyProduct
        default:           return starterMonthlyProduct
        }
    }

    /// Returns the yearly product for the given tier string
    func yearlyProduct(for tier: String) -> Product? {
        switch tier {
        case "pro":        return starterYearlyProduct
        case "enterprise": return proYearlyProduct
        case "ultimate":   return ultimateYearlyProduct
        default:           return starterYearlyProduct
        }
    }

    /// Maps a StoreKit product ID to the backend tier name
    static func backendTier(for productID: String) -> String {
        if productID.hasPrefix("imghost.ultimate")   { return "ultimate"   }
        if productID.hasPrefix("imghost.enterprise") { return "enterprise" }
        return "pro" // imghost.pro.* → Starter (internal name "pro")
    }

    /// Check if user has any active subscription
    var hasActiveSubscription: Bool {
        !purchasedProductIDs.isEmpty
    }
}

// MARK: - Errors

enum StoreKitError: LocalizedError {
    case verificationFailed(Error)
    case noJWSRepresentation
    case purchaseFailed

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let error):
            return "Transaction verification failed: \(error.localizedDescription)"
        case .noJWSRepresentation:
            return "Could not get transaction data"
        case .purchaseFailed:
            return "Purchase failed"
        }
    }
}
