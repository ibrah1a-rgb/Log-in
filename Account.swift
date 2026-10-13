import Foundation
import Combine
import Security
import LocalAuthentication

struct AccountUser: Codable, Identifiable {
    let id: String
    let username: String
    let name: String
    let role: String
}
struct LoginResponse: Decodable { let token: String; let user: AccountUser }
struct MeResponse: Decodable { let user: AccountUser; let state: SavedState }
struct StateResponse: Decodable { let state: SavedState }
struct EmployeesResponse: Decodable { let employees: [AccountUser] }
struct OKResponse: Decodable { let ok: Bool }
struct ErrorResponse: Decodable { let error: String }
struct SavedSession: Codable { let server: String; let token: String }

enum AccountError: LocalizedError {
    case server(Int, String)
    var errorDescription: String? {
        switch self { case .server(_, let message): return message }
    }
}

// The session secret is protected by the currently enrolled biometrics, never UserDefaults.
enum BiometricVault {
    static let service = "ShopCheck.biometric-session"
    static let account = "current"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "biometricsEnabled") }
    static func remove() {
        SecItemDelete([kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                       kSecAttrAccount: account] as CFDictionary)
        UserDefaults.standard.set(false, forKey: "biometricsEnabled")
    }
    static func context() throws -> LAContext {
        let context = LAContext()
        context.localizedFallbackTitle = ""
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            throw AccountError.server(0, "فعّل Face ID أو Touch ID على جهازك، أو استخدم كلمة المرور.")
        }
        return context
    }
    static func save(_ session: SavedSession) async throws {
        let context = try context()
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                  localizedReason: "تفعيل الدخول السريع لحسابك") else { return }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil,
                  kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .biometryCurrentSet, &error) else {
            throw AccountError.server(0, "تعذر حماية جلسة الدخول على هذا الجهاز.")
        }
        let data = try JSONEncoder().encode(session)
        remove()
        let result = SecItemAdd([kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrAccessControl: access, kSecValueData: data] as CFDictionary, nil)
        guard result == errSecSuccess else { throw AccountError.server(0, "تعذر حفظ الدخول السريع.") }
        UserDefaults.standard.set(true, forKey: "biometricsEnabled")
    }
    static func load() async throws -> SavedSession {
        let context = try context()
        guard try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                localizedReason: "الدخول إلى حساب الحضور والمبيعات") else {
            throw AccountError.server(0, "لم يكتمل التحقق. يمكنك الدخول بكلمة المرور.")
        }
        var item: CFTypeRef?
        let result = SecItemCopyMatching([kSecClass: kSecClassGenericPassword,
            kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
            kSecUseAuthenticationContext: context] as CFDictionary, &item)
        guard result == errSecSuccess, let data = item as? Data else {
            if result == errSecItemNotFound { remove() }
            throw AccountError.server(0, "الدخول السريع غير متاح. ادخل بكلمة المرور وأعد تفعيله.")
        }
        return try JSONDecoder().decode(SavedSession.self, from: data)
    }
}

final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor final class Account: ObservableObject {
    @Published var user: AccountUser?
    @Published var employees: [AccountUser] = []
    @Published var biometricEnabled = BiometricVault.enabled
    private var token: String?
    private var sessionVersion = 0
    private(set) var server = ""
    private let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        let version = sessionVersion
        guard let url = URL(string: server + path), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AccountError.server(0, "أدخل عنوان خدمة HTTPS الصحيحة من المدير.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await session.data(for: request)
        guard version == sessionVersion else { throw AccountError.server(0, "تم قفل الجلسة. أعد تسجيل الدخول.") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        guard (200..<300).contains(status) else {
            let message = (try? decoder.decode(ErrorResponse.self, from: data).error) ?? "تعذر الاتصال بالخدمة."
            if status == 401, token != nil {
                lock(); BiometricVault.remove(); biometricEnabled = false
            }
            throw AccountError.server(status, message)
        }
        return try decoder.decode(T.self, from: data)
    }
    func login(server: String, username: String, password: String) async throws -> SavedState {
        self.server = server.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        token = nil; user = nil
        let response: LoginResponse = try await request("/v1/login", method: "POST", body: ["username": username, "password": password])
        token = response.token
        BiometricVault.remove(); biometricEnabled = false
        UserDefaults.standard.set(self.server, forKey: "serverURL")
        return try await refresh()
    }
    func refresh() async throws -> SavedState {
        let response: MeResponse = try await request("/v1/me")
        user = response.user
        return response.state
    }
    func biometricLogin() async throws -> SavedState {
        let version = sessionVersion
        let saved = try await BiometricVault.load()
        guard version == sessionVersion else { throw AccountError.server(0, "أعد محاولة تسجيل الدخول.") }
        server = saved.server; token = saved.token
        return try await refresh()
    }
    func enableBiometrics() async throws {
        guard let token, user != nil else { return }
        try await BiometricVault.save(SavedSession(server: server, token: token))
        biometricEnabled = BiometricVault.enabled
    }
    func disableBiometrics() { BiometricVault.remove(); biometricEnabled = false }
    func lock() { sessionVersion += 1; token = nil; user = nil; employees = [] }
    func logout() async throws {
        let _: OKResponse = try await request("/v1/logout", method: "POST")
        disableBiometrics(); lock()
    }
    func loadEmployees() async throws {
        let response: EmployeesResponse = try await request("/v1/employees")
        employees = response.employees
    }
    func createEmployee(username: String, name: String, password: String) async throws {
        let response: EmployeesResponse = try await request("/v1/employees", method: "POST",
            body: ["username": username, "name": name, "password": password])
        employees = response.employees
    }
}
