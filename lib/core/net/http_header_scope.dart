/// Headers supplied for one origin must not be inherited by another.
bool isOriginBoundHttpHeader(String name) => const {
  'authorization',
  'cookie',
  'host',
  'proxy-authorization',
}.contains(name.toLowerCase());

/// Media transports own the connection, selected byte range and cache state.
/// A captured browser request can contain conditions for bytes only it has.
bool isMediaTransportHeader(String name) => const {
  'host',
  'connection',
  'content-length',
  'accept-encoding',
  'range',
  'if-range',
  'if-none-match',
  'if-modified-since',
}.contains(name.toLowerCase());
