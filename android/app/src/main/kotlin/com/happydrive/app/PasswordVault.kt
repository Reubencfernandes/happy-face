package com.happydrive.app

import android.app.Activity
import android.os.Handler
import android.os.Looper
import androidx.credentials.CreateCredentialResponse
import androidx.credentials.CreatePasswordRequest
import androidx.credentials.CredentialManager
import androidx.credentials.CredentialManagerCallback
import androidx.credentials.GetCredentialRequest
import androidx.credentials.GetCredentialResponse
import androidx.credentials.GetPasswordOption
import androidx.credentials.PasswordCredential
import androidx.credentials.exceptions.CreateCredentialCancellationException
import androidx.credentials.exceptions.CreateCredentialException
import androidx.credentials.exceptions.GetCredentialException
import java.util.concurrent.Executor

/**
 * Keeps the library passphrase in the phone's password manager (Google
 * Password Manager unless the person picked another provider), through
 * Credential Manager. Both calls show the system sheet, so they need the
 * Activity rather than the application context.
 */
class PasswordVault(private val activity: Activity) {
    private val manager = CredentialManager.create(activity)
    private val main = Handler(Looper.getMainLooper())
    private val onMain = Executor { main.post(it) }

    /** Answers "saved", "cancelled" or "unavailable". */
    fun save(id: String, password: String, done: (String) -> Unit) {
        manager.createCredentialAsync(
            activity,
            CreatePasswordRequest(id, password),
            null,
            onMain,
            object : CredentialManagerCallback<CreateCredentialResponse, CreateCredentialException> {
                override fun onResult(result: CreateCredentialResponse) = done("saved")
                override fun onError(e: CreateCredentialException) =
                    done(if (e is CreateCredentialCancellationException) "cancelled" else "unavailable")
            },
        )
    }

    /** The saved id and password the person picks, or null. */
    fun load(done: (Map<String, String>?) -> Unit) {
        manager.getCredentialAsync(
            activity,
            GetCredentialRequest(listOf(GetPasswordOption())),
            null,
            onMain,
            object : CredentialManagerCallback<GetCredentialResponse, GetCredentialException> {
                override fun onResult(result: GetCredentialResponse) {
                    val credential = result.credential as? PasswordCredential
                    done(credential?.let { mapOf("id" to it.id, "password" to it.password) })
                }

                override fun onError(e: GetCredentialException) = done(null)
            },
        )
    }
}
