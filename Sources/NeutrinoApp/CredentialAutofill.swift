// SPDX-License-Identifier: MPL-2.0
import Foundation

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
