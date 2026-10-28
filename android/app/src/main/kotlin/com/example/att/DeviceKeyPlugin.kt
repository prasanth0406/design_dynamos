package com.example.att

import android.content.pm.PackageManager
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import android.security.keystore.UserNotAuthenticatedException
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricManager.Authenticators.BIOMETRIC_STRONG
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/**
 * Device-bound attendance key backed by the Android Keystore.
 *
 * The EC P-256 private key is generated inside the Keystore (StrongBox when
 * available, otherwise the TEE), is non-exportable, can only sign after a
 * Class 3 (strong) biometric authentication for that specific operation, and
 * is permanently invalidated when a new biometric is enrolled. Only the
 * public key, the attestation certificate chain and signatures leave this
 * class.
 *
 * Android does not report which enrolled fingerprint satisfied the prompt; a
 * successful signature proves that *a* strong biometric enrolled on this phone
 * at key-creation time was presented, not that it belonged to the student.
 */
class DeviceKeyPlugin(
    private val activity: FragmentActivity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {

    companion object {
        const val CHANNEL = "com.example.att/device_key"
        private const val KEY_ALIAS = "sdtt_attendance_device_key_v1"
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val SIGNATURE_ALGORITHM = "SHA256withECDSA"
        private const val MAX_PAYLOAD_CHARS = 2048
    }

    private val channel = MethodChannel(messenger, CHANNEL).also {
        it.setMethodCallHandler(this)
    }
    private var signInProgress = false

    fun dispose() = channel.setMethodCallHandler(null)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getStatus" -> result.success(status())
                "generateKey" -> {
                    val challenge = call.argument<String>("attestationChallenge")
                    result.success(generateKey(challenge?.let { decodeBase64(it) }))
                }
                "getPublicKey" -> result.success(publicKeyBase64())
                "deleteKey" -> {
                    keyStore().deleteEntry(KEY_ALIAS)
                    result.success(null)
                }
                "sign" -> sign(call, result)
                else -> result.notImplemented()
            }
        } catch (e: IllegalArgumentException) {
            result.error("INVALID_ARGUMENT", e.message, null)
        } catch (e: Exception) {
            result.error("KEYSTORE_ERROR", e.javaClass.simpleName + ": " + e.message, null)
        }
    }

    private fun keyStore(): KeyStore =
        KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    private fun decodeBase64(value: String): ByteArray =
        try {
            Base64.decode(value, Base64.NO_WRAP)
        } catch (e: IllegalArgumentException) {
            throw IllegalArgumentException("attestationChallenge is not base64")
        }

    private fun encode(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

    private fun biometricStatus(): String =
        when (BiometricManager.from(activity).canAuthenticate(BIOMETRIC_STRONG)) {
            BiometricManager.BIOMETRIC_SUCCESS -> "available"
            BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "none_enrolled"
            BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "no_hardware"
            BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "hardware_unavailable"
            BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "security_update_required"
            else -> "unsupported"
        }

    private fun strongBoxSupported(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.P &&
            activity.packageManager.hasSystemFeature(PackageManager.FEATURE_STRONGBOX_KEYSTORE)

    private fun status(): Map<String, Any?> = mapOf(
        "hasKey" to keyStore().containsAlias(KEY_ALIAS),
        "biometricStatus" to biometricStatus(),
        "strongBoxSupported" to strongBoxSupported(),
        "sdkInt" to Build.VERSION.SDK_INT,
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
    )

    private fun publicKeyBase64(): String? =
        keyStore().getCertificate(KEY_ALIAS)?.publicKey?.encoded?.let(::encode)

    @Suppress("DEPRECATION")
    private fun buildSpec(challenge: ByteArray?, strongBox: Boolean): KeyGenParameterSpec {
        val builder = KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN)
            .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
            .setDigests(KeyProperties.DIGEST_SHA256)
            .setUserAuthenticationRequired(true)
            .setInvalidatedByBiometricEnrollment(true)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            // Timeout 0 = authentication is required for every single use.
            builder.setUserAuthenticationParameters(0, KeyProperties.AUTH_BIOMETRIC_STRONG)
        } else {
            // -1 = every use must be authorized through a BiometricPrompt CryptoObject.
            builder.setUserAuthenticationValidityDurationSeconds(-1)
        }
        if (challenge != null) builder.setAttestationChallenge(challenge)
        if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            builder.setIsStrongBoxBacked(true)
        }
        return builder.build()
    }

    private fun generateKey(challenge: ByteArray?): Map<String, Any?> {
        if (biometricStatus() != "available") {
            throw IllegalStateException("Strong biometric authentication is not available: ${biometricStatus()}")
        }
        val store = keyStore()
        store.deleteEntry(KEY_ALIAS)

        var usedStrongBox = false
        val generator = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
        if (strongBoxSupported()) {
            try {
                generator.initialize(buildSpec(challenge, strongBox = true))
                generator.generateKeyPair()
                usedStrongBox = true
            } catch (e: StrongBoxUnavailableException) {
                usedStrongBox = false
            }
        }
        if (!usedStrongBox) {
            generator.initialize(buildSpec(challenge, strongBox = false))
            generator.generateKeyPair()
        }

        val chain = store.getCertificateChain(KEY_ALIAS)?.map { encode(it.encoded) } ?: emptyList()
        return mapOf(
            "publicKey" to publicKeyBase64(),
            "attestationChain" to chain,
            "strongBox" to usedStrongBox,
            "securityLevel" to securityLevel(store),
        )
    }

    @Suppress("DEPRECATION")
    private fun securityLevel(store: KeyStore): String {
        val key = store.getKey(KEY_ALIAS, null) as? PrivateKey ?: return "unknown"
        val info = KeyFactory.getInstance(key.algorithm, ANDROID_KEYSTORE)
            .getKeySpec(key, KeyInfo::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            return when (info.securityLevel) {
                KeyProperties.SECURITY_LEVEL_STRONGBOX -> "strongbox"
                KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "trusted_environment"
                KeyProperties.SECURITY_LEVEL_SOFTWARE -> "software"
                else -> "unknown"
            }
        }
        return if (info.isInsideSecureHardware) "secure_hardware" else "software"
    }

    private fun sign(call: MethodCall, result: MethodChannel.Result) {
        val payload = call.argument<String>("payload")
            ?: throw IllegalArgumentException("payload is required")
        require(payload.length in 1..MAX_PAYLOAD_CHARS) { "payload has an invalid length" }
        val title = call.argument<String>("title") ?: "Verify your identity"
        val subtitle = call.argument<String>("subtitle") ?: "Confirm with your fingerprint or face"

        if (signInProgress) {
            result.error("IN_PROGRESS", "Another verification is already in progress.", null)
            return
        }
        if (biometricStatus() != "available") {
            result.error("BIOMETRIC_UNAVAILABLE", biometricStatus(), null)
            return
        }
        val key = keyStore().getKey(KEY_ALIAS, null) as? PrivateKey
        if (key == null) {
            result.error("NO_KEY", "No attendance key exists on this phone.", null)
            return
        }

        val signature = Signature.getInstance(SIGNATURE_ALGORITHM)
        try {
            signature.initSign(key)
        } catch (e: KeyPermanentlyInvalidatedException) {
            keyStore().deleteEntry(KEY_ALIAS)
            result.error("KEY_INVALIDATED",
                "Biometric enrollment changed, so this phone's attendance key was destroyed.", null)
            return
        } catch (e: UserNotAuthenticatedException) {
            result.error("KEYSTORE_ERROR", "The key could not be initialized for signing.", null)
            return
        }

        signInProgress = true
        var replied = false
        fun reply(block: () -> Unit) {
            if (replied) return
            replied = true
            signInProgress = false
            block()
        }

        val prompt = BiometricPrompt(
            activity,
            ContextCompat.getMainExecutor(activity),
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                    val unlocked = authResult.cryptoObject?.signature
                    if (unlocked == null) {
                        reply { result.error("KEYSTORE_ERROR", "No signature object was returned.", null) }
                        return
                    }
                    try {
                        unlocked.update(payload.toByteArray(Charsets.UTF_8))
                        val bytes = unlocked.sign()
                        reply { result.success(encode(bytes)) }
                    } catch (e: Exception) {
                        reply { result.error("SIGN_FAILED", e.javaClass.simpleName + ": " + e.message, null) }
                    }
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    val code = when (errorCode) {
                        BiometricPrompt.ERROR_USER_CANCELED,
                        BiometricPrompt.ERROR_NEGATIVE_BUTTON,
                        BiometricPrompt.ERROR_CANCELED -> "CANCELLED"
                        BiometricPrompt.ERROR_LOCKOUT,
                        BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "LOCKED_OUT"
                        BiometricPrompt.ERROR_NO_BIOMETRICS -> "BIOMETRIC_UNAVAILABLE"
                        BiometricPrompt.ERROR_HW_NOT_PRESENT,
                        BiometricPrompt.ERROR_HW_UNAVAILABLE -> "BIOMETRIC_UNAVAILABLE"
                        else -> "AUTH_ERROR"
                    }
                    reply { result.error(code, errString.toString(), null) }
                }
                // onAuthenticationFailed = one unrecognized attempt; the prompt stays open.
            },
        )

        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(title)
            .setSubtitle(subtitle)
            .setNegativeButtonText("Cancel")
            .setAllowedAuthenticators(BIOMETRIC_STRONG)
            .setConfirmationRequired(true)
            .build()
        prompt.authenticate(info, BiometricPrompt.CryptoObject(signature))
    }
}
