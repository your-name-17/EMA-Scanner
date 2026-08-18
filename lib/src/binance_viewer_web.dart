import 'dart:html' as html;

Future<void> openBinanceViewerUrl(String url, {String? targetName}) async {
  html.window.open(url, targetName ?? 'perpscope_binance_viewer');
}
