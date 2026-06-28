// Copyright 2026 RTFM. All rights reserved.
// Use of this source code is governed by an Apache-2.0 license that can be
// found in the LICENSE file.

/// Represents the structured response wrapper returned by an API execution.
///
/// This class acts as a container for payloads and error states, ensuring
/// that the synchronization pipeline consistently processes data as a [List].
///
/// ### Examples
///
/// **Using with `http` package:**
///
/// Returning a collection (list):
/// ```dart
/// final http.Response res = await http.get(Uri.parse('https://api.example.com/users'));
/// return FluentApiResponse.list(
///   data: (jsonDecode(res.body) as List).map((e) => User.fromJson(e)).toList(),
///   statusCode: res.statusCode,
/// );
/// ```
///
/// Returning a single entity:
/// ```dart
/// final http.Response res = await http.get(Uri.parse('https://api.example.com/users/1'));
/// return FluentApiResponse.single(
///   data: User.fromJson(jsonDecode(res.body)),
///   statusCode: res.statusCode,
/// );
/// ```
///
/// **Using with `dio` package:**
///
/// Returning a collection (list):
/// ```dart
/// final Response res = await dio.get('/users');
/// return FluentApiResponse.list(
///   data: (res.data as List).map((e) => User.fromJson(e)).toList(),
///   statusCode: res.statusCode ?? 200,
/// );
/// ```
///
/// Returning a single entity:
/// ```dart
/// final Response res = await dio.get('/users/1');
/// return FluentApiResponse.single(
///   data: User.fromJson(res.data),
///   statusCode: res.statusCode ?? 200,
/// );
/// ```
class FluentApiResponse<T> {
  /// The list of entities successfully retrieved from the API.
  /// Is null if the request failed or resulted in an empty collection.
  final List<T>? data;

  /// The HTTP status code returned by the server (e.g., 200, 404, 500).
  final int statusCode;

  /// Any error detail encountered during the request.
  /// This may contain exception information or server-provided error messages.
  final Object? error;

  /// Creates a [FluentApiResponse].
  ///
  /// * [data]: The collection of items returned by the server.
  /// * [statusCode]: The status code of the HTTP response.
  /// * [error]: Optional error object if the request did not succeed.
  FluentApiResponse._({required this.data, required this.statusCode, required this.error});

  /// Wraps a single entity into a list response.
  /// ### Examples
  ///
  /// **Using with `http` package:**
  ///
  /// Returning a single entity:
  /// ```dart
  /// final http.Response res = await http.get(Uri.parse('https://api.example.com/users/1'));
  /// return FluentApiResponse.single(
  ///   data: User.fromJson(jsonDecode(res.body)),
  ///   statusCode: res.statusCode,
  /// );
  /// ```
  ///
  /// **Using with `dio` package:**
  ///
  /// Returning a single entity:
  /// ```dart
  /// final Response res = await dio.get('/users/1');
  /// return FluentApiResponse.single(
  ///   data: User.fromJson(res.data),
  ///   statusCode: res.statusCode ?? 200,
  /// );
  /// ```
  factory FluentApiResponse.single({required T? data, int statusCode = 200, Object? error}) => FluentApiResponse._(data: data != null ? <T>[data] : <T>[], statusCode: statusCode, error: error);

  /// Wraps a list of entities into a response.
  /// ### Examples
  ///
  /// **Using with `http` package:**
  ///
  /// Returning a collection (list):
  /// ```dart
  /// final http.Response res = await http.get(Uri.parse('https://api.example.com/users'));
  /// return FluentApiResponse.list(
  ///   data: (jsonDecode(res.body) as List).map((e) => User.fromJson(e)).toList(),
  ///   statusCode: res.statusCode,
  /// );
  /// ```
  ///
  /// **Using with `dio` package:**
  ///
  /// Returning a collection (list):
  /// ```dart
  /// final Response res = await dio.get('/users');
  /// return FluentApiResponse.list(
  ///   data: (res.data as List).map((e) => User.fromJson(e)).toList(),
  ///   statusCode: res.statusCode ?? 200,
  /// );
  /// ```
  factory FluentApiResponse.list({required List<T?>? data, int statusCode = 200, Object? error}) =>
      FluentApiResponse._(data: data?.whereType<T>().toList() ?? <T>[], statusCode: statusCode, error: error);
}
