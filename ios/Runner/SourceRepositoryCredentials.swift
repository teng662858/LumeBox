import Flutter
import Security

/// Device-only credential for the remote source repository. Never exported.
enum SourceRepositoryCredentials {
  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "lumebox/source_repository", binaryMessenger: messenger).setMethodCallHandler { call, result in
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "lumebox.source-repository", kSecAttrAccount as String: "github"]
      if call.method == "read" {
        var read = query; read[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &value)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          result(FlutterError(code: "keychain", message: "无法读取 GitHub 授权", details: nil)); return
        }
        result((value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "")
      } else if call.method == "write", let text = call.arguments as? String {
        var status: OSStatus
        if text.isEmpty { status = SecItemDelete(query as CFDictionary) }
        else {
          let data = Data(text.utf8)
          status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
          if status == errSecItemNotFound {
            var insert = query; insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(insert as CFDictionary, nil)
          }
        }
        guard status == errSecSuccess || (text.isEmpty && status == errSecItemNotFound) else {
          result(FlutterError(code: "keychain", message: "无法保存 GitHub 授权", details: nil)); return
        }
        result(nil)
      } else { result(FlutterMethodNotImplemented) }
    }
  }
}
