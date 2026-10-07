package com.droiddeck.launcher.session

import android.content.Context
import android.os.Process
import android.util.Log
import com.droiddeck.launcher.core.DeviceSupport
import com.droiddeck.launcher.core.FileUtils
import com.droiddeck.launcher.core.HostProcess
import com.droiddeck.launcher.core.SessionPart
import java.io.File
import java.io.PrintWriter

/**
 * Vulkan for the session on a GPU Turnip cannot drive (Mali, Xclipse, PowerVR), through Venus.
 *
 * The guest's processes are glibc and cannot load the vendor's bionic driver. Instead they load
 * Mesa's Venus ICD (libvulkan_virtio.so), which serializes every Vulkan call over a unix socket to
 * virglrenderer's vtest server. The server runs here, on the Android side, and replays the calls
 * on the device's own Vulkan driver. Both ends of the socket are under the app's files directory,
 * which the session binds at its own path, so the same path works inside and out.
 */
class VenusComponent(private val logFile: File?) : SessionPart() {
    @Volatile private var pid = -1

    override fun start() {
        val context = app()
        stageIcd(context)
        val libDir = context.applicationInfo.nativeLibraryDir
        val socket = socket(context)
        socket.delete()
        val env = arrayOf(
            "LD_LIBRARY_PATH=$libDir",
            // vtest forks a render server per client; this is where its executable is.
            "RENDER_SERVER_EXEC_PATH=$libDir/libvirgl_render_server.so",
            "TMPDIR=" + context.cacheDir.path,
        )
        val command = "$libDir/libvirgl_test_server.so --venus --no-virgl --socket-path " + socket.path
        val out = logFile?.let { runCatching { PrintWriter(java.io.FileWriter(it, true)) }.getOrNull() }
        pid = HostProcess.start(command, env, context.filesDir, { status ->
            Log.w(TAG, "vtest server exited: $status")
            out?.let { synchronized(it) { it.println("vtest server exited: $status"); it.flush() } }
        }, { line ->
            Log.i(TAG, line)
            out?.let { synchronized(it) { it.println(line); it.flush() } }
        })
        Log.i(TAG, "vtest server pid $pid on $socket")
    }

    override fun stop() {
        if (pid > 1) Process.killProcess(pid)
        pid = -1
    }

    companion object {
        private const val TAG = "Venus"
        private const val ASSET = "venus/libvulkan_virtio.so"
        private const val DIR = "venus"
        private const val LIB = "libvulkan_virtio.so"
        private const val ICD = "virtio_icd.json"

        /** Venus is the session's only way to a GPU where there is no KGSL. */
        @JvmStatic
        fun wanted(context: Context): Boolean = !DeviceSupport.adreno()

        @JvmStatic
        fun socket(context: Context): File = File(File(context.filesDir, DIR), "vtest.sock")

        /** What the guest needs to find the ICD and the server. */
        @JvmStatic
        fun guestEnv(context: Context): List<String> {
            val dir = File(context.filesDir, DIR)
            return listOf(
                "VK_ICD_FILENAMES=" + File(dir, ICD).path,
                "VN_DEBUG=vtest",
                "VTEST_SOCKET_NAME=" + socket(context).path,
            )
        }

        /** Copies the ICD out of the APK when it changed, and writes its manifest with an absolute path. */
        private fun stageIcd(context: Context) {
            val dir = File(context.filesDir, DIR).apply { mkdirs() }
            val lib = File(dir, LIB)
            // Copied again after every app update: the asset is compressed, so its size is unknown up front.
            val installed = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime
            if (!lib.isFile || lib.lastModified() < installed) {
                val tmp = File(dir, "$LIB.tmp")
                context.assets.open(ASSET).use { input -> tmp.outputStream().use { input.copyTo(it) } }
                if (!tmp.renameTo(lib)) Log.e(TAG, "could not move the Venus ICD into place")
                Log.i(TAG, "staged $lib (${lib.length()} bytes)")
            }
            FileUtils.writeString(
                File(dir, ICD),
                """{"file_format_version":"1.0.1","ICD":{"library_path":"${lib.path}","api_version":"1.4.354"}}""",
            )
        }
    }
}
