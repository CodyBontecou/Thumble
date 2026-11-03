package expo.modules.tappinglink

import com.android.billingclient.api.*
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import android.os.Handler
import android.os.Looper

class TappingPurchasesModule : Module(), PurchasesUpdatedListener {
  // Google Play offers no Family plans. Lifetime keeps the original product ID.
  private val lifetimeId = "thumble_pro_lifetime"
  private val subscriptionIds = listOf("thumble_weekly", "thumble_yearly")
  private var billing: BillingClient? = null
  private var buying: Promise? = null
  private val main = Handler(Looper.getMainLooper())
  override fun definition() = ModuleDefinition {
    Name("TappingPurchases")
    Events("purchaseChanged")
    AsyncFunction("status") { promise: Promise -> main.post { connect(promise) { snapshot(promise) } } }
    AsyncFunction("restore") { promise: Promise -> main.post { connect(promise) { snapshot(promise) } } }
    AsyncFunction("catalog") { _: List<String>, promise: Promise -> main.post { connect(promise) { details(promise) { products ->
      promise.resolve(products.map { product ->
        if (product.productType == BillingClient.ProductType.SUBS) {
          val offers = product.subscriptionOfferDetails.orEmpty()
          val trial = offers.firstOrNull { offer -> offer.pricingPhases.pricingPhaseList.any { it.priceAmountMicros == 0L } }
          val paid = (trial ?: offers.firstOrNull())?.pricingPhases?.pricingPhaseList?.lastOrNull { it.priceAmountMicros > 0L }
          val free = trial?.pricingPhases?.pricingPhaseList?.firstOrNull { it.priceAmountMicros == 0L }
          mapOf("id" to product.productId, "kind" to "subscription", "family" to false,
            "price" to (paid?.formattedPrice ?: ""), "amount" to ((paid?.priceAmountMicros ?: 0L) / 1_000_000.0), "currency" to (paid?.priceCurrencyCode ?: "USD"),
            "period" to if (paid?.billingPeriod == "P1W") "week" else if (paid?.billingPeriod == "P1Y") "year" else "other",
            // Play only returns offers this account is eligible for.
            "trialEligible" to (free != null), "trialDays" to if (free?.billingPeriod == "P1W" || free?.billingPeriod == "P7D") 7 else 0)
        } else {
          val offer = product.oneTimePurchaseOfferDetailsList?.firstOrNull()
          mapOf("id" to product.productId, "kind" to "lifetime", "family" to false, "price" to (offer?.formattedPrice ?: ""),
            "amount" to ((offer?.priceAmountMicros ?: 0L) / 1_000_000.0), "currency" to (offer?.priceCurrencyCode ?: "USD"), "trialEligible" to false)
        }
      })
    } } } }
    AsyncFunction("purchase") { id: String, promise: Promise -> main.post {
      if (buying != null) promise.reject("busy", "A purchase is already in progress.", null)
      else if (id != lifetimeId && id !in subscriptionIds) promise.reject("unavailable", "This plan is not available on Google Play.", null)
      else connect(promise) {
        val activity = appContext.currentActivity
        if (activity == null) promise.reject("unavailable", "Open Thumble before choosing a plan.", null)
        else details(promise) { products ->
          val product = products.firstOrNull { it.productId == id }
          if (product == null) { promise.reject("unavailable", "This plan is not available in your store yet.", null); return@details }
          buying = promise
          val item = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product)
          if (product.productType == BillingClient.ProductType.SUBS) {
            val offers = product.subscriptionOfferDetails.orEmpty()
            (offers.firstOrNull { offer -> offer.pricingPhases.pricingPhaseList.any { it.priceAmountMicros == 0L } } ?: offers.firstOrNull())?.offerToken?.let { item.setOfferToken(it) }
          } else product.oneTimePurchaseOfferDetailsList?.firstOrNull()?.offerToken?.let { item.setOfferToken(it) }
          val result = billing!!.launchBillingFlow(activity, BillingFlowParams.newBuilder().setProductDetailsParamsList(listOf(item.build())).build())
          if (result.responseCode != BillingClient.BillingResponseCode.OK) { buying = null; fail(promise, result) }
        }
      }
    } }
    AsyncFunction("installationId") {
      val prefs = prefs()
      prefs.getString("installation", null) ?: java.util.UUID.randomUUID().toString().also { if (!prefs.edit().putString("installation", it).commit()) throw IllegalStateException("Device identity could not be saved.") }
    }
    AsyncFunction("onboardingComplete") { prefs().getBoolean("onboarding.v1", false) }
    AsyncFunction("completeOnboarding") {
      if (!prefs().edit().putBoolean("onboarding.v1", true).commit()) throw IllegalStateException("Setup could not be saved.")
    }
    AsyncFunction("getOnboardingProgress") { prefs().getString("onboarding.v2", "") ?: "" }
    AsyncFunction("saveOnboardingProgress") { json: String ->
      require(json.toByteArray(Charsets.UTF_8).size <= 8192) { "Setup could not be saved." }
      org.json.JSONObject(json)
      if (!prefs().edit().putString("onboarding.v2", json).commit()) throw IllegalStateException("Setup could not be saved.")
    }
    AsyncFunction("getCalibration") { prefs().getString("calibration", "") ?: "" }
    AsyncFunction("saveCalibration") { json: String ->
      require(json.length <= 4096)
      if (!prefs().edit().putString("calibration", json).commit()) throw IllegalStateException("Calibration could not be saved.")
    }
    AsyncFunction("demoUsed") { prefs().getFloat("used", 0f).toDouble().coerceIn(0.0, 1800.0) }
    AsyncFunction("saveDemoUsed") { used: Double ->
      if (used.isFinite() && used in 0.0..1800.0) {
        val prefs = prefs()
        if (!prefs.edit().putFloat("used", maxOf(prefs.getFloat("used", 0f), used.toFloat())).commit()) throw IllegalStateException("Demo time could not be saved.")
      }
    }
    OnDestroy { billing?.endConnection(); buying?.reject("closed", "Billing closed. Restore your purchase next time.", null); buying = null }
  }
  private fun prefs() = appContext.reactContext!!.getSharedPreferences("tapping.demo", android.content.Context.MODE_PRIVATE)
  private fun connect(promise: Promise, ready: () -> Unit) {
    if (billing?.isReady == true) { ready(); return }
    billing?.endConnection()
    billing = BillingClient.newBuilder(appContext.reactContext!!).setListener(this)
      .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().enablePrepaidPlans().build())
      .enableAutoServiceReconnection().build()
    billing!!.startConnection(object : BillingClientStateListener {
      override fun onBillingSetupFinished(result: BillingResult) { if (result.responseCode == BillingClient.BillingResponseCode.OK) ready() else fail(promise, result) }
      override fun onBillingServiceDisconnected() { }
    })
  }
  private fun details(promise: Promise, ready: (List<ProductDetails>) -> Unit) {
    val subs = subscriptionIds.map { QueryProductDetailsParams.Product.newBuilder().setProductId(it).setProductType(BillingClient.ProductType.SUBS).build() }
    val inapp = QueryProductDetailsParams.Product.newBuilder().setProductId(lifetimeId).setProductType(BillingClient.ProductType.INAPP).build()
    billing!!.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(subs).build()) { subResult, subResponse ->
      if (subResult.responseCode != BillingClient.BillingResponseCode.OK) { fail(promise, subResult); return@queryProductDetailsAsync }
      billing!!.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(listOf(inapp)).build()) { result, response ->
        if (result.responseCode != BillingClient.BillingResponseCode.OK) fail(promise, result)
        else ready(subResponse.productDetailsList + response.productDetailsList)
      }
    }
  }
  // Play returns only current subscriptions (including grace periods). A plan
  // that was active before and is now missing has lapsed or is on account hold.
  private fun snapshot(promise: Promise) {
    billing!!.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()) { subResult, subs ->
      if (subResult.responseCode != BillingClient.BillingResponseCode.OK) { fail(promise, subResult); return@queryPurchasesAsync }
      billing!!.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build()) { result, inapp ->
        if (result.responseCode != BillingClient.BillingResponseCode.OK) { fail(promise, result); return@queryPurchasesAsync }
        val owned = (inapp + subs).filter { it.purchaseState == Purchase.PurchaseState.PURCHASED && (lifetimeId in it.products || it.products.any { id -> id in subscriptionIds }) }
        val purchase = owned.firstOrNull { lifetimeId in it.products } ?: owned.firstOrNull()
        val pending = (inapp + subs).any { it.purchaseState == Purchase.PurchaseState.PENDING }
        val prefs = prefs()
        val value = mutableMapOf<String, Any>("platform" to "android", "status" to "free")
        if (purchase != null) {
          val id = purchase.products.first()
          value["status"] = "active"; value["productId"] = id; value["proof"] = purchase.purchaseToken
          if (id != lifetimeId) value["willRenew"] = purchase.isAutoRenewing
          prefs.edit().putString("proof", purchase.purchaseToken).putString("proofProduct", id).putBoolean("entitled", true).apply()
          for (item in owned) if (!item.isAcknowledged) billing!!.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(item.purchaseToken).build()) { }
        } else {
          value["status"] = if (pending) "pending" else if (prefs.getBoolean("entitled", false)) "expired" else "free"
          prefs.getString("proof", null)?.let { value["proof"] = it; value["productId"] = prefs.getString("proofProduct", lifetimeId) ?: lifetimeId }
        }
        promise.resolve(value)
      }
    }
  }
  override fun onPurchasesUpdated(result: BillingResult, purchases: MutableList<Purchase>?) {
    val promise = buying; buying = null
    if (promise != null) {
      when (result.responseCode) {
        BillingClient.BillingResponseCode.OK, BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> snapshot(promise)
        BillingClient.BillingResponseCode.USER_CANCELED -> promise.resolve(mapOf("status" to "cancelled", "platform" to "android"))
        else -> fail(promise, result)
      }
    }
    sendEvent("purchaseChanged", emptyMap<String, Any>())
  }
  private fun fail(promise: Promise, result: BillingResult) { promise.reject("billing_${result.responseCode}", "Google Play could not complete this request. Please retry or restore purchases.", null) }
}
