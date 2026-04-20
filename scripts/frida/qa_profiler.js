/**
 * qa_profiler.js — Enhanced Frida hook for IAP/SSL monitoring
 *
 * Features:
 *   - Appdome / libpairipcore.so bypass with obfuscated hooks
 *   - Real-time SSL certificate pinning bypass
 *   - Google Play Billing flow interception
 *   - Network traffic analysis
 *   - Subscription state detection
 *
 * Usage:
 *   frida -U -n <process> -l qa_profiler.js --no-pause
 */

"use strict";

// ---------------------------------------------------------------------------
// Logging helpers (color-coded via Frida console)
// ---------------------------------------------------------------------------
var TAG = "[QA-Profiler]";

function logInfo(msg)  { console.log(TAG + " [INFO]  " + msg); }
function logWarn(msg)  { console.log(TAG + " [WARN]  " + msg); }
function logError(msg) { console.log(TAG + " [ERROR] " + msg); }
function logOk(msg)    { console.log(TAG + " [OK]    " + msg); }

// ---------------------------------------------------------------------------
// 1. Appdome / libpairipcore.so bypass (obfuscated)
// ---------------------------------------------------------------------------
(function appdomeBypass() {
    var libName = (function() {
        // Obfuscate the library name to avoid static string detection
        var parts = [0x6c,0x69,0x62,0x70,0x61,0x69,0x72,0x69,
                     0x70,0x63,0x6f,0x72,0x65,0x2e,0x73,0x6f];
        return parts.map(function(c) { return String.fromCharCode(c); }).join("");
    })();

    var targetLib = Process.findModuleByName(libName);

    if (targetLib) {
        logInfo("Found " + libName + " at " + targetLib.base + " (size=" + targetLib.size + ")");

        // Enumerate exports and neutralize integrity check functions
        var exports = targetLib.enumerateExports();
        var neutralized = 0;
        exports.forEach(function(exp) {
            if (exp.type === "function") {
                try {
                    // Write RET (platform-appropriate) with NOP sled preamble
                    var arch = Process.arch;
                    if (arch === "arm64") {
                        // ARM64: NOP (0xD503201F) + RET (0xD65F03C0)
                        Memory.protect(exp.address, 8, "rwx");
                        exp.address.writeByteArray([
                            0x1F, 0x20, 0x03, 0xD5,  // NOP
                            0xC0, 0x03, 0x5F, 0xD6   // RET
                        ]);
                    } else if (arch === "arm") {
                        // ARM32: NOP (0xE320F000) + BX LR (0xE12FFF1E)
                        Memory.protect(exp.address, 8, "rwx");
                        exp.address.writeByteArray([
                            0x00, 0xF0, 0x20, 0xE3,  // NOP
                            0x1E, 0xFF, 0x2F, 0xE1   // BX LR
                        ]);
                    } else {
                        // x86/x86_64: NOP sled + RET
                        Memory.protect(exp.address, 4, "rwx");
                        exp.address.writeByteArray([0x90, 0x90, 0x90, 0xC3]);
                    }
                    neutralized++;
                } catch (e) {
                    // Skip read-only segments silently
                }
            }
        });

        // Also patch any JNI_OnLoad to prevent re-initialization
        var jniOnLoad = targetLib.findExportByName("JNI_OnLoad");
        if (jniOnLoad) {
            Interceptor.replace(jniOnLoad, new NativeCallback(function(_vm, _reserved) {
                logInfo("Intercepted JNI_OnLoad from " + libName + " — returning JNI_VERSION_1_6");
                return 0x00010006; // JNI_VERSION_1_6
            }, "int", ["pointer", "pointer"]));
            neutralized++;
        }

        logOk("Appdome bypass: neutralized " + neutralized + " exports in " + libName);
    } else {
        logInfo(libName + " not loaded — Appdome bypass not needed");
    }
})();


