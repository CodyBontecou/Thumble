package expo.modules.tappinglink

import com.android.billingclient.api.*
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import android.os.Handler
import android.os.Looper

class TappingPurchasesModule : Module(), PurchasesUpdatedListener {
  private val productId = "tapping_pro_lifetime"
  private var billing: BillingClient? = null
  private var buying: Promise? = null
  private val main = Handler(Looper.getMainLooper())
  override fun definition() = ModuleDefinition {
    Name("TappingPurchases")
    Events("purchaseChanged")
    AsyncFunction("status") { promise: Promise -> main.post { connect(promise) { snapshot(promise) } } }
    AsyncFunction("restore") { promise: Promise -> main.post { connect(promise) { snapshot(promise) } } }
    AsyncFunction("purchase") { promise: Promise -> main.post {
      if (buying != null) promise.reject("busy", "A purchase is already in progress.", null)
      else connect(promise) {
        val activity = appContext.currentActivity
        if (activity == null) promise.reject("unavailable", "Open Tapping before buying Pro.", null)
        else details(promise) { product ->
          buying = promise
          val item = BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product)
          product.oneTimePurchaseOfferDetailsList?.firstOrNull()?.offerToken?.let { item.setOfferToken(it) }
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
      .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
      .enableAutoServiceReconnection().build()
    billing!!.startConnection(object : BillingClientStateListener {
      override fun onBillingSetupFinished(result: BillingResult) { if (result.responseCode == BillingClient.BillingResponseCode.OK) ready() else fail(promise, result) }
      override fun onBillingServiceDisconnected() { }
    })
  }
  private fun details(promise: Promise, ready: (ProductDetails) -> Unit) {
    val product = QueryProductDetailsParams.Product.newBuilder().setProductId(productId).setProductType(BillingClient.ProductType.INAPP).build()
    billing!!.queryProductDetailsAsync(QueryProductDetailsParams.newBuilder().setProductList(listOf(product)).build()) { result, response ->
      if (result.responseCode != BillingClient.BillingResponseCode.OK) fail(promise, result)
      else response.productDetailsList.firstOrNull()?.let(ready) ?: promise.reject("unavailable", "Pro is not available in this store yet.", null)
    }
  }
  private fun snapshot(promise: Promise) {
    billing!!.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.INAPP).build()) { result, purchases ->
      if (result.responseCode != BillingClient.BillingResponseCode.OK) { fail(promise, result); return@queryPurchasesAsync }
      val purchase = purchases.firstOrNull { productId in it.products && it.purchaseState == Purchase.PurchaseState.PURCHASED }
      val pending = purchases.any { productId in it.products && it.purchaseState == Purchase.PurchaseState.PENDING }
      val value = mutableMapOf<String, Any>("platform" to "android", "status" to if (purchase != null) "owned" else if (pending) "pending" else "free")
      if (purchase != null) { value["proof"] = purchase.purchaseToken; prefs().edit().putString("proof", purchase.purchaseToken).apply() }
      else prefs().getString("proof", null)?.let { value["proof"] = it }
      // The verification endpoint acknowledges only after checking Google purchase state.
      details(promise) { product ->
        val price = product.oneTimePurchaseOfferDetailsList?.firstOrNull()?.formattedPrice
        if (price != null) value["price"] = price
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
