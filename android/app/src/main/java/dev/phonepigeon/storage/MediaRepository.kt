package dev.phonepigeon.storage

import android.Manifest
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.MediaStore
import android.webkit.MimeTypeMap
import dev.phonepigeon.proto.FileEntry
import dev.phonepigeon.proto.FileOpType
import dev.phonepigeon.proto.FileOperationRequest
import dev.phonepigeon.proto.FileOperationResponse
import dev.phonepigeon.proto.ListDirectoryRequest
import dev.phonepigeon.proto.ListDirectoryResponse
import dev.phonepigeon.proto.ListMediaGalleryRequest
import dev.phonepigeon.proto.ListMediaGalleryResponse
import dev.phonepigeon.proto.MediaItem
import dev.phonepigeon.proto.MediaTypeFilter
import dev.phonepigeon.telephony.has
import java.io.File

/**
 * Gallery indexer (MediaStore) and file explorer (NIO under /storage/emulated/0) — spec v2 §6.1.
 * Every path the Mac sends is relative to the storage root and canonicalised to block `../` traversal.
 */
object MediaRepository {
    val root: File get() = Environment.getExternalStorageDirectory()

    /** Resolves a Mac-supplied relative path, or null if it escapes the storage root. */
    fun resolve(relative: String): File? {
        val rootPath = root.canonicalPath
        val f = File(root, relative.trimStart('/')).canonicalFile
        return if (f.path == rootPath || f.path.startsWith("$rootPath/")) f else null
    }

    fun relative(f: File): String = "/" + f.canonicalPath.removePrefix(root.canonicalPath).trimStart('/')

    fun mimeOf(name: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase()) ?: "application/octet-stream"

    fun hasAllFilesAccess(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) Environment.isExternalStorageManager() else true

    fun canReadMedia(context: Context): Boolean =
        if (Build.VERSION.SDK_INT >= 33) context.has(Manifest.permission.READ_MEDIA_IMAGES) || context.has(Manifest.permission.READ_MEDIA_VIDEO)
        else context.has(Manifest.permission.READ_EXTERNAL_STORAGE)

    // ------------------------------------------------------------------ file explorer

    fun list(req: ListDirectoryRequest): ListDirectoryResponse {
        if (!hasAllFilesAccess()) return ListDirectoryResponse(req.requestId, req.path, emptyList(),
            "Allow “All files access” for PhonePigeon on your phone to browse its storage.")
        val dir = resolve(req.path) ?: return ListDirectoryResponse(req.requestId, req.path, emptyList(), "Path is outside phone storage")
        if (!dir.isDirectory) return ListDirectoryResponse(req.requestId, req.path, emptyList(), "Not a folder")
        val children = dir.listFiles().orEmpty()
            .filter { req.includeHidden || !it.name.startsWith(".") }
            .map { f ->
                FileEntry(
                    path = relative(f),
                    name = f.name,
                    isDirectory = f.isDirectory,
                    sizeBytes = if (f.isFile) f.length() else 0,
                    mimeType = if (f.isDirectory) "inode/directory" else mimeOf(f.name),
                    modifiedAtMs = f.lastModified(),
                    childCount = if (f.isDirectory) countChildren(f) else 0,
                )
            }
        return ListDirectoryResponse(req.requestId, relative(dir), children)
    }

    @Volatile private var latestSearch = ""

