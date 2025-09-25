package io.carius.lars.ar_flutter_update

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.ar.sceneform.rendering.ModelRenderable
import java.io.File
import java.io.IOException
import java.net.URL
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore

object GlbRenderableLoader {
    private const val TAG = "GlbRenderableLoader"

    private val gate = Semaphore(3) // حدّ التوازي
    private val inflight = ConcurrentHashMap<String, CompletableFuture<ModelRenderable>>()
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    /** تنزيل GLB إلى الكاش */
    @Throws(IOException::class)
    private fun downloadGlbToCache(context: Context, url: String): File {
        val name = "mdl_${url.hashCode()}.glb"
        val out = File(context.cacheDir, name)
        if (out.exists() && out.length() > 0L) {
            return out
        }

        val conn = URL(url).openConnection()
        conn.getInputStream().use { input ->
            out.outputStream().use { output ->
                input.copyTo(output)
            }
        }

        if (!out.exists() || out.length() == 0L) {
            throw IOException("Empty download: $url")
        }
        return out
    }

    /** بناء ModelRenderable على UI Thread */
    private fun buildRenderableOnUiThread(
        context: Context,
        uri: Uri,
        registryId: String
    ): CompletableFuture<ModelRenderable> {
        val future = CompletableFuture<ModelRenderable>()
        mainHandler.post {
            try {
                ModelRenderable.builder()
                    .setSource(context, uri)
                    .setIsFilamentGltf(true)
                    // نخلي registryId يتغير عشان ما يعلّق الكاش
                    .setRegistryId("$registryId-${System.currentTimeMillis()}")
                    .build()
                    .thenAccept { future.complete(it) }
                    .exceptionally { t ->
                        future.completeExceptionally(t)
                        null
                    }
            } catch (e: Exception) {
                future.completeExceptionally(e)
            }
        }
        return future
    }

    /** تحميل GLB بدون progress */
    fun load(
        context: Context,
        modelPath: String,
        maxRetries: Int = 2
    ): CompletableFuture<ModelRenderable> {
        inflight[modelPath]?.let { return it }

        val out = CompletableFuture<ModelRenderable>()
        inflight[modelPath] = out

        Thread {
            var attempt = 0

            fun releaseAndFail(t: Throwable) {
                inflight.remove(modelPath)
                out.completeExceptionally(t)
                try { gate.release() } catch (_: Exception) {}
            }

            try {
                gate.acquire()

                fun once(): CompletableFuture<ModelRenderable> {
                    return try {
                        when {
                            modelPath.startsWith("http://") || modelPath.startsWith("https://") -> {
                                val file = downloadGlbToCache(context, modelPath)
                                buildRenderableOnUiThread(context, Uri.fromFile(file), modelPath)
                            }
                            modelPath.startsWith("content://") || modelPath.startsWith("file://") -> {
                                buildRenderableOnUiThread(context, Uri.parse(modelPath), modelPath)
                            }
                            else -> {
                                val file = File(modelPath)
                                buildRenderableOnUiThread(context, Uri.fromFile(file), modelPath)
                            }
                        }
                    } catch (e: Exception) {
                        val cf = CompletableFuture<ModelRenderable>()
                        cf.completeExceptionally(e)
                        cf
                    }
                }

                fun tryAttempt() {
                    once()
                        .thenAccept { r ->
                            inflight.remove(modelPath)
                            out.complete(r)
                            gate.release()
                        }
                        .exceptionally { t ->
                            if (attempt < maxRetries) {
                                attempt++
                                try { Thread.sleep(300L * attempt) } catch (_: InterruptedException) {}
                                tryAttempt()
                            } else {
                                releaseAndFail(t ?: RuntimeException("Unknown error"))
                            }
                            null
                        }
                }

                tryAttempt()
            } catch (e: Exception) {
                releaseAndFail(e)
            }
        }.start()

        return out
    }
}
