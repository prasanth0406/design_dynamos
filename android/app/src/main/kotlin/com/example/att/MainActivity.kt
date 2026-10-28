package com.example.att

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.spec.ECGenParameterSpec

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "com.example.att/device_crypto"
    private val keyStoreType = "AndroidKeyStore"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canAuthenticate" -> {
                        try {
                            val biometricManager = BiometricManager.from(this)
                            val authenticators = BiometricManager.Authenticators.BIOMETRIC_STRONG
                            val canAuth = biometricManager.canAuthenticate(authenticators)
                            val isSupported = canAuth == BiometricManager.BIOMETRIC_SUCCESS
                            val status = when (canAuth) {
                                BiometricManager.BIOMETRIC_SUCCESS -> "SUCCESS"
                                BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> "NO_HARDWARE"
                                BiometricManager.BIOMETRIC_ERROR_HW_UNAVAILABLE -> "HW_UNAVAILABLE"
                                BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> "NONE_ENROLLED"
                                BiometricManager.BIOMETRIC_ERROR_SECURITY_UPDATE_REQUIRED -> "SECURITY_UPDATE_REQUIRED"
                                else -> "ERROR_$canAuth"
                            }
                            result.success(mapOf("canAuthenticate" to isSupported, "status" to status))
                        } catch (e: Exception) {
                            result.error("CHECK_FAILED", e.localizedMessage, null)
                        }
                    }

                    "hasKey" -> {
                        val alias = call.argument<String>("alias")
                        if (alias.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Alias is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val keyStore = KeyStore.getInstance(keyStoreType).apply { load(null) }
                            result.success(keyStore.containsAlias(alias))
                        } catch (e: Exception) {
                            result.error("KEYSTORE_ERROR", e.localizedMessage, null)
                        }
                    }

                    "generateKeyPair" -> {
                        val alias = call.argument<String>("alias")
                        if (alias.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Alias is required", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val keyStore = KeyStore.getInstance(keyStoreType).apply { load(null) }
                            if (keyStore.containsAlias(alias)) {
                                keyStore.deleteEntry(alias)
                            }

                            val kpg = KeyPairGenerator.getInstance(
                                KeyProperties.KEY_ALGORITHM_EC,
                                keyStoreType
                            )

                            val builder = KeyGenParameterSpec.Builder(
                                alias,
                                KeyProperties.PURPOSE_SIGN
                            )
                                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                                .setDigests(KeyProperties.DIGEST_SHA256)
                                .setUserAuthenticationRequired(true)
                                .setInvalidatedByBiometricEnrollment(true)

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                                builder.setUserAuthenticationParameters(
                                    0,
                                    KeyProperties.AUTH_BIOMETRIC_STRONG
                                )
                            } else {
                                @Suppress("DEPRECATION")
                                builder.setUserAuthenticationValidityDurationSeconds(-1)
                            }

                            kpg.initialize(builder.build())
                            val keyPair = kpg.generateKeyPair()
                            val spkiBytes = keyPair.public.encoded
                            val base64PublicKey = Base64.encodeToString(spkiBytes, Base64.NO_WRAP)

                            result.success(
                                mapOf(
                                    "publicKey" to base64PublicKey,
                                    "algorithm" to "ES256"
                                )
                            )
                        } catch (e: Exception) {
                            result.error("KEY_GENERATION_FAILED", e.localizedMessage, null)
                        }
                    }

                    "signChallenge" -> {
                        val alias = call.argument<String>("alias")
                        val challenge = call.argument<String>("challenge")
                        val title = call.argument<String>("title") ?: "Authorize Cryptographic Operation"
                        val subtitle = call.argument<String>("subtitle") ?: "Confirm your biometric to proceed"

                        if (alias.isNullOrBlank() || challenge.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Alias and challenge are required", null)
                            return@setMethodCallHandler
                        }

                        try {
                            val keyStore = KeyStore.getInstance(keyStoreType).apply { load(null) }
                            if (!keyStore.containsAlias(alias)) {
                                result.error("KEY_NOT_FOUND", "No cryptographic key found for alias: $alias", null)
                                return@setMethodCallHandler
                            }

                            val privateKey = keyStore.getKey(alias, null) as? PrivateKey
                            if (privateKey == null) {
                                result.error("PRIVATE_KEY_NULL", "Unable to load private key from Android Keystore", null)
                                return@setMethodCallHandler
                            }

                            val signature = Signature.getInstance("SHA256withECDSA")
                            try {
                                signature.initSign(privateKey)
                            } catch (e: KeyPermanentlyInvalidatedException) {
                                result.error(
                                    "KEY_PERMANENTLY_INVALIDATED",
                                    "Biometric enrollment has changed on this device. The private key has been permanently invalidated.",
                                    null
                                )
                                return@setMethodCallHandler
                            } catch (e: Exception) {
                                result.error("INIT_SIGN_FAILED", e.localizedMessage, null)
                                return@setMethodCallHandler
                            }

                            val cryptoObject = BiometricPrompt.CryptoObject(signature)
                            val executor = ContextCompat.getMainExecutor(this)

                            var completed = false
                            val callback = object : BiometricPrompt.AuthenticationCallback() {
                                override fun onAuthenticationSucceeded(authResult: BiometricPrompt.AuthenticationResult) {
                                    super.onAuthenticationSucceeded(authResult)
                                    if (completed) return
                                    completed = true

                                    try {
                                        val crypto = authResult.cryptoObject?.signature
                                            ?: throw IllegalStateException("Signature is null in CryptoObject")
                                        val challengeBytes = challenge.toByteArray(Charsets.UTF_8)
                                        crypto.update(challengeBytes)
                                        val signatureBytes = crypto.sign()
                                        val base64Signature = Base64.encodeToString(signatureBytes, Base64.NO_WRAP)
                                        result.success(mapOf("signature" to base64Signature))
                                    } catch (e: Exception) {
                                        result.error("SIGN_FAILED", e.localizedMessage, null)
                                    }
                                }

                                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                                    super.onAuthenticationError(errorCode, errString)
                                    if (completed) return
                                    completed = true

                                    val errorType = when (errorCode) {
                                        BiometricPrompt.ERROR_USER_CANCELED,
                                        BiometricPrompt.ERROR_NEGATIVE_BUTTON -> "BIOMETRIC_CANCELLED"
                                        BiometricPrompt.ERROR_LOCKOUT,
                                        BiometricPrompt.ERROR_LOCKOUT_PERMANENT -> "BIOMETRIC_LOCKED_OUT"
                                        BiometricPrompt.ERROR_NO_BIOMETRICS -> "BIOMETRIC_NOT_ENROLLED"
                                        else -> "BIOMETRIC_ERROR_$errorCode"
                                    }
                                    result.error(errorType, errString.toString(), null)
                                }

                                override fun onAuthenticationFailed() {
                                    super.onAuthenticationFailed()
                                    // Fingerprint not recognized; BiometricPrompt allows retries until max attempts.
                                }
                            }

                            val promptInfo = BiometricPrompt.PromptInfo.Builder()
                                .setTitle(title)
                                .setSubtitle(subtitle)
                                .setNegativeButtonText("Cancel")
                                .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG)
                                .build()

                            val biometricPrompt = BiometricPrompt(this, executor, callback)
                            biometricPrompt.authenticate(promptInfo, cryptoObject)

                        } catch (e: Exception) {
                            result.error("SIGN_CHALLENGE_FAILED", e.localizedMessage, null)
                        }
                    }

                    "deleteKey" -> {
                        val alias = call.argument<String>("alias")
                        if (alias.isNullOrBlank()) {
                            result.error("INVALID_ARGUMENT", "Alias is required", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val keyStore = KeyStore.getInstance(keyStoreType).apply { load(null) }
                            if (keyStore.containsAlias(alias)) {
                                keyStore.deleteEntry(alias)
                            }
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("DELETE_FAILED", e.localizedMessage, null)
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }
}