import SwiftUI
import Combine
import CoreLocation
import UserNotifications

enum ShopLocation {
    static let name = "مجوهرات عبدالإله حمد الخيال"
    // Center of 7HP8JPJ7+5P, recovered from the supplied JPJ7+5P / Ad Dirah image.
    static let latitude = 24.6304375
    static let longitude = 46.7143125
}

struct Entry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var employee: String
    var kind: String
    var product = ""
    var quantity = 0
    var halalas = 0 // Total sale amount, not unit price.
}

struct SavedState: Codable {
    var employee = ""
    var started: Date?
    var entries: [Entry] = []
    var latitude: Double?
    var longitude: Double?
}

enum InputError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

// Prototype: local records only. A name is NOT an authenticated employee identity.
@MainActor final class Store: NSObject, ObservableObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    @Published var state = SavedState()
    @Published var message = ""
    @Published var busy = false
    private let center = UNUserNotificationCenter.current()
    private let location = CLLocationManager()
    private let file = URL.documentsDirectory.appendingPathComponent("shop-check.json")
    private var healthy = true

    override init() {
        super.init()
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
            }
        } catch {
            healthy = false
            message = "تعذر قراءة السجل. لن نكتب فوق الملف الموجود."
        }
        center.delegate = self
        location.delegate = self
    }

    func commit(_ next: SavedState) throws {
        guard healthy else { throw InputError.invalid("تعذر فتح السجل المحفوظ.") }
        try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtection])
        state = next
    }

    func permissions() async throws {
        guard try await center.requestAuthorization(options: [.alert, .sound, .badge]) else {
            throw InputError.invalid("فعّل الإشعارات من إعدادات الآيفون ثم أعد المحاولة.")
        }
    }

    func run(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { message = error.localizedDescription }
        }
    }

    func checkIn(name: String) async throws {
        guard state.started == nil else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw InputError.invalid("اكتب اسم الموظف.") }
        try await permissions()
        let content = UNMutableNotificationContent()
        content.title = "بعت شي؟"
        content.body = "افتح التطبيق وسجّل المنتج والكمية والمبلغ، أو اختر ما بعت شي."
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "sales", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1800, repeats: true)))
        var next = state
        next.employee = name
        next.started = Date()
        next.entries.insert(Entry(employee: name, kind: "حضور"), at: 0)
        do { try commit(next) } catch {
            center.removePendingNotificationRequests(withIdentifiers: ["sales"])
            throw error
        }
        center.removePendingNotificationRequests(withIdentifiers: ["arrival"])
        message = "تم تسجيل حضورك. تذكير المبيعات كل نصف ساعة حتى تسجّل الانصراف."
    }

    func checkOut() async throws {
        guard state.started != nil else { return }
        var next = state
        next.started = nil
        next.entries.insert(Entry(employee: state.employee, kind: "انصراف"), at: 0)
        try commit(next)
        center.removePendingNotificationRequests(withIdentifiers: ["sales"])
        center.removeDeliveredNotifications(withIdentifiers: ["sales"])
        message = "تم تسجيل الانصراف وإيقاف تذكير المبيعات."
        if state.latitude != nil { try await scheduleArrival() }
    }

    static func normalized(_ raw: String) -> String {
        String(raw.map { char in
            if let digit = char.wholeNumberValue { return Character(String(digit)) }
            return char == "٫" ? "." : char
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sale(product: String, quantity: String, total: String, none: Bool = false) throws {
        guard state.started != nil else { throw InputError.invalid("سجّل حضورك أولًا.") }
        var entry = Entry(employee: state.employee, kind: none ? "ما بعت شي" : "بيع")
        if !none {
            let product = product.trimmingCharacters(in: .whitespacesAndNewlines)
            let raw = Self.normalized(total)
            guard !product.isEmpty, let qty = Int(Self.normalized(quantity)), qty > 0, qty <= 100000,
                  raw.range(of: "^[0-9]+(\\.[0-9]{1,2})?$", options: .regularExpression) != nil,
                  let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")),
                  amount > 0, amount <= 10000000 else {
                throw InputError.invalid("أدخل المنتج، كمية صحيحة موجبة، وإجماليًا موجبًا بمنزلتين عشريتين كحد أقصى.")
            }
            entry.product = product
            entry.quantity = qty
            entry.halalas = NSDecimalNumber(decimal: amount * 100).intValue
        }
        var next = state
        next.entries.insert(entry, at: 0)
        try commit(next)
        message = "تم حفظ التسجيل."
    }

    func configure(lat: String, lon: String) async throws {
        guard let lat = Double(Self.normalized(lat)), let lon = Double(Self.normalized(lon)),
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            throw InputError.invalid("أدخل إحداثيات المحل الصحيحة.")
        }
        try await permissions()
        var next = state
        next.latitude = lat; next.longitude = lon
        try commit(next)
        if location.authorizationStatus == .notDetermined {
            message = "اسمح باستخدام الموقع لتنبيه الوصول."
            location.requestWhenInUseAuthorization()
        } else {
            try await scheduleArrival()
            message = "تم حفظ الموقع. تنبيه الوصول يعمل خارج الدوام."
        }
    }

    func scheduleArrival() async throws {
        guard state.started == nil, let lat = state.latitude, let lon = state.longitude else { return }
        guard location.authorizationStatus == .authorizedAlways || location.authorizationStatus == .authorizedWhenInUse else {
            throw InputError.invalid("فعّل إذن الموقع للتطبيق من إعدادات الآيفون.")
        }
        let region = CLCircularRegion(center: CLLocationCoordinate2D(latitude: lat, longitude: lon),
                                      radius: 150, identifier: "shop")
        region.notifyOnEntry = true; region.notifyOnExit = false
        let content = UNMutableNotificationContent()
        content.title = "وصلت المحل؟"
        content.body = "افتح التطبيق واضغط تسجيل الحضور لحفظ الوقت."
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: "arrival", content: content,
            trigger: UNLocationNotificationTrigger(region: region, repeats: true)))
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.state.latitude != nil else { return }
            do { try await self.scheduleArrival() } catch { self.message = error.localizedDescription }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main struct ShopCheckApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup { Home(store: store).environment(\.layoutDirection, .rightToLeft).tint(.teal) }
    }
}

