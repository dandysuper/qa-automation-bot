/*
 * hook_1m.js — Frida instrumentation script for IAP QA testing
 *
 * Purpose:
 *   1. Mock environment / security checks so the staging build runs in the
 *      emulator without tripping integrity guards.
 *   2. Override the offerToken value returned by Google Play Billing Library
 *      to simulate the 1-month subscription tier.
 *   3. Intercept BillingResult callbacks so the QA worker can validate the
 *      mocked purchase completed successfully (sandbox — no real charge).
 *
 * Usage:
 *   frida -U -n <package> -l hook_1m.js --no-pause
 */

"use strict";

// ---------------------------------------------------------------------------
// Configuration — adjust these for your app & subscription tier
// ---------------------------------------------------------------------------
var TARGET_PACKAGE     = "com.yourcompany.app";
var MONTHLY_OFFER_ID   = "monthly-sub-offer";
var MONTHLY_BASE_PLAN  = "monthly-base-plan";
// The mock offerToken the sandbox will accept for the 1-month tier
var MOCK_OFFER_TOKEN   = "QA_MOCK_OFFER_TOKEN_1M";

// ---------------------------------------------------------------------------
// Utility helpers
// ---------------------------------------------------------------------------
function log(tag, msg) {
    console.log("[hook_1m] [" + tag + "] " + msg);
}

function toStr(javaStr) {
    return javaStr ? javaStr.toString() : "(null)";
}

