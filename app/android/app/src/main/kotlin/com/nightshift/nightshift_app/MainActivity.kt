package com.nightshift.nightshift_app

import android.app.Activity
import android.app.RecoverableSecurityException
import android.content.Intent
import android.content.IntentSender
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.util.Log
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
 * file_picker never calls takePersistableUriPermission on the picked URI.
 * The grant it gets from ACTION_OPEN_DOCUMENT is transient by default --
 * per Android's own docs, that lasts only until the app's process is
 * killed, not just an explicit force-quit. Confirmed for real during the
 * M7 ten-video run: all ten uploads survived a background process death
 * mid-batch (M4's resume logic re-reads everything from disk/db), but every
 * one of them then failed Delete with permission_denied -- the transient
 * URI grants didn't survive that same death. "persistAccess" below exists
 * to close that gap going forward: called once at pick time, before
 * hashing/uploading even starts, so the grant is upgraded to a persistable
 * one while it's still definitely fresh. A pick made before this existed
 * has no persisted grant to fall back on -- deleting those from the app
 * will keep failing; the file itself is still safe (already archived), it
 * just has to be removed manually if wanted.
 */
class MainActivity : FlutterActivity() {
    private val tag = "NightshiftDelete"
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
                val uriString = call.argument<String>("uri")
                if (uriString == null) {
                    result.error("bad_args", "uri is required", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "delete" -> deleteUri(Uri.parse(uriString), result)
                    "persistAccess" -> persistAccess(Uri.parse(uriString), result)
                    else -> result.notImplemented()
                }
            }
    }

    /// Best-effort: upgrades the transient read/write grant from the
    /// original pick into one that survives process death and device
    /// reboots. Not every DocumentsProvider grants write access by default
    /// (some only read) -- tries read+write first, falls back to read-only
    /// so at least future GET /offset-style read access survives even if
    /// delete itself won't work without a fresh pick.
    private fun persistAccess(uri: Uri, result: MethodChannel.Result) {
        Log.d(tag, "persistAccess: uri=$uri isDocumentUri=${DocumentsContract.isDocumentUri(this, uri)}")
        val readWrite = Intent.FLAG_GRANT_READ_URI_PERMISSION or
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        try {
            contentResolver.takePersistableUriPermission(uri, readWrite)
            Log.d(tag, "persistAccess: granted read+write for $uri")
            result.success(true)
            return
        } catch (e: SecurityException) {
            Log.w(tag, "persistAccess: read+write denied for $uri: ${e.message}")
        }
        try {
            contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
            )
            Log.d(tag, "persistAccess: granted read-only for $uri")
            result.success(true)
        } catch (e: SecurityException) {
            Log.w(tag, "persistAccess: read-only also denied for $uri: ${e.message}")
            result.success(false)
        }
    }

    private fun deleteUri(uri: Uri, result: MethodChannel.Result) {
        val isDoc = DocumentsContract.isDocumentUri(this, uri)
        Log.d(tag, "deleteUri: uri=$uri isDocumentUri=$isDoc")
        if (isDoc) {
            try {
                val deleted = DocumentsContract.deleteDocument(contentResolver, uri)
                Log.d(tag, "deleteUri: deleteDocument returned $deleted for $uri")
                result.success(deleted)
            } catch (e: FileNotFoundException) {
                // Already gone -- deleted elsewhere, or a previous attempt
                // actually succeeded but the app died before recording it.
                Log.d(tag, "deleteUri: $uri already gone (FileNotFoundException)")
                result.success(true)
            } catch (e: SecurityException) {
                Log.w(tag, "deleteUri: permission denied for $uri: ${e.message}")
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
