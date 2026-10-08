import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:html/parser.dart' as html_parser;

import '../../models/recipe_image.dart';
import 'bounded_http.dart';

const recipePhotoProvider = 'Wikimedia Commons';
const maxRecipePhotoSearchResults = 12;
const maxRecipePhotoQueryLength = 100;
const maxRecipePhotoResponseBytes = 1024 * 1024;

/// Previews are scaled by the provider, so a found photo stays small within
/// the shared local photo budget.
const maxRecipePhotoBytes = 2 * 1024 * 1024;
const recipePhotoPreviewWidth = 800;

final defaultRecipePhotoEndpoint = Uri.parse(
  'https://commons.wikimedia.org/w/api.php',
);
const defaultRecipePhotoHosts = {
  'commons.wikimedia.org',
  'thumb.wikimedia.org',
  'upload.wikimedia.org',
};

enum RecipePhotoSearchFailure {
  network,

  /// Wikimedia asked to retry later, for example after many searches.
  busy,
  timeout,
  tooLarge,
  invalidResponse,
  unsupportedImage,
}

class RecipePhotoSearchException implements Exception {
  final RecipePhotoSearchFailure failure;

  const RecipePhotoSearchException(this.failure);

  @override
  String toString() => 'RecipePhotoSearchException: ${failure.name}';
}

/// A freely licensed photo that may (or may not) show the dish.
class RecipePhotoCandidate {
  final Uri imageUrl;
  final RecipeImageCredit credit;

  const RecipePhotoCandidate({required this.imageUrl, required this.credit});
}

/// Collapses whitespace and bounds the length; empty means "do not search".
String normalizeRecipePhotoQuery(String query) {
  final text = query.replaceAll(RegExp(r'\s+'), ' ').trim();
  return text.length > maxRecipePhotoQueryLength
      ? text.substring(0, maxRecipePhotoQueryLength).trimRight()
      : text;
}

/// Searches Wikimedia Commons for freely licensed photos. Only the search
/// words are sent, never profile or cookbook data. Requests happen only when
/// the owner starts a search, and every request (including redirects) is
/// limited to the provider's hosts over the endpoint's scheme.
class RecipePhotoSearch {
  final Uri endpoint;
  final Set<String> allowedHosts;
  final Duration timeout;
  final int maxResponseBytes;
  final int maxImageBytes;
  final int maxRedirects;
  final HttpClient Function()? clientFactory;

  RecipePhotoSearch({
    Uri? endpoint,
    this.allowedHosts = defaultRecipePhotoHosts,
    this.timeout = const Duration(seconds: 20),
    this.maxResponseBytes = maxRecipePhotoResponseBytes,
    this.maxImageBytes = maxRecipePhotoBytes,
    this.maxRedirects = 3,
    this.clientFactory,
  }) : endpoint = endpoint ?? defaultRecipePhotoEndpoint;

  static const _userAgent =
      'MorphCook/1.0 (https://github.com/TheMorpheus407/morphcook-refined; '
      'user-requested recipe photo search)';

  bool isAllowed(Uri uri) =>
      uri.scheme == endpoint.scheme && allowedHosts.contains(uri.host);

  Future<List<RecipePhotoCandidate>> search(
    String query, {
    String lang = 'en',
  }) async {
    final words = normalizeRecipePhotoQuery(query);
    if (words.isEmpty) return const [];
    final uri = endpoint.replace(
      queryParameters: {
        'action': 'query',
        'format': 'json',
        'formatversion': '2',
        'generator': 'search',
        // Bitmap files only; drawings, diagrams and audio are not photos.
        'gsrsearch': '$words filetype:bitmap',
        'gsrnamespace': '6',
        'gsrlimit': '$maxRecipePhotoSearchResults',
        'prop': 'imageinfo',
        'iiprop': 'url|mime|extmetadata',
        'iiurlwidth': '$recipePhotoPreviewWidth',
        'iiextmetadatafilter': 'Artist|LicenseShortName|ObjectName',
        'iiextmetadatalanguage': lang == 'de' ? 'de' : 'en',
      },
    );
    final response = await _get(
      uri,
      maxBytes: maxResponseBytes,
      accept: 'application/json',
      allowedMimeTypes: const {'application/json'},
    );
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bytes));
    } on FormatException {
      throw const RecipePhotoSearchException(
        RecipePhotoSearchFailure.invalidResponse,
      );
    }
    return parseRecipePhotoSearch(decoded, allowImage: isAllowed);
  }

  /// Downloads and validates a candidate's preview. The bytes enter private
  /// storage only when the owner chooses this photo.
  Future<Uint8List> download(RecipePhotoCandidate candidate) async {
    final response = await _get(
      candidate.imageUrl,
      maxBytes: maxImageBytes,
      accept: 'image/jpeg,image/png,image/webp',
    );
    try {
      RecipeImage(
        recipeId: 'photo-search',
        bytes: response.bytes,
        updatedAt: DateTime.now(),
      );
    } on RecipeImageException {
      throw const RecipePhotoSearchException(
        RecipePhotoSearchFailure.unsupportedImage,
      );
    }
    return response.bytes;
  }

  Future<BoundedHttpResponse> _get(
    Uri uri, {
    required int maxBytes,
    required String accept,
    Set<String>? allowedMimeTypes,
  }) async {
    try {
      return await boundedHttpGet(
        uri,
        maxBytes: maxBytes,
        timeout: timeout,
        maxRedirects: maxRedirects,
        userAgent: _userAgent,
        accept: accept,
        allowedMimeTypes: allowedMimeTypes,
        allowUri: isAllowed,
        clientFactory: clientFactory,
      );
    } on BoundedHttpException catch (error) {
      throw RecipePhotoSearchException(switch (error.failure) {
        BoundedHttpFailure.timeout => RecipePhotoSearchFailure.timeout,
        BoundedHttpFailure.busy => RecipePhotoSearchFailure.busy,
        BoundedHttpFailure.tooLarge => RecipePhotoSearchFailure.tooLarge,
        BoundedHttpFailure.unsupportedType =>
          RecipePhotoSearchFailure.invalidResponse,
        BoundedHttpFailure.invalidUrl ||
        BoundedHttpFailure.network => RecipePhotoSearchFailure.network,
      });
    }
  }
}