// ---------------------------------------------------------------------------
// Wait for the Java VM to be ready, then hook
// ---------------------------------------------------------------------------
Java.perform(function () {
    log("init", "Frida instrumentation loaded for IAP QA");

    // -----------------------------------------------------------------------
    // 1. Bypass environment / emulator detection
    // -----------------------------------------------------------------------
    try {
        var Build = Java.use("android.os.Build");

        // Many apps check Build fields to detect emulators
        Build.FINGERPRINT.value  = "google/walleye/walleye:12/SP1A.210812.016/1234567:user/release-keys";
        Build.MODEL.value        = "Pixel 2";
        Build.MANUFACTURER.value = "Google";
        Build.BRAND.value        = "google";
        Build.DEVICE.value       = "walleye";
        Build.PRODUCT.value      = "walleye";
        Build.HARDWARE.value     = "walleye";

        log("env", "Build fields spoofed to pass emulator detection");
    } catch (e) {
        log("env", "Build spoof skipped: " + e.message);
    }

    // Root / integrity checks (SafetyNet / Play Integrity stubs)
    try {
        var RootCheck = Java.use("com.yourcompany.app.security.RootDetector");
        RootCheck.isDeviceRooted.implementation = function () {
            log("env", "RootDetector.isDeviceRooted() → false");
            return false;
        };
    } catch (e) {
        log("env", "RootDetector hook skipped (class not found): " + e.message);
    }

    try {
        var IntegrityCheck = Java.use("com.yourcompany.app.security.IntegrityValidator");
        IntegrityCheck.validate.implementation = function () {
            log("env", "IntegrityValidator.validate() → bypassed");
            return true;
        };
    } catch (e) {
        log("env", "IntegrityValidator hook skipped (class not found): " + e.message);
    }

    // -----------------------------------------------------------------------
    // 2. Hook Google Play Billing — override offerToken for 1-month tier
    // -----------------------------------------------------------------------
    try {
        // ProductDetails.SubscriptionOfferDetails
        var OfferDetails = Java.use(
            "com.android.billingclient.api.ProductDetails$SubscriptionOfferDetails"
        );

        OfferDetails.getOfferToken.implementation = function () {
            var original = this.getOfferToken.call(this);
            log("billing", "getOfferToken() original: " + toStr(original));
            log("billing", "getOfferToken() → overriding with: " + MOCK_OFFER_TOKEN);
            return Java.use("java.lang.String").$new(MOCK_OFFER_TOKEN);
        };

        OfferDetails.getOfferId.implementation = function () {
            var original = this.getOfferId.call(this);
            log("billing", "getOfferId() original: " + toStr(original) + " → " + MONTHLY_OFFER_ID);
            return Java.use("java.lang.String").$new(MONTHLY_OFFER_ID);
        };

        OfferDetails.getBasePlanId.implementation = function () {
            var original = this.getBasePlanId.call(this);
            log("billing", "getBasePlanId() original: " + toStr(original) + " → " + MONTHLY_BASE_PLAN);
            return Java.use("java.lang.String").$new(MONTHLY_BASE_PLAN);
        };

        log("billing", "SubscriptionOfferDetails hooks installed");
    } catch (e) {
        log("billing", "SubscriptionOfferDetails hook failed: " + e.message);
    }

    // -----------------------------------------------------------------------
    // 3. Intercept BillingResult to validate purchase completion
    // -----------------------------------------------------------------------
    try {
        var BillingResult = Java.use("com.android.billingclient.api.BillingResult");

        BillingResult.getResponseCode.implementation = function () {
            var code = this.getResponseCode.call(this);
            var debugMsg = this.getDebugMessage.call(this);
            log("result", "BillingResult code=" + code + " msg=" + toStr(debugMsg));

            // Response codes: 0=OK, 1=USER_CANCELED, 7=ITEM_ALREADY_OWNED
            if (code === 0) {
                log("result", "Purchase flow completed successfully (sandbox)");
            }
            return code;
        };

        log("billing", "BillingResult hooks installed");
    } catch (e) {
        log("billing", "BillingResult hook failed: " + e.message);
    }

    // -----------------------------------------------------------------------
    // 4. Hook PurchasesUpdatedListener for final validation
    // -----------------------------------------------------------------------
    try {
        var PurchasesUpdatedListener = Java.use(
            "com.android.billingclient.api.PurchasesUpdatedListener"
        );

        var ListenerImpl = Java.use(
            "com.yourcompany.app.billing.PurchaseListener"
        );

        ListenerImpl.onPurchasesUpdated.implementation = function (billingResult, purchases) {
            var code = billingResult.getResponseCode();
            log("purchase", "onPurchasesUpdated → responseCode=" + code);

            if (purchases !== null) {
                var iter = purchases.iterator();
                while (iter.hasNext()) {
                    var purchase = iter.next();
                    log("purchase", "  orderId=" + toStr(purchase.getOrderId()));
                    log("purchase", "  products=" + toStr(purchase.getProducts().toString()));
                    log("purchase", "  purchaseState=" + purchase.getPurchaseState());
                    log("purchase", "  isAcknowledged=" + purchase.isAcknowledged());
                }
            } else {
                log("purchase", "  purchases list is null");
            }

            // Call original implementation
            this.onPurchasesUpdated.call(this, billingResult, purchases);
        };

        log("purchase", "PurchasesUpdatedListener hook installed");
    } catch (e) {
        log("purchase", "PurchasesUpdatedListener hook skipped: " + e.message);
    }

    // -----------------------------------------------------------------------
    // 5. SSL pinning bypass for staging builds (allows Frida traffic inspection)
    // -----------------------------------------------------------------------
    try {
        var TrustManagerImpl = Java.use("com.android.org.conscrypt.TrustManagerImpl");
        TrustManagerImpl.verifyChain.implementation = function () {
            log("ssl", "SSL certificate chain verification bypassed");
            return arguments[0];
        };
    } catch (e) {
        log("ssl", "TrustManagerImpl hook skipped: " + e.message);
    }

    try {
        var OkHttpCertPinner = Java.use("okhttp3.CertificatePinner");
        OkHttpCertPinner.check.overload(
            "java.lang.String", "java.util.List"
        ).implementation = function () {
            log("ssl", "OkHttp CertificatePinner.check() bypassed");
        };
    } catch (e) {
        log("ssl", "OkHttp CertificatePinner hook skipped: " + e.message);
    }

    log("init", "All hooks installed — ready for IAP QA flow");
});
