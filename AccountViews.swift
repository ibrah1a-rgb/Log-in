import SwiftUI

struct RootView: View {
    @ObservedObject var store: Store
    @ObservedObject var account: Account
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if account.user?.role == "admin" { ManagerView(store: store, account: account) }
            else if account.user != nil { Home(store: store, account: account) }
            else { LoginView(store: store, account: account) }
        }
        .overlay {
            if scenePhase != .active {
                ZStack { Color(.systemBackground).ignoresSafeArea(); Label("حضور ومبيعات", systemImage: "lock.fill") }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { account.lock(); store.clearPrivateData() }
        }
        .onChange(of: account.user?.id) { _, identifier in
            if identifier == nil { store.clearPrivateData() }
        }
        .alert("حضور ومبيعات", isPresented: Binding(get: { !store.message.isEmpty }, set: { if !$0 { store.message = "" } })) {
            Button("تمام") { store.message = "" }
        } message: { Text(store.message) }
    }
}

struct LoginView: View {
    @ObservedObject var store: Store
    @ObservedObject var account: Account
    @AppStorage("serverURL") private var server = ""
    @State private var username = ""
    @State private var password = ""
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("أهلًا بك", systemImage: "storefront.fill").font(.title2)
                    Text("ادخل بالحساب اللي أنشأه لك المدير.")
                }
                Section("الدخول") {
                    TextField("اسم المستخدم", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("كلمة المرور", text: $password).textContentType(.password)
                    Button("تسجيل الدخول") {
                        let value = password
                        password = ""
                        store.run {
                            let state = try await account.login(server: server, username: username, password: value)
                            await store.signedIn(state)
                        }
                    }.disabled(username.isEmpty || password.isEmpty || server.isEmpty)
                    if account.biometricEnabled {
                        Button { store.run { await store.signedIn(try await account.biometricLogin()) } } label: {
                            Label("الدخول باستخدام Face ID / Touch ID", systemImage: "faceid")
                        }
                    }
                }
                Section("إعداد الاتصال لأول مرة") {
                    TextField("https://عنوان-خدمة-المحل", text: $server).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("يُزوّدك المدير بعنوان الخدمة بعد استضافتها. رابط GitHub ليس عنوان الخدمة.").font(.footnote)
                }
                Section { Text("لا يوجد تسجيل ذاتي. اطلب بيانات الحساب من المدير. فعّل Face ID من الإعدادات بعد أول دخول بكلمة المرور.").font(.footnote) }
            }.navigationTitle("تسجيل الدخول").disabled(store.busy)
        }
    }
}

struct AccountSettings: View {
    @ObservedObject var store: Store
    @ObservedObject var account: Account
    var body: some View {
        Section("حسابي") {
            Text(account.user?.name ?? "")
            if account.biometricEnabled {
                Button("إيقاف الدخول باستخدام Face ID / Touch ID") { account.disableBiometrics() }
            } else {
                Button("تفعيل Face ID / Touch ID") {
                    store.run {
                        try await account.enableBiometrics()
                        store.message = "تم تفعيل الدخول السريع على هذا الجهاز. عند انتهاء الجلسة ستحتاج كلمة المرور."
                    }
                }
            }
            Text("استخدم جهازك الشخصي. البصمة تتحقق من مالك الجهاز المسجّل فيه، ولا تُرسل صورة وجهك للمدير.").font(.footnote)
            Button("تسجيل الخروج من الحساب", role: .destructive) {
                store.run {
                    guard store.state.started == nil else { throw InputError.invalid("سجّل الانصراف قبل الخروج من الحساب.") }
                    try await account.logout()
                    store.stopNotifications()
                    store.clearPrivateData()
                }
            }
        }
    }
}

struct ManagerView: View {
    @ObservedObject var store: Store
    @ObservedObject var account: Account
    @State private var username = ""
    @State private var name = ""
    @State private var password = ""
    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    Section("إنشاء حساب موظف") {
                        TextField("اسم الموظف", text: $name)
                        TextField("اسم المستخدم بالإنجليزي", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        SecureField("كلمة المرور — 12 حرفًا على الأقل", text: $password).textContentType(.newPassword)
                        Button("إنشاء الحساب") {
                            let value = password
                            password = ""
                            store.run {
                                try await account.createEmployee(username: username, name: name, password: value)
                                name = ""; username = ""
                                store.message = "تم إنشاء حساب الموظف. سلّمه بيانات الدخول بشكل خاص."
                            }
                        }.disabled(name.isEmpty || username.isEmpty || password.count < 12)
                        Text("الحساب الجديد موظف فقط؛ لا تُمنح له صلاحيات المدير.").font(.footnote)
                    }
                    Section("الموظفون") {
                        Button("تحديث القائمة") { store.run { try await account.loadEmployees() } }
                        ForEach(account.employees) { user in
                            VStack(alignment: .leading) { Text(user.name); Text(user.username).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }.navigationTitle("إدارة الموظفين").disabled(store.busy)
                .task { store.run { try await account.loadEmployees() } }
            }.tabItem { Label("الموظفون", systemImage: "person.2") }
            NavigationStack {
                List {
                    Section {
                        Text("آخر 500 تسجيل من جميع الموظفين").font(.footnote)
                        Button("تحديث السجل") { store.run { try await store.refresh() } }
                    }
                    ForEach(store.state.entries) { entry in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(entry.employee) · \(entry.kind)").font(.headline)
                            if entry.kind == "بيع" {
                                Text("\(entry.product) × \(entry.quantity)")
                                Text((Double(entry.halalas) / 100).formatted(.currency(code: "SAR")))
                            }
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        }
                    }
                }.navigationTitle("الحضور والمبيعات")
            }.tabItem { Label("السجل", systemImage: "list.bullet.rectangle") }
            NavigationStack {
                Form { AccountSettings(store: store, account: account) }.navigationTitle("الإعدادات").disabled(store.busy)
            }.tabItem { Label("الإعدادات", systemImage: "gearshape") }
        }
    }
}
