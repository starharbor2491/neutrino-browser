import NeutrinoCore
// SPDX-License-Identifier: MPL-2.0
import SwiftUI

struct PasswordsView: View {
  @ObservedObject var model: BrowserModel
  @Environment(\.browserTheme) private var theme
  @State private var records: [LocalCredential] = []
  @State private var website = ""
  @State private var username = ""
  @State private var password = ""
  @State private var status: String?
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text(
          "Saved in macOS Keychain for your \(model.profile.name) profile. Autofill requires your action and an exact match to the current website’s origin."
        ).font(.caption).foregroundStyle(.secondary)
        if model.isPrivate {
          Text("Saving and filling passwords is unavailable in private browsing.").font(.caption)
        } else {
          ForEach(records) { item in
            HStack {
              VStack(alignment: .leading, spacing: 5) {
                Text(item.origin).font(.system(size: 13, weight: .medium))
                Text(item.username).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button("Fill") { fill(item) }.buttonStyle(NeutrinoButtonStyle()).disabled(
                (try? model.selectedTab.url.map(LocalCredential.origin(for:))) != item.origin)
              IconButton(title: "Delete saved password", icon: "trash") {
                do {
                  try SecureVault.delete(
                    account: item.id, service: LocalCredential.service(model.profile.id))
                  reload()
                } catch { status = error.localizedDescription }
              }
            }.padding(14).background(theme.canvas, in: RoundedRectangle(cornerRadius: 12))
          }
          Text("Add a password").font(.headline).padding(.top, 10)
          field("https://example.com", text: $website)
          field("Username", text: $username)
          SecureField("Password", text: $password).textFieldStyle(.plain).padding(12).background(
            theme.canvas, in: RoundedRectangle(cornerRadius: 10))
          Button("Save password") {
            do {
              guard let url = URL(string: website) else {
                throw ValidationError("Enter a website URL.")
              }
              try LocalCredential(
                origin: LocalCredential.origin(for: url), username: username, password: password
              ).save(profile: model.profile.id)
              password = ""
              reload()
              status = "Password saved in Keychain."
            } catch { status = error.localizedDescription }
          }.buttonStyle(NeutrinoButtonStyle(prominent: true))
        }
        if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
      }
    }.onAppear {
      website = model.selectedTab.url?.absoluteString ?? ""
      reload()
    }
  }
  private func field(_ title: String, text: Binding<String>) -> some View {
    TextField(title, text: text).textFieldStyle(.plain).padding(12).background(
      theme.canvas, in: RoundedRectangle(cornerRadius: 10))
  }
  private func reload() {
    do { records = try LocalCredential.list(profile: model.profile.id) } catch {
      status = error.localizedDescription
    }
  }
  private func fill(_ credential: LocalCredential) {
    let tab = model.activeWebTab
    let revision = tab.navigationRevision
    Task { @MainActor in
      do {
        guard let url = tab.url, try LocalCredential.origin(for: url) == credential.origin else {
          throw ValidationError("This password belongs to a different website.")
        }
        try await tab.fillCredential(credential)
        guard tab.navigationRevision == revision else { return }
        status = "Filled the login fields. Review them before submitting."
      } catch { status = error.localizedDescription }
    }
  }
}
extension LocalCredential {
  var autofillScript: String {
    let data = try! JSONEncoder().encode(self)
    let json = String(decoding: data, as: UTF8.self)
    return """
      const credential = \(json);
      if (location.origin !== credential.origin) throw new Error('Website changed');
      const password = document.querySelector('input[type=password]');
      if (!password) throw new Error('No password field found');
      const form = password.form || document;
      const username = form.querySelector('input[autocomplete=username], input[type=email], input[name=username], input[type=text]');
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      const fill = (field, value) => { setter.call(field, value); field.dispatchEvent(new Event('input', {bubbles:true})); field.dispatchEvent(new Event('change', {bubbles:true})); };
      if (username) fill(username, credential.username);
      fill(password, credential.password);
      return true;
      """
  }
}
