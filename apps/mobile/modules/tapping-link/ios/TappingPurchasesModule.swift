import ExpoModulesCore
import StoreKit
import Security

// StoreKit owns the payment UI and verification. No purchase secrets enter JS logs.
public final class TappingPurchasesModule: Module {
    // Lifetime keeps the original product ID so earlier purchases still unlock.
    private let lifetimeIDs: Set<String> = ["thumble_pro_lifetime", "thumble_family_lifetime"]
    private let subscriptionIDs: Set<String> = ["thumble_weekly", "thumble_yearly", "thumble_family_weekly", "thumble_family_yearly"]
    private var productIDs: Set<String> { lifetimeIDs.union(subscriptionIDs) }
    private var updates: Task<Void, Never>?
    private var buying = false
    public func definition() -> ModuleDefinition {
        Name("TappingPurchases")
        Events("purchaseChanged")
        OnCreate {
            self.updates = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard let self, !Task.isCancelled else { return }
                    if case .verified(let transaction) = result, self.productIDs.contains(transaction.productID) {
                        await transaction.finish()
                        self.sendEvent("purchaseChanged", [:])
                    }
                }
            }
        }
        OnDestroy { self.updates?.cancel() }
        AsyncFunction("status") { () async throws -> [String: Any] in try await self.snapshot() }
        AsyncFunction("catalog") { (ids: [String]) async throws -> [[String: Any]] in
            let wanted = Set(ids).intersection(self.productIDs)
            var items: [[String: Any]] = []
            for product in try await Product.products(for: wanted) {
                var item: [String: Any] = ["id": product.id, "price": product.displayPrice, "amount": NSDecimalNumber(decimal: product.price).doubleValue,
                                           "currency": product.priceFormatStyle.currencyCode, "family": product.isFamilyShareable,
                                           "kind": product.type == .autoRenewable ? "subscription" : "lifetime"]
                if let subscription = product.subscription {
                    item["period"] = subscription.subscriptionPeriod.unit == .week ? "week" : subscription.subscriptionPeriod.unit == .year ? "year" : "other"
                    if let offer = subscription.introductoryOffer, offer.paymentMode == .freeTrial {
                        item["trialEligible"] = await subscription.isEligibleForIntroOffer
                        item["trialDays"] = offer.period.unit == .week ? offer.period.value * 7 : offer.period.unit == .day ? offer.period.value : 0
                    } else { item["trialEligible"] = false }
                }
                items.append(item)
            }
            return items
        }
        AsyncFunction("restore") { () async throws -> [String: Any] in
            try await AppStore.sync()
            return try await self.snapshot()
        }
        AsyncFunction("purchase") { (id: String) async throws -> [String: Any] in
            guard !self.buying else { throw PurchaseError.message("A purchase is already in progress.") }
            guard self.productIDs.contains(id) else { throw PurchaseError.message("This plan is not available.") }
            self.buying = true; defer { self.buying = false }
            guard let product = try await Product.products(for: [id]).first else { throw PurchaseError.message("This plan is not available in your store yet.") }
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else { throw PurchaseError.message("Apple could not verify this purchase. Try Restore Purchases.") }
                await transaction.finish()
                return try await self.snapshot()
            case .pending: return ["status": "pending", "platform": "ios"]
            case .userCancelled: return ["status": "cancelled", "platform": "ios"]
            @unknown default: throw PurchaseError.message("Purchase status is unavailable. Try Restore Purchases.")
            }
        }
        AsyncFunction("installationId") { () -> String in
            #if targetEnvironment(simulator)
            let id = UserDefaults.standard.string(forKey: "tapping.simulatorIdentity") ?? UUID().uuidString
            UserDefaults.standard.set(id, forKey: "tapping.simulatorIdentity")
            return id
            #else
            var query = self.keyQuery; query[kSecAttrAccount as String] = "installation"
            var read = query; read[kSecReturnData as String] = true
            var result: CFTypeRef?
            let status = SecItemCopyMatching(read as CFDictionary, &result)
            if status == errSecSuccess, let data = result as? Data, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil { return id }
            guard status == errSecItemNotFound else { throw PurchaseError.message("Device identity is unavailable. Unlock your phone and retry.") }
            let id = UUID().uuidString; query[kSecValueData as String] = Data(id.utf8)
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw PurchaseError.message("Device identity could not be saved.") }
            return id
            #endif
        }
        AsyncFunction("onboardingComplete") { () -> Bool in UserDefaults.standard.bool(forKey: "tapping.onboarding.v1") }
        AsyncFunction("completeOnboarding") { UserDefaults.standard.set(true, forKey: "tapping.onboarding.v1") }
        AsyncFunction("getOnboardingProgress") { () -> String in UserDefaults.standard.string(forKey: "tapping.onboarding.v2") ?? "" }
        AsyncFunction("saveOnboardingProgress") { (json: String) in
            guard json.utf8.count <= 8192, let data = json.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else { throw PurchaseError.message("Setup could not be saved.") }
            UserDefaults.standard.set(json, forKey: "tapping.onboarding.v2")
        }
        AsyncFunction("getCalibration") { () -> String in UserDefaults.standard.string(forKey: "tapping.calibration") ?? "" }
        AsyncFunction("saveCalibration") { (json: String) in
            guard json.utf8.count <= 4096 else { throw PurchaseError.message("Invalid calibration.") }
            UserDefaults.standard.set(json, forKey: "tapping.calibration")
        }
        AsyncFunction("demoUsed") { () -> Double in self.readUsed() }
        AsyncFunction("saveDemoUsed") { (used: Double) in
            guard used.isFinite, used >= 0, used <= 1800 else { return }
            try self.writeUsed(max(self.readUsed(), used))
        }
    }
    // Lifetime wins over subscriptions; otherwise the latest-expiring active plan.
    // Without an entitlement, StoreKit's renewal state separates a lapsed plan
    // from a billing problem so the app can show the right recovery.
    private func snapshot() async throws -> [String: Any] {
        var result: [String: Any] = ["platform": "ios", "status": "free"]
        var best: (transaction: StoreKit.Transaction, jws: String)?
        for await entry in StoreKit.Transaction.currentEntitlements {
            guard case .verified(let transaction) = entry, productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            if let expires = transaction.expirationDate, expires <= Date() { continue }
            if let current = best?.transaction, lifetimeIDs.contains(current.productID) { continue }
            if best == nil || lifetimeIDs.contains(transaction.productID) || (transaction.expirationDate ?? .distantPast) > (best!.transaction.expirationDate ?? .distantPast) {
                best = (transaction, entry.jwsRepresentation)
            }
        }
        if let best {
            result["status"] = "active"; result["productId"] = best.transaction.productID; result["proof"] = best.jws
            if let expires = best.transaction.expirationDate { result["expiresAt"] = expires.timeIntervalSince1970 * 1000 }
            result["inTrial"] = best.transaction.offerType == .introductory
            UserDefaults.standard.set(best.jws, forKey: "tapping.lastPurchaseProof")
            UserDefaults.standard.set(best.transaction.productID, forKey: "tapping.lastPurchaseProduct")
        }
        if let products = try? await Product.products(for: subscriptionIDs) {
            var lapsed = false, billing = false
            for product in products {
                for status in (try? await product.subscription?.status) ?? [] {
                    if case .verified(let renewal) = status.renewalInfo, best?.transaction.productID == renewal.currentProductID { result["willRenew"] = renewal.willAutoRenew }
                    if status.state == .inBillingRetryPeriod { billing = true }
                    if status.state == .expired || status.state == .revoked { lapsed = true }
                }
            }
            if best == nil { result["status"] = billing ? "billing" : lapsed ? "expired" : "free" }
        }
        if best == nil, let previous = UserDefaults.standard.string(forKey: "tapping.lastPurchaseProof") {
            result["proof"] = previous
            result["productId"] = UserDefaults.standard.string(forKey: "tapping.lastPurchaseProduct") ?? "thumble_pro_lifetime"
        }
        return result
    }
    private var keyQuery: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "tapping.demo", kSecAttrAccount as String: "used"] }
    private func readUsed() -> Double {
        #if targetEnvironment(simulator)
        return min(1800, max(0, UserDefaults.standard.double(forKey: "tapping.simulatorDemoUsed")))
        #else
        var query = keyQuery; query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return 0 }
        guard status == errSecSuccess, let data = value as? Data,
              let text = String(data: data, encoding: .utf8), let used = Double(text), used.isFinite, (0...1800).contains(used) else { return 1800 }
        return used
        #endif
    }
    private func writeUsed(_ used: Double) throws {
        #if targetEnvironment(simulator)
        UserDefaults.standard.set(used, forKey: "tapping.simulatorDemoUsed")
        #else
        let data = Data(String(used).utf8)
        var status = SecItemUpdate(keyQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = keyQuery; query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw PurchaseError.message("Demo time could not be saved. Retry after unlocking your phone.") }
        #endif
    }
    private enum PurchaseError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
    }
}
