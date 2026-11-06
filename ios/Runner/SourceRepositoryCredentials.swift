import Flutter
import Security

/// Device-only private subscription credentials and local storage key. Never exported.
enum SourceRepositoryCredentials {
  static func register(with messenger: FlutterBinaryMessenger) {
    FlutterMethodChannel(name: "lumebox/source_repository", binaryMessenger: messenger).setMethodCallHandler { call, result in
      if call.method == "storageKey" {
        let keyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: "lumebox.private-storage", kSecAttrAccount as String: "master-v1"]
        var read = keyQuery; read[kSecReturnData as String] = true
        var existing: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &existing)
        if status == errSecSuccess, let data = existing as? Data, data.count == 32 { result(data.base64EncodedString()); return }
        guard status == errSecItemNotFound else { result(FlutterError(code: "keychain", message: "无法读取私密存储密钥", details: nil)); return }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { result(FlutterError(code: "random", message: "无法生成安全密钥", details: nil)); return }
        let data = Data(bytes)
        var insert = keyQuery; insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { result(FlutterError(code: "keychain", message: "无法保存私密存储密钥", details: nil)); return }
        result(data.base64EncodedString()); return
      }
      let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "lumebox.private-subscription",
        kSecAttrAccount as String: "github"]
      if call.method == "privateRead" {
        var read = query; read[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &value)
        guard status == errSecSuccess || status == errSecItemNotFound else {
          result(FlutterError(code: "keychain", message: "无法读取 GitHub 授权", details: nil)); return
        }
        result((value as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? "")
      } else if call.method == "privateWrite", let text = call.arguments as? String {
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
