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
  /// Waits in Neutrino's isolated world until the person clicks a field of the login
  /// form, or presses Down Arrow in one, then fills it once. Page scripts can't send
  /// trusted events, so they can't make the saved password appear by themselves.
  var autofillOnUseScript: String {
    let data = try! JSONEncoder().encode(self)
    let json = String(decoding: data, as: UTF8.self)
    return """
      const credential = \(json);
      if (location.origin !== credential.origin || window.top !== window) return false;
      if (window.__neutrinoAutofill) return true;
      window.__neutrinoAutofill = true;
      const userFields = 'input[autocomplete=username], input[type=email], input[name=username], input[type=text]';
      const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      const fill = (field, value) => { setter.call(field, value); field.dispatchEvent(new Event('input', {bubbles:true})); field.dispatchEvent(new Event('change', {bubbles:true})); };
      const stop = () => { removeEventListener('pointerdown', use, true); removeEventListener('keydown', use, true); };
      function use(event) {
        if (!event.isTrusted || location.origin !== credential.origin) return;
        if (event.type === 'keydown' && event.key !== 'ArrowDown') return;
        const field = event.target;
        if (!(field instanceof HTMLInputElement)) return;
        const form = field.form || document;
        const password = form.querySelector('input[type=password]');
        if (!password || (field !== password && !field.matches(userFields))) return;
        stop();
        if (password.value) return;
        const username = form.querySelector(userFields);
        if (username && !username.value) fill(username, credential.username);
        fill(password, credential.password);
      }
      addEventListener('pointerdown', use, true);
      addEventListener('keydown', use, true);
      return true;
      """
  }
}
