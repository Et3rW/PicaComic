package com.github.pacalini.pica_comic

import android.os.Build
import android.view.KeyEvent
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Environment
import android.Manifest
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import java.io.File
import com.google.android.gms.common.GoogleApiAvailability

class MainActivity: FlutterFragmentActivity() {
    var volumeListen = VolumeListen()
    var listening = false


    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        GeneratedPluginRegistrant.registerWith(flutterEngine)

        val channel = EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.github.pacalini.pica_comic/volume")
        channel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    listening = true
                    volumeListen.whenUp = {
                        events.success(1)
                    }
                    volumeListen.whenDown = {
                        events.success(2)
                    }
                }
                override fun onCancel(arguments: Any?) {
                    listening = false
                }
        })
        //拦截屏幕截图
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/screenshot").setMethodCallHandler{
                _, _ ->
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/secure").setMethodCallHandler{
                _, _ ->
            window.setFlags(WindowManager.LayoutParams.FLAG_SECURE, WindowManager.LayoutParams.FLAG_SECURE)
        }
        //获取cpu架构
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/device").setMethodCallHandler{
                _, res ->
            res.success(getDeviceInfo())
        }
        //获取http代理
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/proxy").setMethodCallHandler{
                _, res ->
            res.success(getProxy())
        }
        //保持屏幕常亮
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"com.github.pacalini.pica_comic/keepScreenOn").setMethodCallHandler{
                call, _ ->
            if(call.method == "set")
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            else
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pica_comic/playServer").setMethodCallHandler{
                _, res ->
            val flag = GoogleApiAvailability.getInstance().isGooglePlayServicesAvailable(this) == com.google.android.gms.common.ConnectionResult.SUCCESS
            res.success(flag)
        }

        // Hands a downloaded update to the system installer. Without the
        // "install unknown apps" permission it opens that setting instead and
        // reports "permission", so the user can allow it and try again.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pica_comic/update").setMethodCallHandler{
                call, res ->
            if (call.method != "install") {
                res.notImplemented()
                return@setMethodCallHandler
            }
            try {
                val path = call.argument<String>("path")!!
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                    startActivity(Intent(
                        android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ))
                    res.success("permission")
                    return@setMethodCallHandler
                }
                val uri = FileProvider.getUriForFile(this, "$packageName.update_provider", File(path))
                val intent = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(uri, "application/vnd.android.package-archive")
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                res.success("started")
            } catch (e: Exception) {
                res.error("install", e.message, null)
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"pica_comic/settings").setMethodCallHandler{
                call, res ->
            if(call.method == "link") {
                val intent = Intent(
                    android.provider.Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS,
                    Uri.parse("package:$packageName"),
                )
                startActivity(intent)
                res.success(null)
            } else if(call.method == "files") {
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    Intent(android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION)
                } else {
                    Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                }
                intent.data = Uri.parse("package:$packageName")
                startActivity(intent)
                res.success(null)
            } else if(call.method == "files_check") {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    res.success(Environment.isExternalStorageManager())
                } else {
                    res.success(
                        ContextCompat.checkSelfPermission(this, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
                            && ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED)
                }
            }

        }
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if(listening){
            when (keyCode) {
                KeyEvent.KEYCODE_VOLUME_DOWN -> {
                    volumeListen.down()
                    return true
                }
                KeyEvent.KEYCODE_VOLUME_UP -> {
                    volumeListen.up()
                    return true
                }
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    private fun getDeviceInfo(): String{
        //获取cpu架构从而找到应当下载的app版本
        return Build.SUPPORTED_ABIS[0]
    }

    private fun getProxy(): String{
        val host = System.getProperty("http.proxyHost")
        val port = System.getProperty("http.proxyPort")
        return if(host!=null&&port!=null){
            "$host:$port"
        }else{
            "No Proxy"
        }
    }
}

class VolumeListen{
    var whenUp = fun() {}
    var whenDown = fun() {}
    fun up(){
        whenUp()
    }
    fun down(){
        whenDown()
    }
}
