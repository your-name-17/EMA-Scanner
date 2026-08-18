package com.example.perpscope

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
	private val CHANNEL = "perpscope/binance"

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
			.setMethodCallHandler { call, result ->
				if (call.method == "openBinance") {
					val symbol = call.argument<String>("symbol") ?: ""
					val mode = call.argument<String>("mode") ?: "futures"
					val url = if (mode == "futures") {
						"https://www.binance.com/en/futures/$symbol"
					} else {
						"https://www.binance.com/en/trade/$symbol?type=spot"
					}

					val started = tryOpenInBinanceApp(url)
					result.success(started)
				} else {
					result.notImplemented()
				}
			}
	}

	private fun tryOpenInBinanceApp(url: String): Boolean {
		val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
		intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

		val pm = this.packageManager

		try {
			// Build a candidate package list: installed packages that contain 'binance'
			val candidates = mutableListOf<String>()
			val apps: List<ApplicationInfo> = pm.getInstalledApplications(0)
			for (app in apps) {
				val pkg = app.packageName
				var added = false
				if (pkg.contains("binance", ignoreCase = true)) {
					candidates.add(pkg)
					added = true
				}
				// also check the application label (visible name), e.g. 币安
				try {
					val label = pm.getApplicationLabel(app).toString()
					if (!added && (label.contains("币安") || label.contains("Binance", ignoreCase = true))) {
						candidates.add(pkg)
					}
				} catch (e: Exception) {
					// ignore label retrieval issues
				}
			}

			// Try to open the URL with any package that might handle it
			for (pkg in candidates) {
				try {
					val it = Intent(Intent.ACTION_VIEW, Uri.parse(url))
					it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
					it.setPackage(pkg)
					startActivity(it)
					return true
				} catch (e: Exception) {
					// ignore and try next
				}
			}

			// If none of the packages handle the URL directly, try launching the app main activity for candidates
			for (pkg in candidates) {
				try {
					val launch = pm.getLaunchIntentForPackage(pkg)
					if (launch != null) {
						launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
						startActivity(launch)
						return true
					}
				} catch (e: Exception) {
					// continue
				}
			}

			// Try a few well-known Binance package names as a last resort
			val knownPkgs = listOf("com.binance.dev", "com.binance", "com.binance.android")
			for (pkg in knownPkgs) {
				try {
					val it = Intent(Intent.ACTION_VIEW, Uri.parse(url))
					it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
					it.setPackage(pkg)
					startActivity(it)
					return true
				} catch (e: Exception) {
					try {
						val launch = pm.getLaunchIntentForPackage(pkg)
						if (launch != null) {
							launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
							startActivity(launch)
							return true
						}
					} catch (_: Exception) {
					}
				}
			}

			// Fallback: open URL with whatever component can handle it (likely browser)
			try {
				startActivity(intent)
				return true
			} catch (e: Exception) {
				return false
			}
		} catch (e: Exception) {
			return false
		}
	}
}
