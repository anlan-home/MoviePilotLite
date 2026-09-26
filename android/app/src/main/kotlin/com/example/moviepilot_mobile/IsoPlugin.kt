package com.example.moviepilot_mobile

import android.os.Build
import io.flutter.plugin.common.MethodChannel
import io.flutter.embedding.engine.plugins.FlutterPlugin

/**
 * ISO 原盘(BDMV ISO)原生直连插件。
 *
 * 通过 MethodChannel 调用 lanplayer_jni 的 libudfread 管线:
 * 解析远端 ISO 的 UDF 文件系统 → 定位 BDMV/STREAM 正片 m2ts
 * → 本地 127.0.0.1 服务以 Range 流暴露给播放内核。
 *
 * 线程注记:openIso 在原生层起独立服务线程,调用本身很快返回。
 */
class IsoPlugin : FlutterPlugin {
    companion object {
        private const val CHANNEL = "com.lanplayer/iso"

        init {
            try {
                System.loadLibrary("lanplayer_jni")
            } catch (e: UnsatisfiedLinkError) {
                // lanplayer_jni 不存在(未启用 CMake 构建)
            }
        }
    }

    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "openIso" -> {
                        val url = call.argument<String>("url") ?: ""
                        val size = (call.argument<Number>("size") as? Number)?.toLong() ?: 0L
                        result.success(IsoBridge.nativeOpenIso(url, size))
                    }
                    "closeIso" -> {
                        IsoBridge.nativeCloseIso()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }
}

/** JNI 桥(lanplayer_jni 内实现,ISO 原生直连)。 */
object IsoBridge {
    init {
        try {
            System.loadLibrary("lanplayer_jni")
        } catch (e: UnsatisfiedLinkError) {
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) {
            // 理论不可达(minSdk 24),防御性标注
        }
    }

    /** 打开 ISO 原盘并启动本地流服务;返回 127.0.0.1 播放地址,null=失败 */
    external fun nativeOpenIso(url: String, sizeBytes: Long): String?

    /** 释放原生直连资源 */
    external fun nativeCloseIso()
}