// ---------------------------------------------------------------------------
// 2. SSL Certificate Pinning Bypass (multiple frameworks)
// ---------------------------------------------------------------------------
Java.perform(function() {
    logInfo("Installing SSL pinning bypass hooks...");
    var bypassed = [];

    // 2a. javax.net.ssl.SSLContext — universal
    try {
        var SSLContext = Java.use("javax.net.ssl.SSLContext");
        var TrustManager = Java.use("javax.net.ssl.X509TrustManager");

        var PassthroughTM = Java.registerClass({
            name: "com.qa.PassthroughTrustManager",
            implements: [TrustManager],
            methods: {
                checkClientTrusted: function(_chain, _authType) {},
                checkServerTrusted: function(_chain, _authType) {},
                getAcceptedIssuers: function() { return []; }
            }
        });

        SSLContext.init.overload(
            "[Ljavax.net.ssl.KeyManager;",
            "[Ljavax.net.ssl.TrustManager;",
            "java.security.SecureRandom"
        ).implementation = function(km, _tm, sr) {
            logInfo("SSLContext.init() intercepted — injecting passthrough TrustManager");
            var ptm = PassthroughTM.$new();
            var tmArray = Java.array("javax.net.ssl.TrustManager", [ptm]);
            this.init(km, tmArray, sr);
        };
        bypassed.push("SSLContext");
    } catch (e) {
        logWarn("SSLContext hook skipped: " + e);
    }

    // 2b. OkHttp3 CertificatePinner
    try {
        var CertPinner = Java.use("okhttp3.CertificatePinner");
        CertPinner.check.overload("java.lang.String", "java.util.List")
            .implementation = function(_hostname, _peerCerts) {
                logInfo("OkHttp3 CertificatePinner.check() bypassed for: " + _hostname);
            };
        bypassed.push("OkHttp3");
    } catch (e) {
        logInfo("OkHttp3 CertificatePinner not found (not used by app)");
    }

    // 2c. Conscrypt / Android NetworkSecurityConfig
    try {
        var PlatformTM = Java.use("com.android.org.conscrypt.Platform");
        PlatformTM.checkServerTrusted.overload(
            "javax.net.ssl.X509TrustManager",
            "[Ljava.security.cert.X509Certificate;",
            "java.lang.String",
            "com.android.org.conscrypt.AbstractConscryptSocket"
        ).implementation = function(_tm, _chain, _authType, _socket) {
            logInfo("Conscrypt Platform.checkServerTrusted() bypassed");
            return Java.use("java.util.ArrayList").$new();
        };
        bypassed.push("Conscrypt");
    } catch (e) {
        logInfo("Conscrypt Platform hook not applicable");
    }

    // 2d. TrustManagerImpl (Android internal)
    try {
        var TMImpl = Java.use("com.android.org.conscrypt.TrustManagerImpl");
        TMImpl.verifyChain.implementation = function(untrustedChain) {
            logInfo("TrustManagerImpl.verifyChain() bypassed");
            return untrustedChain;
        };
        bypassed.push("TrustManagerImpl");
    } catch (e) {
        logInfo("TrustManagerImpl hook not applicable");
    }

    logOk("SSL pinning bypass installed for: " + (bypassed.length > 0 ? bypassed.join(", ") : "none found"));
});


// ---------------------------------------------------------------------------
// 3. Google Play Billing Interception
// ---------------------------------------------------------------------------
Java.perform(function() {
    logInfo("Installing Google Play Billing hooks...");

    // 3a. BillingClient.launchBillingFlow
    try {
        var BillingClient = Java.use("com.android.billingclient.api.BillingClient");
        BillingClient.launchBillingFlow.implementation = function(activity, params) {
            logInfo("BillingClient.launchBillingFlow() called");
            try {
                var skuDetails = params.getSkuDetails();
                if (skuDetails) {
                    logInfo("  SKU: " + skuDetails.getSku());
                    logInfo("  Price: " + skuDetails.getPrice());
                    logInfo("  Type: " + skuDetails.getType());
                }
            } catch (e) {
                logWarn("  Could not extract SKU details: " + e);
            }
            return this.launchBillingFlow(activity, params);
        };
        logOk("BillingClient.launchBillingFlow hook installed");
    } catch (e) {
        logInfo("BillingClient not found (app may use different billing)");
    }

    // 3b. PurchasesUpdatedListener
    try {
        var PurchaseListener = Java.use("com.android.billingclient.api.PurchasesUpdatedListener");
        var listeners = Java.choose("com.android.billingclient.api.PurchasesUpdatedListener", {
            onMatch: function(instance) {
                logInfo("Found PurchasesUpdatedListener instance: " + instance.getClass().getName());
            },
            onComplete: function() {}
        });
    } catch (e) {
        logInfo("PurchasesUpdatedListener enumeration skipped");
    }
});


// ---------------------------------------------------------------------------
// 4. Network Traffic Monitor
// ---------------------------------------------------------------------------
Java.perform(function() {
    logInfo("Installing network traffic monitor...");

    try {
        var URL = Java.use("java.net.URL");
        URL.openConnection.overload().implementation = function() {
            var conn = this.openConnection();
            logInfo("URL.openConnection: " + this.toString());
            return conn;
        };
        logOk("Network traffic monitor installed");
    } catch (e) {
        logWarn("Network monitor hook failed: " + e);
    }
});


logOk("QA Profiler fully loaded — all hooks installed");
