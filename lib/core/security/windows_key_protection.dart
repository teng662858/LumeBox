import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

final class _Blob extends Struct {
  @Uint32()
  external int length;
  external Pointer<Uint8> bytes;
}

typedef _ProtectNative = Int32 Function(
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Uint32,
  Pointer<_Blob>,
);
typedef _ProtectDart = int Function(
  Pointer<_Blob>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  Pointer<Void>,
  int,
  Pointer<_Blob>,
);

/// Windows DPAPI binds the local master key to the signed-in OS account.
class WindowsKeyProtection {
  static Uint8List protect(Uint8List bytes) => _run(bytes, 'CryptProtectData');
  static Uint8List unprotect(Uint8List bytes) =>
      _run(bytes, 'CryptUnprotectData');
  static Uint8List _run(Uint8List bytes, String name) {
    final input = calloc<_Blob>();
    final output = calloc<_Blob>();
    final data = calloc<Uint8>(bytes.length);
    data.asTypedList(bytes.length).setAll(0, bytes);
    input.ref
      ..length = bytes.length
      ..bytes = data;
    try {
      final fn = DynamicLibrary.open('crypt32.dll')
          .lookupFunction<_ProtectNative, _ProtectDart>(name);
      if (fn(input, nullptr, nullptr, nullptr, nullptr, 1, output) == 0) {
        throw StateError('Windows 安全存储不可用');
      }
      return Uint8List.fromList(
        output.ref.bytes.asTypedList(output.ref.length),
      );
    } finally {
      if (output.ref.bytes != nullptr) {
        DynamicLibrary.open('kernel32.dll').lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree')(output.ref.bytes.cast());
      }
      calloc.free(data);
      calloc.free(input);
      calloc.free(output);
    }
  }
}
