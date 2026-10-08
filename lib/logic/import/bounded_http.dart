import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

enum BoundedHttpFailure {
  invalidUrl,
  network,
  timeout,
  tooLarge,
  unsupportedType,

  /// The server asked to retry later (rate limit or temporary overload).
  busy,
}

class BoundedHttpException implements Exception {
  final BoundedHttpFailure failure;

  const BoundedHttpException(this.failure);

  @override
  String toString() => 'BoundedHttpException: ${failure.name}';
}

class BoundedHttpResponse {
  final Uint8List bytes;

  /// The final address after redirects.
  final Uri uri;
  final String? charset;

  const BoundedHttpResponse(this.bytes, this.uri, this.charset);
}

/// HTTP(S) only, with a host and without embedded credentials.
bool isFetchableHttpUri(Uri uri) =>
    const ['http', 'https'].contains(uri.scheme) &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    uri.toString().length <= 4096;

/// One user-requested GET with no cookies or credentials. A fresh client
/// prevents state carrying over between requests. Every redirect hop is
/// validated again (and against [allowUri] when given), the body is bounded
/// by [maxBytes] while streaming, and [timeout] covers the whole exchange.
Future<BoundedHttpResponse> boundedHttpGet(
  Uri initialUri, {
  required int maxBytes,
  required Duration timeout,
  required int maxRedirects,
  required String userAgent,
  required String accept,
  Set<String>? allowedMimeTypes,
  bool Function(Uri uri)? allowUri,
  HttpClient Function()? clientFactory,
}) async {
  void validate(Uri uri) {
    if (!isFetchableHttpUri(uri) || (allowUri != null && !allowUri(uri))) {
      throw const BoundedHttpException(BoundedHttpFailure.invalidUrl);
    }
  }

  validate(initialUri);
  if (maxBytes <= 0 || timeout <= Duration.zero || maxRedirects < 0) {
    throw ArgumentError('invalid HTTP limits');
  }
  final client = (clientFactory ?? HttpClient.new)();
  client.connectionTimeout = timeout;
  client.userAgent = userAgent;
  try {
    return await (() async {
      var uri = initialUri;
      for (var redirects = 0; ; redirects++) {
        validate(uri);
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptHeader, accept);
        final response = await request.close();
        if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null || redirects >= maxRedirects) {
            throw const BoundedHttpException(BoundedHttpFailure.network);
          }
          uri = uri.resolve(location);
          validate(uri);
          // Do not drain an unbounded redirect body before proceeding.
          await response.listen((_) {}).cancel();
          continue;
        }
        if (response.statusCode == HttpStatus.tooManyRequests ||
            response.statusCode == HttpStatus.serviceUnavailable) {
          throw const BoundedHttpException(BoundedHttpFailure.busy);
        }
        if (response.statusCode != HttpStatus.ok) {
          throw const BoundedHttpException(BoundedHttpFailure.network);
        }
        final contentType = response.headers.contentType;
        final mime = contentType?.mimeType;
        if (allowedMimeTypes != null &&
            mime != null &&
            !allowedMimeTypes.contains(mime)) {
          throw const BoundedHttpException(BoundedHttpFailure.unsupportedType);
        }
        if (response.contentLength > maxBytes) {
          throw const BoundedHttpException(BoundedHttpFailure.tooLarge);
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const BoundedHttpException(BoundedHttpFailure.tooLarge);
          }
          bytes.add(chunk);
        }
        return BoundedHttpResponse(
          bytes.takeBytes(),
          uri,
          contentType?.charset,
        );
      }
    })().timeout(timeout);
  } on TimeoutException {
    throw const BoundedHttpException(BoundedHttpFailure.timeout);
  } on BoundedHttpException {
    rethrow;
  } on FormatException {
    throw const BoundedHttpException(BoundedHttpFailure.invalidUrl);
  } on IOException {
    throw const BoundedHttpException(BoundedHttpFailure.network);
  } finally {
    client.close(force: true);
  }
}
