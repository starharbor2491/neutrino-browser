// SPDX-License-Identifier: MPL-2.0
const checkbox = document.getElementById("nativecheckbox");
const status = document.getElementById("status");
const root = document.documentElement;

function showTheme(theme) {
  checkbox.checked = theme === "dark";
  root.dataset.neutrinoFixtureTheme = theme;
  status.textContent = `Saved theme: ${theme}.`;
}

function showError(error) {
  root.dataset.neutrinoFixtureError = String(error.message || error);
  status.textContent = `Fixture error: ${error.message || error}`;
}

chrome.storage.local.get({theme: "light"}).then(state => {
  showTheme(state.theme);
  checkbox.disabled = false;
  root.dataset.neutrinoFixtureOptionsState = "ready";
}, showError);

checkbox.addEventListener("change", () => {
  const theme = checkbox.checked ? "dark" : "light";
  root.dataset.neutrinoFixtureOptionsState = "saving";
  chrome.storage.local.set({theme}).then(() => {
    showTheme(theme);
    root.dataset.neutrinoFixtureOptionsState = "saved";
  }, showError);
});

chrome.storage.onChanged.addListener((changes, areaName) => {
  if (areaName === "local" && changes.theme) {
    showTheme(changes.theme.newValue ?? "light");
  }
});
