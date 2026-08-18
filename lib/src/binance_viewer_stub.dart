import 'package:url_launcher/url_launcher.dart' show LaunchMode, launchUrl;

Future<void> openBinanceViewerUrl(String url, {String? targetName}) async {
  await launchUrl(
    Uri.parse(url),
    mode: LaunchMode.externalApplication,
  );
}
