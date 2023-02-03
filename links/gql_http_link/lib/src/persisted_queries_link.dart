// ignore_for_file: parameter_assignments
// ignore_for_file: implicit_dynamic_parameter

import "dart:async";
import "dart:convert";

import "package:crypto/crypto.dart";
import "package:gql/ast.dart";
import "package:gql/language.dart";
import "package:gql_exec/gql_exec.dart";
import "package:gql_http_link/gql_http_link.dart";
import "package:gql_link/gql_link.dart";

// ignore: constant_identifier_names
const VERSION = 1;

typedef QueryHashGenerator = String Function(DocumentNode query);

typedef ShouldDisablePersistedQueries = bool Function(
  Request request,
  Response response, [
  HttpLinkServerException exception,
]);

extension on Operation {
  bool get isQuery => isOfType(OperationType.query, document, operationName);
}

class PersistedQueriesLink extends Link {
  bool disabledDueToErrors = false;

  /// Adds a [HttpLinkMethod.get()] to context entry for hashed queries
  final bool useGETForHashedQueries;

  /// callback for hashing queries.
  ///
  /// Defaults to [defaultSha256Hash]
  final QueryHashGenerator getQueryHash;

  /// Called when [response] has errors to determine if the [PersistedQueriesLink] should be disabled
  ///
  /// Defaults to [defaultDisableOnError]
  final ShouldDisablePersistedQueries disableOnError;

  PersistedQueriesLink({
    this.useGETForHashedQueries = true,
    this.getQueryHash = defaultSha256Hash,
    this.disableOnError = defaultDisableOnError,
  }) : super();

  @override
  Stream<Response> request(
    Request request, [
    NextLink? forward,
  ]) {
    if (forward == null) {
      throw Exception(
        "PersistedQueryLink cannot be the last link in the chain.",
      );
    }

    final operation = request.operation;

    Object? hashError;
    if (!disabledDueToErrors) {
      try {
        final doc = request.operation.document;
        final hash = getQueryHash(doc);
        // TODO awkward to inject the hash with a thunk like this
        request = request.withContextEntry(
          RequestExtensionsThunk(
            (request) {
              assert(
                request.operation.document == doc,
                "Request document altered after PersistedQueriesLink: "
                "${printNode(request.operation.document)} != ${printNode(doc)}",
              );
              return {
                "persistedQuery": {
                  "sha256Hash": hash,
                  "version": VERSION,
                },
              };
            },
          ),
        );
      } catch (e) {
        hashError = e;
      }
    }

    StreamController<Response>? controller;

    Future<void> onListen() async {
      if (hashError != null) {
        return controller?.addError(hashError);
      }

      StreamSubscription? subscription;
      bool retried = false;
      final Request originalRequest = request;

      Function? retry;
      retry = ({
        Response? response,
        HttpLinkServerException? networkError,
        Function? callback,
      }) {
        if (!retried && (response?.errors != null || networkError != null)) {
          retried = true;

          if (response != null && networkError != null) {
            // TODO triple check that the original wholesale disables the link
            // if the server doesn't support persisted queries, don't try anymore
            disabledDueToErrors =
                disableOnError(request, response, networkError);
          }

          // if its not found, we can try it again, otherwise just report the error
          if (!includesNotSupportedError(response) || disabledDueToErrors) {
            // need to recall the link chain
            if (subscription != null) {
              subscription?.cancel();
            }

            // actually send the query this time
            final retryRequest = originalRequest.withContextEntry(
              RequestSerializationInclusions(
                operationName: request.operation.operationName != null,
                query: true,
                extensions: !disabledDueToErrors,
              ),
            );

            subscription = _attachListener(
              controller,
              forward(retryRequest),
              retry,
            );

            return;
          }
        }

        callback?.call();
      };

      // don't send the query the first time
      request = request.withContextEntry(
        RequestSerializationInclusions(
          operationName: request.operation.operationName != null,
          query: disabledDueToErrors,
          extensions: !disabledDueToErrors,
        ),
      );

      // If requested, set method to GET if there are no mutations. Remember the
      if (useGETForHashedQueries && !disabledDueToErrors && operation.isQuery) {
        request = request.withContextEntry(const HttpLinkMethod.get());
      }

      subscription = _attachListener(controller, forward(request), retry);
    }

    controller = StreamController<Response>(onListen: onListen);

    return controller.stream;
  }

  /// Default [getQueryHash] that `sha256` encodes the query document string
  static String defaultSha256Hash(DocumentNode query) =>
      sha256.convert(utf8.encode(printNode(query))).toString();

  /// Default [disableOnError].
  ///
  /// Disables the link if [includesNotSupportedError(response)] or if `statusCode` is in `{ 400, 500 }`
  static bool defaultDisableOnError(
    Request request,
    Response response, [
    HttpLinkServerException? exception,
  ]) {
    // if the server doesn't support persisted queries, don't try anymore
    if (includesNotSupportedError(response)) {
      return true;
    }

    // if the server responds with bad request
    // apollo-server responds with 400 for GET and 500 for POST when no query is found

    final HttpLinkResponseContext responseContext =
        response.context.entry() as HttpLinkResponseContext;

    return {400, 500}.contains(responseContext.statusCode);
  }

  static bool includesNotSupportedError(Response? response) {
    final errors = response?.errors ?? [];
    return errors.any(
      (err) => err.message == "PersistedQueryNotSupported",
    );
  }

  StreamSubscription _attachListener(
    StreamController<Response>? controller,
    Stream<Response> stream,
    Function? retry,
  ) =>
      stream.listen(
        (data) {
          if (retry != null) {
            retry(response: data, callback: () => controller?.add(data));
          }
        },
        onError: (err) {
          if (err is HttpLinkServerException) {
            if (retry != null) {
              retry(
                  networkError: err, callback: () => controller?.addError(err));
            }
          } else {
            // ignore: argument_type_not_assignable
            controller?.addError(err);
          }
        },
        onDone: () {
          controller?.close();
        },
        cancelOnError: true,
      );
}

List<OperationDefinitionNode> getOperationNodes(DocumentNode doc) {
  if (doc.definitions == null) return [];

  return doc.definitions.whereType<OperationDefinitionNode>().toList();
}

String? getLastOperationName(DocumentNode doc) {
  final operations = getOperationNodes(doc);

  if (operations.isEmpty) return null;

  return operations.last.name?.value;
}

bool isOfType(
  OperationType operationType,
  DocumentNode doc,
  String? operationName,
) {
  final operations = getOperationNodes(doc);

  if (operationName == null) {
    if (operations.length > 1) return false;

    return operations.any(
      (op) => op.type == operationType,
    );
  }

  return operations.any(
    (op) => op.name?.value == operationName && op.type == operationType,
  );
}
