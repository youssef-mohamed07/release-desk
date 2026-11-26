import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'errors.dart';

const userAgent = 'ReleaseDesk/1.0';

/// Whether an exception from package:http is a transport problem worth a
/// retry (no answer at all, as opposed to an error answer).
bool isTransportError(Object e) => e is SocketException || e is http.ClientException || e is TimeoutException || e is HandshakeException || e is HttpException;

/// Sends [request] without following redirects; returns the response with
/// its body read.
Future<http.Response> sendNoRedirect(http.Client client, http.BaseRequest request) async {
  request.followRedirects = false;
  final streamed = await client.send(request).timeout(const Duration(seconds: 120));
  return http.Response.fromStream(streamed);
}

/// Follows one redirect by hand, without the Authorization header (GitHub
/// sends logs and artifacts through short-lived signed URLs that refuse it).
Future<http.Response> getFollowingRedirectWithoutAuth(http.Client client, Uri url, Map<String, String> headers) async {
  final first = http.Request('GET', url)..headers.addAll(headers);
  final r = await sendNoRedirect(client, first);
  if (r.statusCode >= 300 && r.statusCode < 400) {
    final location = r.headers['location'];
    if (location == null) throw ReleaseError.api(r.statusCode, url.toString(), ['Redirect without a location']);
    final next = http.Request('GET', url.resolve(location))..headers['User-Agent'] = userAgent;
    return sendNoRedirect(client, next);
  }
  return r;
}