const _supportedPhotoMimeTypes = {'image/jpeg', 'image/png', 'image/webp'};
// Explicit supported metadata labels, without guessing at unknown terms.
final _supportedPhotoLicense = RegExp(
  r'^(?:CC BY(?:-SA)? (?:1\.0|2\.0|2\.5|3\.0|4\.0)|CC0(?: 1\.0)?)$',
);

/// Reads a MediaWiki `formatversion=2` image search response. Results without
/// an author, supported license metadata, a Commons source page or an allowed
/// HTTPS preview are left out, so every new candidate can be credited.
List<RecipePhotoCandidate> parseRecipePhotoSearch(
  Object? decoded, {
  required bool Function(Uri uri) allowImage,
}) {
  if (decoded is! Map<String, dynamic> || decoded['error'] != null) {
    throw const RecipePhotoSearchException(
      RecipePhotoSearchFailure.invalidResponse,
    );
  }
  final query = decoded['query'];
  // A search without matches has no `query` section at all.
  if (query == null) return const [];
  final pages = query is Map<String, dynamic> ? query['pages'] : null;
  if (pages is! List) {
    throw const RecipePhotoSearchException(
      RecipePhotoSearchFailure.invalidResponse,
    );
  }
  final ranked = <(int, RecipePhotoCandidate)>[];
  final seen = <Uri>{};
  for (final (position, page) in pages.indexed) {
    if (page is! Map<String, dynamic>) continue;
    final infos = page['imageinfo'];
    if (infos is! List || infos.isEmpty) continue;
    final info = infos.first;
    if (info is! Map<String, dynamic>) continue;
    if (!_supportedPhotoMimeTypes.contains(info['mime'])) continue;
    final preview = info['thumburl'] ?? info['url'];
    final source = info['descriptionurl'];
    if (preview is! String || source is! String) continue;
    final imageUrl = _withoutCampaignParameters(Uri.tryParse(preview));
    if (imageUrl == null ||
        !isFetchableHttpUri(imageUrl) ||
        !allowImage(imageUrl)) {
      continue;
    }
    final metadata = info['extmetadata'];
    final fields = metadata is Map<String, dynamic>
        ? metadata
        : const <String, dynamic>{};
    final author = _metadataText(fields['Artist']);
    final license = _metadataText(fields['LicenseShortName']);
    final sourceUrl = _withoutCampaignParameters(Uri.tryParse(source));
    if (author == null ||
        license == null ||
        !_supportedPhotoLicense.hasMatch(license) ||
        sourceUrl == null ||
        sourceUrl.scheme != 'https' ||
        sourceUrl.host != 'commons.wikimedia.org' ||
        !sourceUrl.path.startsWith('/wiki/File:')) {
      continue;
    }
    final title = page['title'];
    final credit = RecipeImageCredit.tryCreate(
      title:
          _metadataText(fields['ObjectName']) ??
          (title is String ? title.replaceFirst(RegExp('^File:'), '') : ''),
      author: author,
      license: license,
      provider: recipePhotoProvider,
      sourceUrl: sourceUrl.toString(),
    );
    if (credit == null || !seen.add(imageUrl)) continue;
    final index = page['index'];
    ranked.add((
      index is int ? index : position,
      RecipePhotoCandidate(imageUrl: imageUrl, credit: credit),
    ));
  }
  // Generator results are unordered; `index` holds the search ranking.
  ranked.sort((a, b) => a.$1.compareTo(b.$1));
  return [
    for (final (_, candidate) in ranked.take(maxRecipePhotoSearchResults))
      candidate,
  ];
}

/// The API tags its links with `utm_*` campaign parameters. They are not
/// needed to load a file, so they are not sent with the owner's request.
Uri? _withoutCampaignParameters(Uri? uri) {
  if (uri == null || !uri.hasQuery) return uri;
  // Keep the remaining parameters exactly as encoded by the provider.
  final kept = uri.query
      .split('&')
      .where((part) => part.isNotEmpty && !part.startsWith('utm_'))
      .join('&');
  final text = uri.removeFragment().toString();
  final base = text.substring(0, text.indexOf('?'));
  return Uri.tryParse(kept.isEmpty ? base : '$base?$kept');
}

/// Extended metadata values may contain HTML links; keep only their text.
String? _metadataText(Object? field) {
  final value = field is Map<String, dynamic> ? field['value'] : null;
  if (value is! String || value.length > 10000) return null;
  final text = (html_parser.parseFragment(value).text ?? '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return text.isEmpty ? null : text;
}
