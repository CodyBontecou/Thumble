import ExpoModulesCore
import StoreKit
import Security

// StoreKit owns the payment UI and verification. No purchase secrets enter JS logs.
public final class TappingPurchasesModule: Module {
    private let productID = "tapping_pro_lifetime"
    private var updates: Task<Void, Never>?
    private var buying = false
    public func definition() -> ModuleDefinition {
        Name("TappingPurchases")
        Events("purchaseChanged")
        OnCreate {
            self.updates = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard let self, !Task.isCancelled else { return }
                    if case .verified(let transaction) = result, transaction.productID == self.productID {
                        await transaction.finish()
                        self.sendEvent("purchaseChanged", [:])
                    }
                }
            }
        }
        OnDestroy { self.updates?.cancel() }
        AsyncFunction("status") { () async throws -> [String: Any] in try await self.snapshot() }
        AsyncFunction("restore") { () async throws -> [String: Any] in
            try await AppStore.sync()
            return try await self.snapshot()
        }
        AsyncFunction("purchase") { () async throws -> [String: Any] in
            guard !self.buying else { throw PurchaseError.message("A purchase is already in progress.") }
            self.buying = true; defer { self.buying = false }
            guard let product = try await Product.products(for: [self.productID]).first,
                  product.type == .nonConsumable else { throw PurchaseError.message("Pro is not available in this store yet.") }
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
    private func snapshot() async throws -> [String: Any] {
        var result: [String: Any] = ["platform": "ios", "status": "free"]
        for await entry in StoreKit.Transaction.currentEntitlements {
            if case .verified(let transaction) = entry, transaction.productID == productID,
               transaction.revocationDate == nil, !transaction.isUpgraded {
                result["status"] = "owned"; result["proof"] = entry.jwsRepresentation
                UserDefaults.standard.set(entry.jwsRepresentation, forKey: "tapping.lastPurchaseProof")
            }
        }
        if result["proof"] == nil, let previous = UserDefaults.standard.string(forKey: "tapping.lastPurchaseProof") { result["proof"] = previous }
        if let products = try? await Product.products(for: [productID]), let product = products.first { result["price"] = product.displayPrice }
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
