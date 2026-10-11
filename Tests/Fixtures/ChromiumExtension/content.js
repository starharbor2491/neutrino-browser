// SPDX-License-Identifier: MPL-2.0
(() => {
  const root = document.documentElement;
  if (root.dataset.neutrinoFixtureContent === "ready") return;
  root.dataset.neutrinoFixtureContent = "ready";
  root.dataset.neutrinoFixtureExtensionId = chrome.runtime.id;
  root.dataset.neutrinoFixtureWorker = "pending";

  function reportError(error) {
    root.dataset.neutrinoFixtureError = String(error.message || error);
  }

  function reflectStorage(state) {
    root.dataset.neutrinoFixtureCount = String(state.pingCount ?? 0);
    root.dataset.neutrinoFixtureActionOpened = String(state.actionOpened ?? 0);
    root.dataset.neutrinoFixtureSidePanelOpened = String(state.sidePanelOpened ?? 0);
    root.dataset.neutrinoFixtureTheme = state.theme ?? "light";
  }

  async function refreshStorage() {
    reflectStorage(await chrome.storage.local.get([
      "pingCount", "actionOpened", "sidePanelOpened", "theme"
    ]));
  }

  async function command(name) {
    const response = await chrome.runtime.sendMessage({
      source: "neutrino-fixture", command: name
    });
    if (!response?.ok) throw new Error(response?.error || "No worker response");
    return response;
  }

  const controls = document.createElement("section");
  controls.id = "neutrino-fixture-controls";
  controls.setAttribute("aria-label", "Neutrino extension test controls");
  controls.style.cssText = "position:fixed;bottom:12px;right:12px;z-index:2147483647;" +
      "display:flex;gap:8px;padding:12px;background:white;color:black;" +
      "border:1px solid #777;border-radius:6px;font:14px system-ui";

  function addButton(id, label, name, marker) {
    const button = document.createElement("button");
    button.id = id;
    button.type = "button";
    button.textContent = label;
    button.addEventListener("click", () => {
      root.dataset[marker] = "pending";
      // Do not await storage or any other work before forwarding the gesture.
      command(name).then(() => {
        root.dataset[marker] = "opened";
      }, error => {
        root.dataset[marker] = "error";
        reportError(error);
      });
    });
    controls.append(button);
  }

  addButton("neutrino-fixture-action", "Open fixture action", "openPopup",
      "neutrinoFixtureActionState");
  addButton("neutrino-fixture-sidepanel", "Open fixture side panel", "openSidePanel",
      "neutrinoFixtureSidePanelState");
  document.body.append(controls);

  chrome.storage.onChanged.addListener((_changes, areaName) => {
    if (areaName === "local") refreshStorage().catch(reportError);
  });

  refreshStorage().catch(reportError);
  command("ping").then(async response => {
    root.dataset.neutrinoFixtureManifestVersion = String(response.manifestVersion);
    root.dataset.neutrinoFixtureVersion = response.extensionVersion;
    await refreshStorage();
    root.dataset.neutrinoFixtureWorker = "ready";
  }, error => {
    root.dataset.neutrinoFixtureWorker = "error";
    reportError(error);
  }).catch(error => {
    root.dataset.neutrinoFixtureWorker = "error";
    reportError(error);
  });
})();
