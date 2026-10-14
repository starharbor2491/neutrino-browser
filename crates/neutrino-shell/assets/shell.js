// SPDX-License-Identifier: MPL-2.0
// DOM/platform adapter only. Rust owns rendering, validation and interaction state.
(() => {
  "use strict";
  const root = document.getElementById("app");
  let chain = Promise.resolve(),
    currentOverlay = false,
    currentEditing = false,
    generation = 0,
    drag = null,
    resize = null,
    adjustment = null,
    adjustmentSequence = 0,
    geometryFrame = 0,
    returnFocus = null,
    composition = false,
    currentContext = null,
    focusToken = null,
    commandRevision = null,
    menuAnchor = null,
    dialogPosition = null,
    dialogDrag = null,
    patching = false,
    feedbackTimer = null,
    feedbackMessage = "",
    wheelGesture = { sum: 0, last: 0, locked: false };
  const native = () => window.webkit?.messageHandlers?.neutrino;
  const textInputSelector =
    "textarea,input:not([type=range]):not([type=checkbox]):not([type=radio])";
  async function transport(message) {
    if (native()) return await native().postMessage(message);
    const r = await fetch("/dispatch", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(message),
    });
    if (!r.ok) throw Error("Connection unavailable");
    return await r.json();
  }
  function selector(el) {
    if (!el) return null;
    if (el.id) return "#" + CSS.escape(el.id);
    for (const key of ["data-setup", "data-name", "data-note", "data-editor"])
      if (el.hasAttribute(key))
        return (
          el.tagName.toLowerCase() +
          "[" +
          key +
          '="' +
          CSS.escape(el.getAttribute(key)) +
          '"]' +
          (el.hasAttribute("data-note-field")
            ? '[data-note-field="' +
              CSS.escape(el.getAttribute("data-note-field")) +
              '"]'
            : "")
        );
    if (el.matches("button[data-op]"))
      return (
        "button" +
        (el.classList[0] && el.classList[0] !== "selected"
          ? "." + CSS.escape(el.classList[0])
          : "") +
        [
          "data-op",
          "data-id",
          "data-value",
          "data-action",
          "data-key",
          "data-component",
          "data-region",
        ]
          .filter((k) => el.hasAttribute(k))
          .map((k) => "[" + k + '="' + CSS.escape(el.getAttribute(k)) + '"]')
          .join("")
      );
    if (el.name)
      return el.tagName.toLowerCase() + '[name="' + CSS.escape(el.name) + '"]';
    return null;
  }
  // Keep existing editable nodes alive: replacing a textarea destroys its IME session
  // and native undo stack. Navigation identity, errors and geometry still update on
  // every response; no entire-frame deferral is allowed while the user types.
  function nodeKey(node) {
    if (node.nodeType !== Node.ELEMENT_NODE) return String(node.nodeType);
    const tag = node.tagName;
    if (node.id) return tag + "#" + node.id;
    for (const attr of [
      "data-note",
      "data-tab",
      "data-space",
      "data-page",
      "data-start-document",
    ]) {
      if (node.hasAttribute(attr))
        return (
          tag +
          ":" +
          attr +
          ":" +
          node.getAttribute(attr) +
          ":" +
          (node.getAttribute("data-note-field") || "")
        );
    }
    if (node.matches("input,textarea,select"))
      return (
        tag +
        ":" +
        (node.name ||
          node.dataset.setup ||
          node.dataset.name ||
          node.dataset.editor ||
          node.className)
      );
    if (node.hasAttribute("data-op")) {
      const attrs = [
        "data-op",
        "data-id",
        "data-action",
        "data-key",
        "data-component",
        "data-region",
      ];
      if (!node.hasAttribute("data-key")) attrs.push("data-value");
      return (
        tag + ":" + attrs.map((attr) => node.getAttribute(attr) || "").join(":")
      );
    }
    return (
      tag + ":" + (node.classList[0] || "") + ":" + (node.dataset.folder || "")
    );
  }
  function reconcile(parent, incoming, preserveEditing) {
    const available = new Map();
    for (const node of parent.childNodes) {
      const key = nodeKey(node);
      if (!available.has(key)) available.set(key, []);
      available.get(key).push(node);
    }
    let cursor = parent.firstChild;
    for (const fresh of [...incoming.childNodes]) {
      const current = available.get(nodeKey(fresh))?.shift();
      if (!current) {
        parent.insertBefore(fresh.cloneNode(true), cursor);
        continue;
      }
      if (current !== cursor) parent.insertBefore(current, cursor);
      if (current.nodeType === Node.ELEMENT_NODE) {
        const adjusting = adjustment && current === adjustment.element;
        const editing =
          adjusting ||
          (preserveEditing &&
            current.matches(textInputSelector + ",select") &&
            (current === document.activeElement ||
              current.closest("form[data-form]")));
        for (const attr of [...current.attributes]) {
          if (
            !fresh.hasAttribute(attr.name) &&
            !(editing && attr.name === "value")
          )
            current.removeAttribute(attr.name);
        }
        for (const attr of fresh.attributes) {
          let value = attr.value;
          if (drag && attr.name === "class")
            value +=
              " " +
              [...current.classList]
                .filter((c) =>
                  [
                    "drop-hover",
                    "drop-before",
                    "drag-source",
                    "valid",
                  ].includes(c),
                )
                .join(" ");
          if (
            !(editing && attr.name === "value") &&
            current.getAttribute(attr.name) !== value
          )
            current.setAttribute(attr.name, value);
        }
        if (adjusting) {
          current.value = adjustment.value;
        } else if (editing && current.matches("select")) {
          const selected = current.value;
          reconcile(current, fresh, preserveEditing);
          const usable = [...current.options].find(
            (option) => option.value === selected && !option.disabled,
          );
          const fallback =
            [...current.options].find(
              (option) => option.value === fresh.value && !option.disabled,
            ) || [...current.options].find((option) => !option.disabled);
          current.value = (usable || fallback)?.value || "";
        } else if (!editing) {
          reconcile(current, fresh, preserveEditing);
          if (
            current.matches("input,textarea,select") &&
            current.value !== fresh.value
          )
            current.value = fresh.value;
        }
      } else if (current.nodeValue !== fresh.nodeValue)
        current.nodeValue = fresh.nodeValue;
      cursor = current.nextSibling;
    }
    for (const nodes of available.values())
      for (const node of nodes) node.remove();
  }
  function patch(result) {
    if (result.generation && result.generation < generation) return;
    if (result.generation) generation = result.generation;
    if (result.error) {
      announce(result.error);
      return;
    }
    if (!result.html) return;
    patching = true;
    const previousMenu = root.querySelector(".popover-menu")?.dataset.menu;
    const previousStep = root.querySelector(".onboarding")?.className;
    const previousScreen =
      root.querySelector(".utility-screen")?.dataset.screen;
    const tabPositions = new Map(
      [...root.querySelectorAll(".tab-row")].map((el) => [
        el.dataset.tab,
        el.getBoundingClientRect(),
      ]),
    );
    const hadPanel = !!root.querySelector(".workspace-panel");
    const sameContext =
      currentContext === null || currentContext === result.context;
    if (result.context) currentContext = result.context;
    const active = document.activeElement,
      key = selector(active);
    const selection =
      active && typeof active.selectionStart === "number"
        ? [active.selectionStart, active.selectionEnd]
        : null;
    const preserved =
      sameContext && key && active.matches(textInputSelector)
        ? active.value
        : null;
    const scrolls = [
      ...root.querySelectorAll(
        ".tabs-scroll,.setup-content,.setup-form,.settings-content,.editor-inspector,.library-content,.note-list,.start-surface,.horizontal-tabs,.modules-content,.module-details",
      ),
    ].map((e) => [e.className, e.scrollTop, e.scrollLeft]);
    const openDetails = [...root.querySelectorAll("details[open]")].map(
      (e) => e.className,
    );
    const hadDialog = !!topDialog();
    const template = document.createElement("template");
    template.innerHTML = result.html;
    const commandValue =
      template.content.querySelector("#command-input")?.getAttribute("value") ||
      "";
    if (sameContext) reconcile(root, template.content, true);
    else root.replaceChildren(template.content.cloneNode(true));
    currentOverlay = !!result.overlay;
    currentEditing = !!result.editing;
    if (result.commandRevision !== commandRevision) {
      commandRevision = result.commandRevision;
      const command = root.querySelector("#command-input");
      if (command) command.value = commandValue;
    }
    const dialog = topDialog();
    for (const el of root.querySelectorAll(
      ".browser-shell,.editor,.utility-screen,.command-palette",
    ))
      el.inert = !!dialog && !el.contains(dialog) && el !== dialog;
    if (dialog && !hadDialog) returnFocus = key;
    for (const cls of openDetails) {
      const el = root.getElementsByClassName(cls)[0];
      if (el) el.open = true;
    }
    for (const [cls, top, left] of scrolls) {
      const el = root.getElementsByClassName(cls)[0];
      if (el) {
        el.scrollTop = top;
        el.scrollLeft = left;
      }
    }
    const next = key ? root.querySelector(key) : null;
    const freshFocus = result.focus && result.focusToken !== focusToken;
    if (freshFocus) focusToken = result.focusToken;
    if (freshFocus) {
      const focus = document.getElementById(result.focus);
      focus?.focus({ preventScroll: true });
      focus?.select?.();
    } else if (next && (!dialog || dialog.contains(next))) {
      if (preserved !== null && next.value !== preserved)
        next.value = preserved;
      if (document.activeElement !== next) next.focus({ preventScroll: true });
      if (
        !composition &&
        next !== active &&
        selection &&
        next.setSelectionRange &&
        next.type !== "number" &&
        next.type !== "range"
      )
        try {
          next.setSelectionRange(...selection);
        } catch {}
    } else if (dialog)
      dialog
        .querySelector("input,button:not(:disabled),select")
        ?.focus({ preventScroll: true });
    else if (hadDialog && returnFocus) {
      root.querySelector(returnFocus)?.focus({ preventScroll: true });
      returnFocus = null;
    }
    if (adjustment) {
      root
        .querySelector(".editing-preview")
        ?.style.setProperty("--rail-width", adjustment.value + "px");
    }
    if (resize) {
      resize.shell.style.setProperty("--rail-width", resize.value + "px");
      resize.handle.setAttribute("aria-valuenow", Math.round(resize.value));
    }
    const feedback = root.querySelector(
      '.rail-feedback[data-transient="true"]',
    );
    const message = feedback?.querySelector("span")?.textContent || "";
    if (message !== feedbackMessage) {
      clearTimeout(feedbackTimer);
      feedbackMessage = message;
      if (message)
        feedbackTimer = setTimeout(() => {
          feedbackMessage = "";
          send({ op: "transient-dismiss" });
        }, 7000);
    }
    positionMenu();
    positionDialog();
    const menu = root.querySelector(".anchored-menu .popover-menu");
    if (menu && previousMenu !== menu.dataset.menu)
      menu
        .querySelector("input,button:not(:disabled),select")
        ?.focus({ preventScroll: true });
    const step = root.querySelector(".onboarding");
    if (step && previousStep !== step.className) {
      step.classList.add("setup-enter");
      setTimeout(() => step.classList.remove("setup-enter"), 420);
      const heading = root.querySelector("#setup-heading");
      if (!root.querySelector('[aria-invalid="true"]'))
        heading?.focus({ preventScroll: true });
      announce(
        root.querySelector(".setup-progress")?.getAttribute("aria-valuetext"),
      );
    }
    const screen = root.querySelector(".utility-screen");
    if (screen && previousScreen !== screen.dataset.screen)
      animate(
        screen,
        [
          { opacity: 0.4, transform: "translateY(4px)" },
          { opacity: 1, transform: "translateY(0)" },
        ],
        180,
      );
    if (sameContext && motionAllowed() && !root.querySelector(".dragging")) {
      for (const tab of root.querySelectorAll(".tab-row")) {
        const before = tabPositions.get(tab.dataset.tab),
          after = tab.getBoundingClientRect();
        if (before && Math.abs(before.top - after.top) > 1)
          animate(
            tab,
            [
              { transform: `translateY(${before.top - after.top}px)` },
              { transform: "translateY(0)" },
            ],
            180,
          );
      }
    }
    const panel = root.querySelector(".workspace-panel");
    if (panel && !hadPanel)
      animate(
        panel,
        [
          { opacity: 0, transform: "translateX(8px)" },
          { opacity: 1, transform: "translateX(0)" },
        ],
        180,
      );
    announce(result.announce);
    patching = false;
    scalePreview();
    scheduleGeometry();
  }
  function topDialog() {
    return (
      root.querySelector(".modal-menu .popover-menu") ||
      root.querySelector(".command-palette")
    );
  }
  function motionAllowed() {
    return (
      !matchMedia("(prefers-reduced-motion: reduce)").matches &&
      root.querySelector(".app-shell")?.dataset.reducedMotion !== "true"
    );
  }
  function animate(element, frames, duration) {
    if (motionAllowed() && element?.animate)
      element.animate(frames, { duration, easing: "cubic-bezier(.2,.7,.2,1)" });
  }
  function positionMenu() {
    const menu = root.querySelector(".anchored-menu .popover-menu");
    if (!menu) return;
    const rail = root.querySelector(".workspace-rail"),
      r = rail?.getBoundingClientRect();
    const width = r?.width ? Math.max(180, r.width - 20) : 260;
    menu.style.width = Math.min(width, innerWidth - 24) + "px";
    const anchor = menuAnchor || { x: r?.left || 10, y: 44 };
    menu.style.left =
      Math.max(
        12,
        Math.min(
          r?.width ? r.left + 10 : anchor.x,
          innerWidth - menu.offsetWidth - 12,
        ),
      ) + "px";
    menu.style.top =
      Math.max(12, Math.min(anchor.y, innerHeight - menu.offsetHeight - 12)) +
      "px";
  }
  function positionDialog() {
    const dialog = root.querySelector(".command-palette");
    if (!dialog || !dialogPosition) return;
    dialogPosition.x = Math.max(
      12,
      Math.min(dialogPosition.x, innerWidth - dialog.offsetWidth - 12),
    );
    dialogPosition.y = Math.max(
      12,
      Math.min(dialogPosition.y, innerHeight - dialog.offsetHeight - 12),
    );
    dialog.style.position = "fixed";
    dialog.style.left = dialogPosition.x + "px";
    dialog.style.top = dialogPosition.y + "px";
    dialog.style.margin = "0";
  }
  function announce(value) {
    if (value) document.getElementById("announcer").textContent = value;
  }
  function send(request) {
    chain = chain
      .then(() => transport({ kind: "action", request }))
      .then(patch)
      .catch((e) => announce("Could not complete that action. " + e.message));
    return chain;
  }
  window.neutrino = { receive: patch, command: send };
  function scalePreview() {
    const frame = root.querySelector(".editor-preview"),
      canvas = root.querySelector(".preview-canvas");
    if (!frame || !canvas) return;
    canvas.style.width = frame.clientWidth + "px";
    canvas.style.height = frame.clientHeight + "px";
    canvas.style.transform = "none";
    canvas.style.left = "0";
    canvas.style.top = "0";
    const frameRect = frame.getBoundingClientRect();
    for (const [selector, target] of [
      [".tabs-selection", ".workspace-rail"],
      [".nav-selection", ".page-toolbar"],
    ]) {
      const selection = frame.querySelector(selector);
      let source = canvas.querySelector(target);
      if (
        target === ".workspace-rail" &&
        source &&
        getComputedStyle(source).visibility === "hidden"
      )
        source = canvas.querySelector(".horizontal-tabs");
      if (selection && source) {
        const rect = source.getBoundingClientRect();
        selection.style.left = rect.left - frameRect.left + "px";
        selection.style.top = rect.top - frameRect.top + "px";
        selection.style.width = rect.width + "px";
        selection.style.height = rect.height + "px";
        selection.style.right = "auto";
        selection.style.bottom = "auto";
      }
    }
  }
  function scheduleGeometry() {
    scalePreview();
    cancelAnimationFrame(geometryFrame);
    geometryFrame = requestAnimationFrame(() => {
      if (!native()) return;
      const pages = [
        ...root.querySelectorAll(".browser-shell .native-page"),
      ].map((el) => {
        const r = el.getBoundingClientRect();
        return {
          id: el.dataset.page,
          x: r.x,
          y: r.y,
          width: r.width,
          height: r.height,
          radius:
            parseFloat(
              getComputedStyle(el.closest(".page-frame") || el).borderRadius,
            ) || 0,
        };
      });
      positionMenu();
      positionDialog();
      const menu = root
        .querySelector(".anchored-menu .popover-menu")
        ?.getBoundingClientRect();
      const overlapsMenu =
        menu &&
        pages.some(
          (p) =>
            menu.left < p.x + p.width &&
            menu.right > p.x &&
            menu.top < p.y + p.height &&
            menu.bottom > p.y,
        );
      native()
        .postMessage({
          kind: "geometry",
          generation,
          overlay:
            currentOverlay || drag?.kind === "component" || !!overlapsMenu,
          editing: currentEditing,
          pages,
          menuRect: menu
            ? { x: menu.x, y: menu.y, width: menu.width, height: menu.height }
            : null,
          dragRegions: [...root.querySelectorAll("[data-window-drag]")]
            .filter((e) => !e.closest(".editing-preview"))
            .map((e) => {
              const r = e.getBoundingClientRect();
              return { x: r.x, y: r.y, width: r.width, height: r.height };
            }),
        })
        .catch(() => {});
    });
  }
  new ResizeObserver(scheduleGeometry).observe(root);
  window.addEventListener("resize", scheduleGeometry);
  function dataRequest(el) {
    const r = { op: el.dataset.op };
    for (const [key, value] of Object.entries(el.dataset)) {
      if (key === "op" || key === "type") continue;
      r[key === "folderId" ? "folderID" : key === "spaceId" ? "spaceID" : key] =
        value;
    }
    if (r.op === "editor-scope" || el.dataset.type === "bool")
      r.value = r.value === "true";
    if (r.index !== undefined) r.index = Number(r.index);
    return r;
  }
  document.addEventListener("click", (e) => {
    if (e.target.closest(".editing-preview")) return;
    const button = e.target.closest("[data-op]");
    if (button && !button.disabled) {
      e.preventDefault();
      if (button.dataset.op === "menu") {
        const r = button.getBoundingClientRect();
        menuAnchor = { x: r.left, y: r.bottom + 5 };
      }
      send(dataRequest(button));
      return;
    }
    if (e.target.matches("[data-dismiss]")) send({ op: "escape" });
  });
  document.addEventListener("dblclick", (e) => {
    if (e.target.closest("[data-window-drag]"))
      native()?.postMessage({ kind: "zoom" });
  });
  document.addEventListener("compositionstart", () => {
    composition = true;
  });
  document.addEventListener("compositionend", () => {
    composition = false;
  });
  document.addEventListener("input", (e) => {
    const el = e.target;
    if (el.dataset.editor && el.type === "range") {
      if (!adjustment || adjustment.element !== el || adjustment.ending)
        adjustment = {
          element: el,
          id: String(++adjustmentSequence),
          value: el.value,
        };
      adjustment.value = el.value;
      send({
        op: "editor-value",
        key: el.dataset.editor,
        value: Number(el.value),
        gesture: adjustment.id,
      });
    } else if (el.dataset.note)
      transport({
        kind: "action",
        request: {
          op: "native",
          action: "saveNote",
          id: el.dataset.note,
          value: { field: el.dataset.noteField, text: el.value },
        },
      })
        .then((result) => patch({ ...result, passive: true }))
        .catch((e) => announce("Could not save note. " + e.message));
    else if (el.dataset.moduleSearch)
      send({ op: "module-query", value: el.value });
    else if (el.id === "command-input") send({ op: "query", value: el.value });
    else if (el.dataset.setup)
      send({ op: "setup-field", key: el.dataset.setup, value: el.value });
    else if (el.dataset.name !== undefined)
      send({ op: "name", value: el.value });
  });
  document.addEventListener("change", (e) => {
    const el = e.target;
    if (el.dataset.moduleSetting) {
      const value = el.type === "number" ? Number(el.value) : el.value;
      if (
        el.type !== "number" ||
        (Number.isSafeInteger(value) && value >= 0 && value <= 200000)
      )
        send({
          op: "module-setting",
          id: el.dataset.moduleId,
          key: el.dataset.moduleSetting,
          value,
        });
    }
    if (el.dataset.scope)
      send({ op: "editor-scope", value: el.value === "true" });
    if (el.dataset.editor) finishAdjustment();
    if (el.name === "provider") {
      const input = el.form.elements.endpoint;
      input.value =
        el.value === "local"
          ? "http://localhost:1234/v1"
          : el.value === "xAI"
            ? "https://api.x.ai/v1"
            : "https://api.openai.com/v1";
      el.form.elements.key.value = "";
    }
  });
  document.addEventListener("submit", (e) => {
    e.preventDefault();
    const form = e.target;
    if (form.dataset.form === "address") {
      const value = new FormData(form).get("address");
      if (value?.trim()) send({ op: "navigate", value });
    } else if (form.dataset.form === "credential") {
      const f = new FormData(form);
      const request = {
        op: "saveCredential",
        origin: f.get("origin"),
        username: f.get("username"),
        password: f.get("password"),
      };
      form.elements.password.value = "";
      send(request);
    } else if (form.dataset.form === "find") {
      send({ op: "find", value: new FormData(form).get("find") });
      send({ op: "escape" });
    } else if (form.dataset.form === "ai") {
      const f = new FormData(form);
      const request = {
        op: "saveAI",
        provider: f.get("provider"),
        endpoint: f.get("endpoint"),
        model: f.get("model"),
        key: f.get("key"),
        useAccount: f.get("useAccount") === "account",
      };
      form.elements.key.value = "";
      send(request);
    } else if (form.dataset.form === "assistant")
      send({ op: "assistant", value: new FormData(form).get("prompt") });
  });
  document.addEventListener("keydown", (e) => {
    const typing =
        e.target.matches(textInputSelector) ||
        (e.target.matches("select") && !currentEditing),
      command = e.metaKey || e.ctrlKey;
    if (e.isComposing) return;
    if (command && ["l", "k", "t"].includes(e.key.toLowerCase())) {
      e.preventDefault();
      const key = e.key.toLowerCase();
      send({
        op:
          key === "l"
            ? "focus-address"
            : key === "k"
              ? "palette"
              : e.shiftKey
                ? "reopenTab"
                : "newTab",
      });
      return;
    }
    if (e.key === "Enter" && e.target.matches("input[data-name]")) {
      const action = e.target
        .closest(".popover-menu")
        ?.querySelector("button.primary[data-op]");
      if (action && e.target.value.trim()) {
        e.preventDefault();
        send({ ...action.dataset });
      }
      return;
    }
    const moving = e.target.closest("[data-drag-dialog]");
    if (
      moving &&
      ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)
    ) {
      e.preventDefault();
      const r = moving.closest(".command-palette").getBoundingClientRect();
      dialogPosition = {
        x: dialogPosition?.x ?? r.x,
        y: dialogPosition?.y ?? r.y,
      };
      dialogPosition.x +=
        e.key === "ArrowRight" ? 16 : e.key === "ArrowLeft" ? -16 : 0;
      dialogPosition.y +=
        e.key === "ArrowDown" ? 16 : e.key === "ArrowUp" ? -16 : 0;
      positionDialog();
      return;
    }
    const space = e.target.closest("[data-space]"),
      folder = e.target.closest("[data-folder-source]");
    if (
      e.altKey &&
      e.shiftKey &&
      (space || folder) &&
      ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"].includes(e.key)
    ) {
      e.preventDefault();
      const list = [
          ...root.querySelectorAll(
            space ? "[data-space]" : "[data-folder-source]",
          ),
        ],
        el = space || folder,
        i = list.indexOf(el);
      const backward = ["ArrowLeft", "ArrowUp"].includes(e.key),
        before = list[i + (backward ? -1 : 2)];
      if (i === 0 && backward) return;
      send({
        op: space ? "reorder-spaces" : "reorder-folders",
        id: space?.dataset.space || folder.dataset.folderSource,
        before: before
          ? space
            ? before.dataset.space
            : before.dataset.folderSource
          : "",
      });
      return;
    }
    if (
      ((space && !command && !e.altKey) ||
        (e.ctrlKey && e.altKey && !e.shiftKey)) &&
      ["ArrowLeft", "ArrowRight"].includes(e.key)
    ) {
      e.preventDefault();
      send({ op: "space-step", value: e.key === "ArrowRight" ? 1 : -1 });
      return;
    }
    if (e.key === "Escape") {
      e.preventDefault();
      if (resize) {
        finishResize(false);
        return;
      }
      send({ op: "escape" });
      return;
    }
    if (e.key === "Tab") {
      const modal = topDialog();
      if (modal) {
        const list = [
          ...modal.querySelectorAll(
            'button:not(:disabled),input,textarea,select,[tabindex="0"]',
          ),
        ].filter((x) => x.getClientRects().length);
        if (list.length) {
          const first = list[0],
            last = list[list.length - 1];
          if (
            e.shiftKey &&
            (document.activeElement === first ||
              !modal.contains(document.activeElement))
          ) {
            e.preventDefault();
            last.focus();
          } else if (!e.shiftKey && document.activeElement === last) {
            e.preventDefault();
            first.focus();
          }
        }
      }
      return;
    }
    if (e.target.id === "command-input") {
      if (["ArrowDown", "ArrowUp", "Enter"].includes(e.key)) {
        e.preventDefault();
        send({
          op:
            e.key === "Enter"
              ? "activate-result"
              : e.key === "ArrowDown"
                ? "result-next"
                : "result-previous",
        });
      }
      return;
    }
    if (
      e.target.matches("[data-resize]") &&
      ["ArrowLeft", "ArrowRight"].includes(e.key)
    ) {
      e.preventDefault();
      const v =
        Number(e.target.getAttribute("aria-valuenow")) +
        (e.key === "ArrowRight" ? 8 : -8);
      send({ op: "sidebar-width", value: Math.max(200, Math.min(340, v)) });
      return;
    }
    if (command && e.key.toLowerCase() === "z" && !typing) {
      e.preventDefault();
      send({
        op: root.querySelector(".editor")
          ? e.shiftKey
            ? "editor-redo"
            : "editor-undo"
          : e.shiftKey
            ? "noop"
            : "undo-tabs",
      });
    } else if (command && e.key === ",") {
      e.preventDefault();
      send({ op: "screen", value: "settings" });
    } else if (command && e.key.toLowerCase() === "d") {
      e.preventDefault();
      send({ op: "bookmark" });
    } else if (command && e.key.toLowerCase() === "b") {
      e.preventDefault();
      send({ op: "sidebar" });
    } else if (
      e.altKey &&
      e.shiftKey &&
      ["ArrowUp", "ArrowDown"].includes(e.key)
    ) {
      const tab = e.target.closest("[data-tab]");
      if (tab) {
        const tabs = [
          ...tab.parentElement.querySelectorAll(":scope > [data-tab]"),
        ];
        const at = tabs.indexOf(tab),
          target = tabs[at + (e.key === "ArrowUp" ? -1 : 2)];
        e.preventDefault();
        if (e.key === "ArrowUp" && at === 0) return;
        send({
          op: "move-tab",
          id: tab.dataset.tab,
          before: target?.dataset.tab || "",
          group: tab.dataset.group,
          folderID: tab.dataset.folder,
        });
      }
    }
  });
  document.addEventListener("contextmenu", (e) => {
    const tab = e.target.closest("[data-tab]");
    if (tab) {
      e.preventDefault();
      menuAnchor = { x: e.clientX, y: e.clientY };
      send({ op: "menu", value: "tab:" + tab.dataset.tab });
    }
  });
  function clearTargets() {
    root
      .querySelectorAll(".drop-hover,.drop-before")
      .forEach((x) => x.classList.remove("drop-hover", "drop-before"));
  }
  document.addEventListener("dragstart", (e) => {
    if (e.target.closest(".editing-preview")) return;
    const tab = e.target.closest("[data-tab]"),
      component = e.target.closest("[data-component]"),
      space = e.target.closest("[data-space]"),
      folder = e.target.closest("[data-folder-source]");
    if (tab) {
      drag = { kind: "tab", id: tab.dataset.tab };
      tab.classList.add("drag-source");
    } else if (component) {
      drag = { kind: "component", component: component.dataset.component };
      root.querySelectorAll("[data-dock]").forEach((el) => {
        const r = el.dataset.dock;
        el.classList.toggle(
          "valid",
          drag.component === "tabs" ||
            (drag.component === "navigation" &&
              ["top", "bottom"].includes(r)) ||
            (drag.component === "panels" &&
              ["leading", "trailing"].includes(r)),
        );
      });
    } else if (space && !space.disabled) {
      drag = { kind: "space", id: space.dataset.space };
      space.classList.add("drag-source");
    } else if (folder && folder.draggable) {
      drag = { kind: "folder", id: folder.dataset.folderSource };
      folder.classList.add("drag-source");
    } else return;
    document.body.classList.add("dragging-" + drag.kind);
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("application/x-neutrino", JSON.stringify(drag));
    scheduleGeometry();
  });
  function dropTarget(e) {
    if (!drag) return null;
    return drag.kind === "component"
      ? e.target.closest("[data-dock].valid")
      : drag.kind === "space"
        ? e.target.closest("[data-space]")
        : drag.kind === "folder"
          ? e.target.closest("[data-folder-source]")
          : e.target.closest("[data-tab],[data-space],[data-drop-group]");
  }
  document.addEventListener("dragover", (e) => {
    if (!drag) return;
    clearTargets();
    const target = dropTarget(e);
    if (!target) return;
    if (
      (drag.kind === "tab" && target.dataset.tab === drag.id) ||
      (drag.kind === "space" && target.dataset.space === drag.id) ||
      (drag.kind === "folder" && target.dataset.folderSource === drag.id)
    )
      return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    target.classList.add(
      target.dataset.tab || drag.kind === "folder" || drag.kind === "space"
        ? "drop-before"
        : "drop-hover",
    );
    const scroller = e.target.closest(".tabs-scroll");
    if (scroller) {
      const r = scroller.getBoundingClientRect();
      if (e.clientY < r.top + 30) scroller.scrollTop -= 9;
      else if (e.clientY > r.bottom - 30) scroller.scrollTop += 9;
    }
  });
  document.addEventListener("drop", (e) => {
    if (!drag) return;
    const target = dropTarget(e);
    if (!target) return;
    e.preventDefault();
    if (drag.kind === "component")
      send({
        op: "dock",
        component: drag.component,
        region: target.dataset.dock,
      });
    else if (drag.kind === "space")
      send({ op: "reorder-spaces", id: drag.id, before: target.dataset.space });
    else if (drag.kind === "folder")
      send({
        op: "reorder-folders",
        id: drag.id,
        before: target.dataset.folderSource,
      });
    else if (target.dataset.space)
      send({ op: "move-space", id: drag.id, spaceID: target.dataset.space });
    else
      send({
        op: "move-tab",
        id: drag.id,
        before: target.dataset.tab || "",
        group: target.dataset.group || target.dataset.dropGroup,
        folderID: target.dataset.folder || "",
      });
    cleanupDrag();
  });
  function cleanupDrag() {
    drag = null;
    document.body.classList.remove(
      "dragging-tab",
      "dragging-component",
      "dragging-space",
      "dragging-folder",
    );
    root
      .querySelectorAll(".drag-source,.valid")
      .forEach((x) => x.classList.remove("drag-source", "valid"));
    clearTargets();
    scheduleGeometry();
  }
  document.addEventListener("dragend", cleanupDrag);
  document.addEventListener("pointerdown", (e) => {
    const popup = root.querySelector(".anchored-menu .popover-menu");
    if (
      popup &&
      !popup.contains(e.target) &&
      !e.target.closest('[data-op="menu"]')
    )
      send({ op: "escape" });
    const grip = e.target.closest("[data-drag-dialog]");
    if (grip) {
      const r = grip.closest(".command-palette").getBoundingClientRect();
      dialogDrag = {
        grip,
        x: e.clientX,
        y: e.clientY,
        startX: r.x,
        startY: r.y,
      };
      grip.setPointerCapture(e.pointerId);
      e.preventDefault();
      return;
    }
    const handle = e.target.closest("[data-resize]");
    if (handle) {
      const shell = handle.closest(".browser-shell"),
        start = Number(handle.getAttribute("aria-valuenow"));
      resize = {
        handle,
        shell,
        start,
        x: e.clientX,
        value: start,
        trailing: shell.classList.contains("placement-trailing"),
      };
      handle.setPointerCapture(e.pointerId);
      e.preventDefault();
    }
  });
  document.addEventListener("pointermove", (e) => {
    if (dialogDrag) {
      dialogPosition = {
        x: dialogDrag.startX + e.clientX - dialogDrag.x,
        y: dialogDrag.startY + e.clientY - dialogDrag.y,
      };
      positionDialog();
      return;
    }
    if (!resize) return;
    resize.value = Math.max(
      200,
      Math.min(
        340,
        resize.start + (e.clientX - resize.x) * (resize.trailing ? -1 : 1),
      ),
    );
    resize.shell.style.setProperty("--rail-width", resize.value + "px");
    resize.handle.setAttribute("aria-valuenow", Math.round(resize.value));
    scheduleGeometry();
  });
  function finishAdjustment() {
    if (!adjustment || adjustment.ending) return;
    const active = adjustment;
    active.ending = true;
    send({ op: "editor-end-adjustment" }).then(() => {
      if (adjustment === active) adjustment = null;
    });
  }
  function finishResize(commit) {
    if (!resize) return;
    const r = resize;
    resize = null;
    if (commit) send({ op: "sidebar-width", value: r.value });
    else {
      r.shell.style.setProperty("--rail-width", r.start + "px");
      r.handle.setAttribute("aria-valuenow", r.start);
      scheduleGeometry();
    }
  }
  document.addEventListener("pointerup", () => {
    dialogDrag = null;
    finishResize(true);
    finishAdjustment();
  });
  document.addEventListener("pointercancel", () => {
    dialogDrag = null;
    finishResize(false);
    finishAdjustment();
  });
  document.addEventListener("focusin", (e) => {
    const menu = root.querySelector(".anchored-menu .popover-menu");
    if (!patching && menu && !menu.contains(e.target)) send({ op: "escape" });
  });
  document.addEventListener(
    "wheel",
    (e) => {
      const rail = e.target.closest(".workspace-rail");
      if (
        !rail ||
        e.target.closest(".editing-preview") ||
        drag ||
        currentOverlay ||
        Math.abs(e.deltaX) < Math.abs(e.deltaY) * 1.35 ||
        Math.abs(e.deltaX) < 2
      )
        return;
      const now = performance.now();
      if (now - wheelGesture.last > 240)
        wheelGesture = { sum: 0, last: now, locked: false };
      wheelGesture.last = now;
      e.preventDefault();
      if (wheelGesture.locked) return;
      wheelGesture.sum +=
        e.deltaX *
        (e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? innerWidth : 1);
      if (Math.abs(wheelGesture.sum) >= 76) {
        wheelGesture.locked = true;
        send({ op: "space-step", value: wheelGesture.sum > 0 ? 1 : -1 });
      }
    },
    { passive: false },
  );
  // Preview controls remain inert; wheel input only changes inspection scroll position.
  document.addEventListener(
    "wheel",
    (e) => {
      const frame = e.target.closest(".editor-preview");
      if (!frame || drag) return;
      const candidates = [
        ...frame.querySelectorAll(
          ".tabs-scroll,.library-content,.note-list,.horizontal-tabs,.start-surface",
        ),
      ].filter((el) => {
        const r = el.getBoundingClientRect();
        return (
          e.clientX >= r.left &&
          e.clientX <= r.right &&
          e.clientY >= r.top &&
          e.clientY <= r.bottom
        );
      });
      let dy = e.deltaY,
        dx = e.deltaX,
        handled = false;
      for (const el of candidates.reverse()) {
        const top = el.scrollTop,
          left = el.scrollLeft,
          vertical = el.scrollHeight > el.clientHeight;
        el.scrollTop += dy;
        el.scrollLeft += dx || (vertical ? 0 : dy);
        const y = el.scrollTop - top,
          x = el.scrollLeft - left;
        if (x || y) handled = true;
        dy -= y || (!vertical && !dx ? x : 0);
        if (dx) dx -= x;
        if (!dy && !dx) break;
      }
      if (handled) e.preventDefault();
    },
    { passive: false },
  );
  transport({ kind: "ready" })
    .then(patch)
    .catch((e) => announce(e.message));
})();
