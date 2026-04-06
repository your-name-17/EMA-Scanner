import 'dart:html' as html;

Future<void> initWebNotifications() async {
  if (!html.Notification.supported) return;
  if (html.Notification.permission != 'granted') {
    await html.Notification.requestPermission();
  }
}

Future<bool> webCanNotify() async {
  return html.Notification.supported &&
      html.Notification.permission == 'granted';
}

Future<void> showWebNotification(String title, String body) async {
  if (!html.Notification.supported) return;

  if (html.Notification.permission != 'granted') {
    final permission = await html.Notification.requestPermission();
    if (permission != 'granted') return;
  }

  html.Notification(title, body: body);
}
