/**
 * subscription_hooks.js — Frida hooks for subscription/IAP state management
 *
 * Features:
 *   - Automated trial/subscription detection
 *   - Dynamic OfferId injection from config
 *   - Purchase flow interception and logging
 *
 * Usage:
 *   frida -U -n <process> -l subscription_hooks.js --no-pause
 *
 * Environment:
 *   Set SUBSCRIPTION_CONFIG_PATH to point to your subscription_plans.json
 */

"use strict";

var TAG = "[Sub-Hooks]";

function logInfo(msg)  { console.log(TAG + " [INFO]  " + msg); }
function logWarn(msg)  { console.log(TAG + " [WARN]  " + msg); }
function logError(msg) { console.log(TAG + " [ERROR] " + msg); }
function logOk(msg)    { console.log(TAG + " [OK]    " + msg); }

// ---------------------------------------------------------------------------
// 1. Subscription State Detection
// ---------------------------------------------------------------------------
Java.perform(function() {
    logInfo("Installing subscription state detection hooks...");

    // Detect active subscriptions via BillingClient.queryPurchasesAsync
    try {
        var BillingClient = Java.use("com.android.billingclient.api.BillingClient");

        // Hook queryPurchasesAsync to inspect current purchase state
        BillingClient.queryPurchasesAsync.overload(
            "com.android.billingclient.api.QueryPurchasesParams",
            "com.android.billingclient.api.PurchasesResponseListener"
        ).implementation = function(params, listener) {
            logInfo("queryPurchasesAsync called — inspecting current subscriptions");

            // Wrap the listener to intercept the result
            var originalListener = listener;
            var WrappedListener = Java.registerClass({
                name: "com.qa.WrappedPurchasesListener",
                implements: [Java.use("com.android.billingclient.api.PurchasesResponseListener")],
                fields: { original: "com.android.billingclient.api.PurchasesResponseListener" },
                methods: {
                    onQueryPurchasesResponse: function(billingResult, purchases) {
                        var code = billingResult.getResponseCode();
                        logInfo("Purchase query result code: " + code);

                        if (purchases !== null) {
                            var size = purchases.size();
                            logInfo("Active purchases found: " + size);
                            for (var i = 0; i < size; i++) {
                                var purchase = purchases.get(i);
                                logInfo("  [" + i + "] Product: " + purchase.getProducts());
                                logInfo("  [" + i + "] State: " + purchase.getPurchaseState());
                                logInfo("  [" + i + "] Token: " + purchase.getPurchaseToken());
                                logInfo("  [" + i + "] AutoRenewing: " + purchase.isAutoRenewing());

                                // Detect trial
                                try {
                                    var orderId = purchase.getOrderId();
                                    if (orderId && orderId.indexOf("..0") !== -1) {
                                        logWarn("  [" + i + "] TRIAL DETECTED (order: " + orderId + ")");
                                        logWarn("  Consider canceling existing trial before new subscription");
                                    }
                                } catch (e) {}
                            }
                        }

                        // Forward to original listener
                        originalListener.onQueryPurchasesResponse(billingResult, purchases);
                    }
                }
            });

            var wrapped = WrappedListener.$new();
            wrapped.original.value = originalListener;
            this.queryPurchasesAsync(params, wrapped);
        };
        logOk("Subscription state detection hooks installed");
    } catch (e) {
        logInfo("BillingClient subscription hooks not applicable: " + e);
    }
});


// ---------------------------------------------------------------------------
// 2. Dynamic OfferId / OfferToken Injection
// ---------------------------------------------------------------------------
Java.perform(function() {
    logInfo("Installing OfferId injection hooks...");

    try {
        var BillingFlowParams = Java.use("com.android.billingclient.api.BillingFlowParams");
        var ProductDetailsParams = Java.use(
            "com.android.billingclient.api.BillingFlowParams$ProductDetailsParams"
        );

        // Hook ProductDetailsParams.Builder.setOfferToken
        var Builder = Java.use(
            "com.android.billingclient.api.BillingFlowParams$ProductDetailsParams$Builder"
        );
        Builder.setOfferToken.implementation = function(token) {
            logInfo("Original offerToken: " + token);

            // Check for override via system property
            try {
                var SystemProperties = Java.use("android.os.SystemProperties");
                var override = SystemProperties.get("qa.offer.token.override", "");
                if (override && override.length > 0) {
                    logWarn("Overriding offerToken with: " + override);
                    return this.setOfferToken(override);
                }
            } catch (e) {}

            logInfo("Using original offerToken (no override set)");
            logInfo("To override, set: adb shell setprop qa.offer.token.override <token>");
            return this.setOfferToken(token);
        };
        logOk("OfferId injection hooks installed");
    } catch (e) {
        logInfo("BillingFlowParams hooks not applicable: " + e);
    }
});


// ---------------------------------------------------------------------------
// 3. Purchase Flow Logging
// ---------------------------------------------------------------------------
Java.perform(function() {
    logInfo("Installing purchase flow logger...");

    try {
        var BillingClient = Java.use("com.android.billingclient.api.BillingClient");

        BillingClient.launchBillingFlow.implementation = function(activity, params) {
            logInfo("=== BILLING FLOW INITIATED ===");
            logInfo("  Activity: " + activity.getClass().getName());

            try {
                var productDetails = params.getProductDetailsParamsList();
                if (productDetails) {
                    for (var i = 0; i < productDetails.size(); i++) {
                        logInfo("  Product[" + i + "]: " + productDetails.get(i));
                    }
                }
            } catch (e) {
                logWarn("  Could not extract product details: " + e);
            }

            var result = this.launchBillingFlow(activity, params);
            logInfo("  BillingResult code: " + result.getResponseCode());
            logInfo("=== BILLING FLOW END ===");
            return result;
        };
        logOk("Purchase flow logger installed");
    } catch (e) {
        logInfo("Purchase flow logger not applicable: " + e);
    }
});


logOk("Subscription hooks fully loaded");
