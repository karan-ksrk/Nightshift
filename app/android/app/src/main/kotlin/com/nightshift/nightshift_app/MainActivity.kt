package com.nightshift.nightshift_app

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.Intent
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.FileNotFoundException

/**
 * Hand-written platform channel ("nightshift/delete", method "delete", arg
 * "uri") for deleting a single picked video through scoped storage's
 * system-confirmed delete flow -- see the Phase 3 plan's "Manual delete
 * flow" section for why this can't be a general media plugin (photo_manager
 * et al. assume MediaStore-indexed gallery assets, not arbitrary picked
 * documents).
 *
 * The plan sketched this as MediaStore.createDeleteRequest (API 30+) with a
 * RecoverableSecurityException fallback (API 29). Checking file_picker's
 * own Android source (FilePickerDelegate.startFileExplorer) before building
 * this showed that's not actually the primary path needed: for the video
 * MIME type, file_picker always launches ACTION_OPEN_DOCUMENT (SAF), never a MediaStore
 * intent -- so the URI handed back is a SAF *document* URI (its authority
 * is a DocumentsProvider, typically the Media Documents Provider), which
 * MediaStore.createDeleteRequest isn't guaranteed to recognize.
 * DocumentsContract.deleteDocument is the API actually meant for a URI
 * obtained that way, and it works the same across every API level this app
 * supports -- no confirmation-dialog plumbing needed, the provider handles
 * that. It's tried first; the MediaStore path stays only as a fallback in
 * case some other picker path (or a future file_picker version) ever hands
 * back a raw MediaStore URI instead.
 *
 * One real limitation, also discovered from that same source read:
 * file_picker never calls takePersistableUriPermission on the picked URI,
 * so the one-time grant from the original pick can already be gone by the
 * time the user taps Delete -- most likely across an app restart, less
 * likely within the same session. That surfaces as a SecurityException,
 * reported back as the distinct "permission_denied" error code rather than
 * silently claiming success.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "nightshift/delete"
    private val deleteRequestCode = 4271

    // Only one delete is ever in flight -- the Dart side awaits one call
    // before making another -- and an Activity result is inherently
    // single-slot per requestCode anyway.
    private var pendingResult: MethodChannel.Result? = null
    private var pendingUri: Uri? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                if (call.method != "delete") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val uriString = call.argument<String>("uri")
                if (uriString == null) {
                    result.error("bad_args", "uri is required", null)
                    return@setMethodCallHandler
                }
                deleteUri(Uri.parse(uriString), result)
            }
    }

    private fun deleteUri(uri: Uri, result: MethodChannel.Result) {
        if (DocumentsContract.isDocumentUri(this, uri)) {
            try {
                val deleted = DocumentsContract.deleteDocument(contentResolver, uri)
                result.success(deleted)
            } catch (e: FileNotFoundException) {
                // Already gone -- deleted elsewhere, or a previous attempt
                // actually succeeded but the app died before recording it.
                result.success(true)
            } catch (e: SecurityException) {
                result.error(
                    "permission_denied",
                    "No permission to delete -- the pick's access grant expired",
                    null,
                )
            }
            return
        }

        // Not a SAF document URI -- fall back to MediaStore's own
        // scoped-storage delete flow.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val pendingIntent = try {
                MediaStore.createDeleteRequest(contentResolver, listOf(uri))
            } catch (e: Exception) {
                result.error("delete_failed", e.message, null)
                return
            }
            pendingResult = result
            pendingUri = uri
            try {
                startIntentSenderForResult(
                    pendingIntent.intentSender, deleteRequestCode, null, 0, 0, 0
                )
            } catch (e: IntentSender.SendIntentException) {
                pendingResult = null
                pendingUri = null
                result.error("send_intent_failed", e.message, null)
            }
            return
        }

        try {
            contentResolver.delete(uri, null, null)
            result.success(true)
        } catch (e: RecoverableSecurityException) {
            pendingResult = result
            pendingUri = uri
            try {
                startIntentSenderForResult(
                    e.userAction.actionIntent.intentSender, deleteRequestCode, null, 0, 0, 0
                )
            } catch (sendEx: IntentSender.SendIntentException) {
                pendingResult = null
                pendingUri = null
                result.error("send_intent_failed", sendEx.message, null)
            }
        } catch (e: SecurityException) {
            result.error("permission_denied", e.message, null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != deleteRequestCode) return

        val result = pendingResult
        val uri = pendingUri
        pendingResult = null
        pendingUri = null
        if (result == null) return

        if (resultCode != Activity.RESULT_OK) {
            // User declined the system dialog -- not an error, just a no.
            result.success(false)
            return
        }

        if (uri != null && Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            // API 29 recovery path: permission was just granted, but the
            // delete itself hasn't happened yet -- retry it now.
            try {
                contentResolver.delete(uri, null, null)
                result.success(true)
            } catch (e: Exception) {
                result.error("delete_failed", e.message, null)
            }
        } else {
            // API 30+: createDeleteRequest's own dialog performs the delete
            // on confirm -- nothing left to do.
            result.success(true)
        }
    }
}