struct Home: View {
    @ObservedObject var store: Store
    @State private var name = ""
    @State private var product = ""
    @State private var quantity = "1"
    @State private var total = ""
    @State private var lat = ""
    @State private var lon = ""
    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    Section("دوامي") {
                        if let start = store.state.started {
                            Label(store.state.employee, systemImage: "person.fill.checkmark")
                            Text("وقت الحضور: \(start.formatted(date: .abbreviated, time: .shortened))")
                            Button("تسجيل الانصراف", role: .destructive) { store.run { try await store.checkOut() } }
                        } else {
                            TextField("اسم الموظف — للتجربة", text: $name)
                            Button("تسجيل الحضور") { store.run { try await store.checkIn(name: name) } }
                        }
                    }
                    if store.state.started != nil {
                        Section("وش بعت؟") {
                            TextField("اسم المنتج", text: $product)
                            TextField("الكمية", text: $quantity).keyboardType(.numberPad)
                            TextField("إجمالي البيع بالريال", text: $total).keyboardType(.decimalPad)
                            Button("حفظ البيع") {
                                store.run {
                                    try store.sale(product: product, quantity: quantity, total: total)
                                    product = ""; quantity = "1"; total = ""
                                }
                            }
                            Button("ما بعت شي") { store.run { try store.sale(product: "", quantity: "", total: "", none: true) } }
                        }
                    }
                    Section { Text("نسخة تجريبية محلية. البيانات محفوظة على هذا الجهاز فقط.").font(.footnote) }
                }.navigationTitle("حضور ومبيعات").disabled(store.busy)
            }.tabItem { Label("دوامي", systemImage: "storefront") }
            NavigationStack {
                List {
                    if store.state.entries.isEmpty { Text("ما فيه سجلات حتى الآن.") }
                    ForEach(store.state.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(entry.kind) · \(entry.employee)").font(.headline)
                            if entry.kind == "بيع" {
                                Text("\(entry.product) × \(entry.quantity)")
                                Text((Double(entry.halalas) / 100).formatted(.currency(code: "SAR")))
                            }
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.navigationTitle("سجل هذا الجهاز")
            }.tabItem { Label("السجل", systemImage: "list.bullet.rectangle") }
            NavigationStack {
                Form {
                    Section("موقع المحل") {
                        Text(ShopLocation.name).font(.headline)
                        Text("سوق الثميري للذهب · الديرة · الرياض").font(.caption)
                        Link("عرض موقع المحل على الخريطة", destination: URL(string: "https://www.google.com/maps/search/?api=1&query=24.6304375,46.7143125")!)
                        TextField("خط العرض Latitude", text: $lat).keyboardType(.numbersAndPunctuation)
                        TextField("خط الطول Longitude", text: $lon).keyboardType(.numbersAndPunctuation)
                        Button("حفظ وتفعيل تنبيه الوصول") { store.run { try await store.configure(lat: lat, lon: lon) } }
                        Text("تنبيه تقريبي عند دخول نطاق 150 مترًا؛ تأكيد الحضور يدوي. لا يجمع التطبيق سجل تحركاتك.").font(.footnote)
                    }
                    Section("الإشعارات") {
                        Text("كل 30 دقيقة من وقت تسجيل الحضور. سجّل الانصراف لإيقافها. قد يؤخر وضع التركيز ظهور الإشعارات.")
                        Button("فتح إعدادات التطبيق") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                }.navigationTitle("الإعدادات").disabled(store.busy)
            }.tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
        .onAppear {
            name = store.state.employee
            lat = String(store.state.latitude ?? ShopLocation.latitude)
            lon = String(store.state.longitude ?? ShopLocation.longitude)
        }
        .alert("حضور ومبيعات", isPresented: Binding(get: { !store.message.isEmpty }, set: { if !$0 { store.message = "" } })) {
            Button("تمام") { store.message = "" }
        } message: { Text(store.message) }
    }
}
