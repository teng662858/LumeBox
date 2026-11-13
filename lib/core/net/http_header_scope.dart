/// Headers supplied for one origin must not be inherited by another.
bool isOriginBoundHttpHeader(String name) => const {
  'authorization',
  'cookie',
  'host',
  'proxy-authorization',
}.contains(name.toLowerCase());
