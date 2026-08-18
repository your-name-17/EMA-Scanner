import 'dart:convert';
import 'dart:html' as html;

const String _perpscopeBrowseQueueKey = 'perpscopeBrowseQueue';
const String _perpscopeBrowseQueueEvent = 'perpscope-browse-queue-updated';

void publishBrowseQueue(Map<String, dynamic> payload) {
  final encoded = jsonEncode(payload);
  html.window.localStorage[_perpscopeBrowseQueueKey] = encoded;
  html.window.dispatchEvent(
    html.CustomEvent(_perpscopeBrowseQueueEvent, detail: encoded),
  );
}

void clearPublishedBrowseQueue() {
  html.window.localStorage.remove(_perpscopeBrowseQueueKey);
  html.window.dispatchEvent(
    html.CustomEvent(_perpscopeBrowseQueueEvent, detail: ''),
  );
}
