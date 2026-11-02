import Foundation
import Combine
import StoreKit

struct AccountProfile: Decodable {
    let userId: String
    let storeLinked: Bool
    let pro: Bool
    let expiresAt: Double?
    let verificationEnabled: Bool
    let purchaseEnabled: Bool
    let productIds: [String]
    let privacyURL: String?
    let termsURL: String?
}

@MainActor final class CommerceStore: ObservableObject {
    @Published var profile: AccountProfile?
    @Published var products: [Product] = []
    @Published var busy = false
    @Published var notice: String?
    private let api: NosceAPI
    private var updates: Task<Void, Never>?
    private var started = false
    private var refreshTask: Task<Void,Never>?
    init(api: NosceAPI) { self.api = api }
    func start() async {
        if !started {
            started = true
            updates = Task { [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard let self, !Task.isCancelled else { return }
                    do { try await self.deliver(result) }
                    catch { self.notice = tr("购买验证尚未完成，请稍后点击恢复购买。", "Purchase verification is pending. Please restore purchases later.") }
                }
            }
        }
        await refresh()
        if profile?.storeLinked == true { await synchronize() }
    }
    func refresh() async {
        if let refreshTask { await refreshTask.value; return }
        let task=Task { @MainActor in
            do {
                self.profile = try await self.api.profile()
                if self.profile?.verificationEnabled == true { try await self.linkStore() }
                if let profile=self.profile, profile.purchaseEnabled, profile.storeLinked {
                    self.products = try await Product.products(for:profile.productIds).filter { $0.type == .autoRenewable }
                } else { self.products = [] }
            } catch { self.products = [] }
        }
        refreshTask=task
        await task.value
        refreshTask=nil
    }
    private func linkStore() async throws {
        let result = try await AppTransaction.shared
        guard case .verified = result else { throw ServiceError.unavailable(422) }
        // StoreKit verifies this device's App Store identity. No separate app login.
        profile = try await api.linkAppStore(result.jwsRepresentation)
    }
    func purchase(_ product: Product) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        await refresh()
        guard let profile, profile.storeLinked, profile.purchaseEnabled,
              profile.productIds.contains(product.id), products.contains(where: { $0.id == product.id }),
              let token = UUID(uuidString:profile.userId) else {
            notice = tr("购买服务暂不可用，请稍后重试。", "Purchases are temporarily unavailable. Please try again later.")
            return
        }
        do {
            switch try await product.purchase(options:[.appAccountToken(token)]) {
            case .success(let result): try await deliver(result)
            case .pending: notice = tr("购买等待批准，批准后将自动更新。", "Purchase is awaiting approval. Access updates after approval.")
            case .userCancelled: break
            @unknown default: notice = tr("购买状态待确认。", "Purchase status is pending.")
            }
        } catch { notice = error.localizedDescription }
    }
    private func deliver(_ result: VerificationResult<StoreKit.Transaction>) async throws {
        guard case .verified(let transaction) = result else { throw ServiceError.unavailable(422) }
        if profile?.storeLinked != true { await refresh() }
        guard let profile, profile.storeLinked else { throw ServiceError.credentials }
        guard profile.productIds.contains(transaction.productID) else { return }
        // Never finish before the server verifies and records the transaction.
        self.profile = try await api.submitPurchase(result.jwsRepresentation)
        await transaction.finish()
    }
    func synchronize() async {
        guard profile?.storeLinked == true else { return }
        do {
            for await result in StoreKit.Transaction.currentEntitlements { try await deliver(result) }
            for await result in StoreKit.Transaction.unfinished { try await deliver(result) }
            await refresh()
        } catch { notice = error.localizedDescription }
    }
    func restore() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            notice = nil
            await refresh()
            guard profile?.verificationEnabled == true else {
                notice = tr("购买服务暂不可用，请稍后重试。", "Purchases are temporarily unavailable. Please try again later.")
                return
            }
            try await AppStore.sync()
            try await linkStore()
            await synchronize()
            if notice == nil { notice = profile?.pro == true ? tr("购买已恢复。", "Purchases restored.") : tr("没有可恢复的有效购买。", "No active purchases to restore.") }
        }
        catch { notice = error.localizedDescription }
    }
    func clearLocalProfile() { profile = nil; products = []; notice = nil }
}