    /**
     * Whole-phone name search, breadth first so shallow matches come first. Stops at the match limit or after 12 s,
     * and abandons itself as soon as a newer search arrives (the Mac searches as you type).
     */
    fun search(req: dev.phonepigeon.proto.SearchFilesRequest): dev.phonepigeon.proto.SearchFilesResponse {
        fun fail(m: String) = dev.phonepigeon.proto.SearchFilesResponse(req.requestId, emptyList(), false, m)
        if (!hasAllFilesAccess()) return fail("Allow “All files access” for PhonePigeon on your phone to search its storage.")
        val q = req.query.trim().lowercase()
        if (q.length < 2) return dev.phonepigeon.proto.SearchFilesResponse(req.requestId, emptyList())
        latestSearch = req.requestId
        val limit = req.limit.coerceIn(1, 1000)
        val deadline = System.currentTimeMillis() + 12_000
        val results = ArrayList<FileEntry>()
        val queue = java.util.ArrayDeque<File>()
        queue.add(root)
        var truncated = false
        while (queue.isNotEmpty()) {
            if (latestSearch != req.requestId) break // superseded
            if (System.currentTimeMillis() > deadline) { truncated = true; break }
            val dir = queue.removeFirst()
            val children = runCatching { dir.listFiles() }.getOrNull() ?: continue
            for (f in children) {
                val name = f.name
                if (!req.includeHidden && name.startsWith(".")) continue
                val isDir = f.isDirectory
                if (name.lowercase().contains(q)) {
                    results += FileEntry(
                        path = relative(f), name = name, isDirectory = isDir,
                        sizeBytes = if (f.isFile) f.length() else 0,
                        mimeType = if (isDir) "inode/directory" else mimeOf(name),
                        modifiedAtMs = f.lastModified(), childCount = 0,
                    )
                    if (results.size >= limit) { truncated = true; break }
                }
                // Other apps' private folders are unreadable anyway; symlinks could loop.
                if (isDir && !isPrivateAppDir(f) && !java.nio.file.Files.isSymbolicLink(f.toPath())) queue.add(f)
            }
            if (results.size >= limit) break
        }
        return dev.phonepigeon.proto.SearchFilesResponse(req.requestId, results, truncated)
    }

    private fun isPrivateAppDir(f: File): Boolean {
        val p = relative(f)
        return p == "/Android/data" || p == "/Android/obb"
    }

    /** Counts entries without materialising huge listings (capped at 999). */
    private fun countChildren(dir: File): Int = runCatching {
        java.nio.file.Files.newDirectoryStream(dir.toPath()).use { ds ->
            var n = 0
            for (@Suppress("UNUSED_VARIABLE") e in ds) { if (++n >= 999) break }
            n
        }
    }.getOrDefault(0)

    fun apply(context: Context, req: FileOperationRequest): FileOperationResponse {
        fun fail(m: String) = FileOperationResponse(req.requestId, false, m)
        if (!hasAllFilesAccess()) return fail("Allow “All files access” for PhonePigeon on your phone.")
        val src = resolve(req.sourcePath) ?: return fail("Path is outside phone storage")
        if (src.path == root.canonicalPath) return fail("Can't modify the storage root")
        val ok = when (req.op) {
            FileOpType.MKDIR -> src.isDirectory || src.mkdirs()
            FileOpType.RENAME -> {
                val dst = resolve(req.targetPath) ?: return fail("Target is outside phone storage")
                if (dst.exists()) return fail("“${dst.name}” already exists")
                src.renameTo(dst).also { if (it) scan(context, src, dst) }
            }
            FileOpType.DELETE -> src.deleteRecursively().also { if (it) scan(context, src) }
            FileOpType.FILE_OP_UNSPECIFIED -> return fail("Unknown operation")
        }
        return if (ok) FileOperationResponse(req.requestId, true) else fail("The phone refused the ${req.op.name.lowercase()}")
    }

    fun scan(context: Context, vararg files: File) {
        android.media.MediaScannerConnection.scanFile(context, files.map { it.path }.toTypedArray(), null, null)
    }

    // ------------------------------------------------------------------ gallery

    private val filesUri: Uri get() = MediaStore.Files.getContentUri("external")
    private const val IMAGE = MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE
    private const val VIDEO = MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO

    fun contentUri(id: Long, mime: String? = null): Uri = when {
        mime?.startsWith("video/") == true -> ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
        mime?.startsWith("image/") == true -> ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
        else -> ContentUris.withAppendedId(filesUri, id)
    }

