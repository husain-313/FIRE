import SwiftUI

// The subscriptions on this device: a tap switches to one, a swipe edits or deletes it.
struct SubscriptionsList: View {
    private struct Editing: Identifiable {
        let id = UUID()
        let account: Account?
    }

    @EnvironmentObject private var app: AppState
    @State private var list = Account.list
    @State private var editing: Editing?
    @State private var deleting: Account?

    var body: some View {
        List {
            ForEach(list) { a in
                Button {
                    if a.id != app.account?.id { app.use(a) }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: a.id == app.account?.id ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(a.id == app.account?.id ? .fire : .soft)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.name).foregroundColor(.white).lineLimit(1)
                            Text(a.user).font(.footnote).foregroundColor(.soft).lineLimit(1)
                        }
                        Spacer()
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { deleting = a } label: { Label("Delete", systemImage: "trash") }
                    Button { editing = Editing(account: a) } label: { Label("Edit", systemImage: "pencil") }
                }
                .contextMenu {
                    Button { editing = Editing(account: a) } label: { Label("Edit Subscription", systemImage: "pencil") }
                    Button(role: .destructive) { deleting = a } label: { Label("Delete", systemImage: "trash") }
                }
            }
            Button { editing = Editing(account: nil) } label: {
                Label("Add Subscription", systemImage: "plus.circle.fill").foregroundColor(.fire)
            }
        }
        .navigationTitle("Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing, onDismiss: { list = Account.list }) { e in
            SubscriptionForm(account: e.account)
        }
        .confirmationDialog("Delete \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let d = deleting { app.delete(d) }
                list = Account.list
                deleting = nil
            }
        } message: {
            Text("Its favourites and Continue Watching on this device go with it.")
        }
    }
}

// Add (account == nil) or edit. The login is tried on the server before it is saved.
struct SubscriptionForm: View {
    let account: Account?
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var link = ""
    @State private var user = ""
    @State private var pass = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (optional)", text: $name)
                    TextField("Server or M3U link", text: $link)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Username", text: $user)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $pass)
                } footer: {
                    Text("Paste a whole M3U link and the username and password fill themselves. Your subscriptions stay on this device only.")
                }
                if let error {
                    Section { Text(error).foregroundColor(.red.opacity(0.9)) }
                }
            }
            .navigationTitle(account == nil ? "Add Subscription" : "Edit Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Save", action: save) }
                }
            }
            .onAppear {
                guard let a = account, link.isEmpty else { return }
                name = a.name
                link = a.server
                user = a.user
                pass = a.pass
            }
        }
    }

    private func save() {
        guard let p = Account.parse(link) else { error = "That doesn't look like a server link."; return }
        // A pasted M3U link fills the fields left empty.
        if user.isEmpty, let u = p.user { user = u }
        if pass.isEmpty, let w = p.pass { pass = w }
        let u = user.trimmingCharacters(in: .whitespaces), w = pass.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, !w.isEmpty else { error = "The username and password are needed."; return }
        let n = name.trimmingCharacters(in: .whitespaces)
        let shown = n.isEmpty ? (URLComponents(string: p.server)?.host ?? p.server) : n
        let id = account?.id ?? String(UUID().uuidString.prefix(8)).lowercased()
        let a = Account(id: id, name: shown, server: p.server, user: u, pass: w)
        busy = true
        error = nil
        Task { @MainActor in
            let problem = await Api.check(a)
            busy = false
            if let problem { error = problem; return }
            Account.put(a)
            dismiss()
            // A new one, or new details for the one in use, start fresh on it.
            if account == nil || account?.id == app.account?.id { app.use(a) }
        }
    }
}
