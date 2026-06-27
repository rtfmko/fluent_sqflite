/// Represents the structured response wrapper returned by an API execution.
///
/// This class acts as a container for both successful payloads and error states,
/// decoupling the raw HTTP response from the synchronization pipeline logic.
///
/// ### Examples
///
/// Using with the **http** package:
/// ```dart
/// final Response response = await http.get(Uri.parse('https://api.example.com/users'));
/// final FluentApiResponse fluentResponse = FluentApiResponse<User>(
///   data: response.statusCode == 200 ? parseUsers(response.body) : null,
///   statusCode: response.statusCode,
///   error: response.statusCode != 200 ? response.reasonPhrase : null,
/// );
/// ```
///
/// Using with the **dio** package:
/// ```dart
/// try {
///   final Response response = await dio.get('/users');
///   return FluentApiResponse<User>(
///     data: (response.data as List).map((e) => User.fromJson(e)).toList(),
///     statusCode: response.statusCode ?? 200,
///   );
/// } on DioException catch (e) {
///   return FluentApiResponse<User>(
///     statusCode: e.response?.statusCode ?? 500,
///     error: e.error,
///   );
/// }
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
  FluentApiResponse({this.data, required this.statusCode, this.error});
}