    fun mimeOfMedia(context: Context, id: Long): String? =
        context.contentResolver.query(ContentUris.withAppendedId(filesUri, id), arrayOf(MediaStore.MediaColumns.MIME_TYPE), null, null, null)
            ?.use { if (it.moveToFirst()) it.getString(0) else null }

    fun gallery(context: Context, req: ListMediaGalleryRequest): ListMediaGalleryResponse {
        if (!canReadMedia(context)) return ListMediaGalleryResponse(req.requestId, emptyList(), emptyList(), false)
        val types = when (req.filter) {
            MediaTypeFilter.MEDIA_IMAGES -> "($IMAGE)"
            MediaTypeFilter.MEDIA_VIDEOS -> "($VIDEO)"
            MediaTypeFilter.MEDIA_ALL -> "($IMAGE,$VIDEO)"
        }
        val sel = StringBuilder("${MediaStore.Files.FileColumns.MEDIA_TYPE} IN $types")
        val args = mutableListOf<String>()
        if (req.bucketName.isNotEmpty()) { sel.append(" AND ${MediaStore.MediaColumns.BUCKET_DISPLAY_NAME} = ?"); args += req.bucketName }
        val limit = req.limit.coerceIn(1, 500)
        val projection = arrayOf(
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME, MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.MIME_TYPE, MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.WIDTH,
            MediaStore.MediaColumns.HEIGHT, MediaStore.MediaColumns.DURATION, MediaStore.MediaColumns.DATE_TAKEN,
            MediaStore.MediaColumns.DATE_ADDED, MediaStore.MediaColumns.RELATIVE_PATH,
        )
        val order = "${MediaStore.MediaColumns.DATE_TAKEN} DESC, ${MediaStore.MediaColumns.DATE_ADDED} DESC"
        val cursor = if (Build.VERSION.SDK_INT >= 30) {
            context.contentResolver.query(filesUri, projection, Bundle().apply {
                putString(ContentResolver.QUERY_ARG_SQL_SELECTION, sel.toString())
                putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, args.toTypedArray())
                putString(ContentResolver.QUERY_ARG_SQL_SORT_ORDER, order)
                putInt(ContentResolver.QUERY_ARG_LIMIT, limit + 1)
                putInt(ContentResolver.QUERY_ARG_OFFSET, req.offset)
            }, null)
        } else {
            context.contentResolver.query(filesUri, projection, sel.toString(), args.toTypedArray(), "$order LIMIT ${limit + 1} OFFSET ${req.offset}")
        }
        val items = ArrayList<MediaItem>()
        cursor?.use { c ->
            while (c.moveToNext()) {
                val taken = c.getLong(8).takeIf { it > 0 } ?: (c.getLong(9) * 1000)
                items += MediaItem(
                    mediaStoreId = c.getLong(0),
                    path = "/" + (c.getString(10) ?: "").trimEnd('/') + "/" + (c.getString(1) ?: ""),
                    displayName = c.getString(1) ?: "",
                    bucketName = c.getString(2) ?: "",
                    mimeType = c.getString(3) ?: "",
                    sizeBytes = c.getLong(4),
                    width = c.getInt(5),
                    height = c.getInt(6),
                    durationMs = c.getLong(7),
                    dateTakenMs = taken,
                )
            }
        }
        val hasMore = items.size > limit
        return ListMediaGalleryResponse(req.requestId, items.take(limit), buckets(context), hasMore)
    }

    @Volatile private var bucketCache: Pair<Long, List<String>>? = null

    private fun buckets(context: Context): List<String> {
        bucketCache?.let { (at, v) -> if (System.currentTimeMillis() - at < 30_000) return v }
        val set = sortedSetOf<String>()
        context.contentResolver.query(filesUri, arrayOf(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME),
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN ($IMAGE,$VIDEO)", null, null)?.use { c ->
            while (c.moveToNext()) c.getString(0)?.let(set::add)
        }
        return set.toList().also { bucketCache = System.currentTimeMillis() to it }
    }
}
