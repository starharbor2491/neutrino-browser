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
    splitArmed = false,
    lastDragPoint = null,
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
    wheelGesture = { sum: 0, last: 0, locked: false },
    shortcutMap = new Map(),
    activeTab = null,
    inputTimers = {};
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
    for (const key of ["data-setup", "data-setup-name", "data-name", "data-note", "data-editor"])
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
          "data-page",
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
              current.closest("form[data-form]")) &&
            (current.id !== "address-input" || current.dataset.addressContext === fresh.dataset.addressContext));
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
    if (Array.isArray(result.shortcuts))
      shortcutMap = new Map(result.shortcuts.map(([binding, action]) => [binding, action]));
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
    const overlays = [...root.querySelectorAll(".palette-scrim, .menu-scrim")];
    const spaceOrder = [...root.querySelectorAll(".spaces [data-space]")].map(
      (el) => el.dataset.space,
    );
    const previousSpace = root.querySelector(".space-button.selected")?.dataset.space;
    const previousSection = root.querySelector(".library-tabs .selected")?.dataset.value;
    const sameContext =
      currentContext === null || currentContext === result.context;
    if (result.context) currentContext = result.context;
    const active = document.activeElement,
      key = selector(active);
    const selection =
      active && typeof active.selectionStart === "number"
        ? [active.selectionStart, active.selectionEnd]
        : null;
    let preserved =
      sameContext && key && active.matches(textInputSelector)
        ? active.value
        : null;
    const scrolls = [
      ...root.querySelectorAll(
        ".tabs-scroll,.setup-content,.setup-form,.settings-content,.editor-inspector,.library-content,.note-list,.start-surface,.horizontal-tab-scroll,.modules-content,.module-details",
      ),
    ].map((e) => [e.className, e.scrollTop, e.scrollLeft]);
    // Disclosures that share a class are told apart by their summary, without its count.
    const detailKey = (e) => {
      const summary = e.querySelector(":scope > summary");
      const label = summary?.querySelector("strong")?.textContent ?? summary?.textContent ?? "";
      return e.className + "\n" + label.trim().replace(/\s*\([^)]*\)$/, "");
    };
    const openDetails = new Set([...root.querySelectorAll("details[open]")].map(detailKey));
    const hadDialog = !!topDialog();
    const template = document.createElement("template");
    template.innerHTML = result.html;
    if (active?.id === "address-input" && active.dataset.addressContext !== template.content.querySelector("#address-input")?.dataset.addressContext)
      preserved = null;
    const commandValue =
      template.content.querySelector("#command-input")?.getAttribute("value") ||
      "";
    if (sameContext) reconcile(root, template.content, true);
    else root.replaceChildren(template.content.cloneNode(true));
    for (const overlay of overlays) if (!overlay.isConnected) leave(overlay);
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
    if (openDetails.size)
      for (const el of root.querySelectorAll("details")) if (openDetails.has(detailKey(el))) el.open = true;
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
      firstControl(dialog)?.focus({ preventScroll: true });
    else if (hadDialog && returnFocus) {
      root.querySelector(returnFocus)?.focus({ preventScroll: true });
      returnFocus = null;
    }
    if (adjustment?.element.dataset.editor === "tabsWidth") {
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
    if (menu && previousMenu !== menu.dataset.menu && menu.dataset.menu !== "suggest")
      firstControl(menu)?.focus({ preventScroll: true });
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
    const space = root.querySelector(".space-button.selected")?.dataset.space;
    const tabs = root.querySelector(".tabs-scroll");
    if (previousSpace && space && space !== previousSpace && tabs) {
      const forward = spaceOrder.indexOf(space) > spaceOrder.indexOf(previousSpace);
      animate(
        tabs,
        [
          { opacity: 0, transform: `translateX(${forward ? 18 : -18}px)` },
          { opacity: 1, transform: "translateX(0)" },
        ],
        240,
      );
    } else if (sameContext && motionAllowed()) {
      for (const tab of root.querySelectorAll(".tab-row")) {
        if (tabPositions.size && !tabPositions.has(tab.dataset.tab))
          animate(
            tab,
            [
              { opacity: 0, transform: "translateX(-6px)" },
              { opacity: 1, transform: "translateX(0)" },
            ],
            200,
          );
      }
    }
    const section = root.querySelector(".library-tabs .selected")?.dataset.value;
    if (previousSection && section && section !== previousSection)
      for (const el of root.querySelectorAll(".library-content > :not(.library-tabs)"))
        animate(
          el,
          [
            { opacity: 0, transform: "translateY(4px)" },
            { opacity: 1, transform: "translateY(0)" },
          ],
          180,
        );
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
    revealActiveTab();
    updateBookmarkOverflow();
    updateMarkup();
    updateClocks();
    applySchedule();
    updateSounds();
    scalePreview();
    scheduleGeometry();
  }
  // Markup editor: strokes stay here and are redrawn after every render, so re-rendering never loses them.
  const markup = { image: null, source: "", strokes: [], tool: "pen", color: "#ff3b30", drawing: null };
  function updateMarkup() {
    const canvas = root.querySelector(".markup-canvas");
    if (!canvas) { markup.strokes = []; markup.source = ""; markup.image = null; return; }
    const source = canvas.dataset.markupImage;
    for (const b of root.querySelectorAll("[data-markup-tool]")) b.setAttribute("aria-pressed", String(b.dataset.markupTool === markup.tool));
    for (const b of root.querySelectorAll("[data-markup-color]")) b.setAttribute("aria-pressed", String(b.dataset.markupColor === markup.color));
    if (source !== markup.source) {
      markup.source = source; markup.strokes = []; markup.image = new Image();
      markup.image.onload = () => drawMarkup();
      markup.image.src = source;
    } else drawMarkup();
  }
  function drawMarkup() {
    const canvas = root.querySelector(".markup-canvas"), image = markup.image;
    if (!canvas || !image || !image.complete || !image.naturalWidth) return;
    if (canvas.width !== image.naturalWidth || canvas.height !== image.naturalHeight) { canvas.width = image.naturalWidth; canvas.height = image.naturalHeight; }
    const g = canvas.getContext("2d");
    g.globalAlpha = 1; g.globalCompositeOperation = "source-over";
    g.drawImage(image, 0, 0);
    for (const stroke of markup.strokes.concat(markup.drawing ? [markup.drawing] : [])) {
      const scale = canvas.width / 1000;
      g.strokeStyle = stroke.color; g.lineCap = "round"; g.lineJoin = "round";
      g.globalAlpha = stroke.tool === "highlight" ? 0.35 : 1;
      g.lineWidth = (stroke.tool === "highlight" ? 18 : 4) * Math.max(1, scale);
      g.beginPath();
      if (stroke.tool === "box" && stroke.points.length > 1) {
        const [a, b] = [stroke.points[0], stroke.points[stroke.points.length - 1]];
        g.strokeRect(a[0], a[1], b[0] - a[0], b[1] - a[1]);
      } else {
        stroke.points.forEach(([x, y], i) => (i ? g.lineTo(x, y) : g.moveTo(x, y)));
        g.stroke();
      }
    }
    g.globalAlpha = 1;
  }
  function markupPoint(e) {
    const canvas = e.target.closest(".markup-canvas"), r = canvas.getBoundingClientRect();
    return [((e.clientX - r.left) / r.width) * canvas.width, ((e.clientY - r.top) / r.height) * canvas.height];
  }
  document.addEventListener("pointerdown", (e) => {
    if (!e.target.closest?.(".markup-canvas") || e.button !== 0) return;
    e.target.setPointerCapture(e.pointerId);
    markup.drawing = { tool: markup.tool, color: markup.color, points: [markupPoint(e)] };
    drawMarkup();
  });
  document.addEventListener("pointermove", (e) => {
    if (!markup.drawing || !e.target.closest?.(".markup-canvas")) return;
    markup.drawing.points.push(markupPoint(e));
    if (markup.drawing.points.length > 5000) markup.drawing.points.shift();
    drawMarkup();
  });
  document.addEventListener("pointerup", () => {
    if (!markup.drawing) return;
    if (markup.drawing.points.length > 1) markup.strokes.push(markup.drawing);
    markup.drawing = null; drawMarkup();
  });
  document.addEventListener("click", (e) => {
    const tool = e.target.closest?.("[data-markup-tool]"), color = e.target.closest?.("[data-markup-color]");
    const undo = e.target.closest?.("[data-markup-undo]"), out = e.target.closest?.("[data-markup-export]");
    if (tool) markup.tool = tool.dataset.markupTool;
    else if (color) markup.color = color.dataset.markupColor;
    else if (undo) markup.strokes.pop();
    else if (out) {
      drawMarkup();
      const canvas = root.querySelector(".markup-canvas");
      if (canvas) send({ op: "markup", value: out.dataset.markupExport, data: canvas.toDataURL("image/png") });
      return;
    } else return;
    updateMarkup();
  });
  document.addEventListener("keydown", (e) => {
    if (!root.querySelector(".markup-editor")) return;
    if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); send({ op: "markup", value: "cancel" }); }
    else if ((e.metaKey || e.ctrlKey) && e.key === "z") { e.preventDefault(); markup.strokes.pop(); drawMarkup(); }
  }, true);
  // A menu or dialog's text field takes focus before its header's Close button.
  function firstControl(container) {
    return (
      container.querySelector('input:not([type=hidden]):not([type=checkbox]):not([type=radio]):not(:disabled),textarea') ||
      container.querySelector("input,button:not(:disabled),select")
    );
  }
  // The bookmarks bar shows what fits; » opens a menu with the rest, as in Chrome and Vivaldi.
  function updateBookmarkOverflow() {
    for (const bar of root.querySelectorAll(".bookmarks-bar")) {
      const list = bar.querySelector(".bar-items"), more = bar.querySelector(".bar-overflow");
      if (!list || !more) continue;
      const items = [...list.children];
      const overflow = () => items.findIndex((e) => e.offsetLeft + e.offsetWidth > list.clientWidth + 1);
      more.hidden = true;
      let first = overflow();
      // Showing » narrows the list, so measure again with it in place.
      if (first >= 0) { more.hidden = false; first = overflow(); }
      items.forEach((e, i) => { e.style.visibility = first >= 0 && i >= first ? "hidden" : ""; });
      more.dataset.value = "bm-overflow:" + Math.max(0, first);
    }
  }
  // Keep the selected tab visible after it changes, in the sidebar and in tab strips.
  function revealActiveTab() {
    const tab = root.querySelector(".browser-shell:not(.editing-preview) .tab-row.active[data-tab]");
    const id = tab?.dataset.tab || null;
    if (!tab || id === activeTab) {
      activeTab = id;
      return;
    }
    activeTab = id;
    tab.scrollIntoView({ block: "nearest", inline: "nearest", behavior: motionAllowed() ? "smooth" : "auto" });
  }
  function updateClocks() {
    const now = new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" });
    for (const el of root.querySelectorAll("[data-clock]")) if (el.textContent !== now) el.textContent = now;
  }
  setInterval(updateClocks, 15000);
  // Light and dark by time of day, when the person set a schedule.
  function applySchedule() {
    const shell = root.querySelector(".app-shell");
    const schedule = shell?.dataset.schedule;
    if (!schedule) return;
    const [light, dark] = schedule.split("-");
    const now = new Date(),
      minutes = now.getHours() * 60 + now.getMinutes(),
      at = (t) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3));
    const day = at(light) <= at(dark)
      ? minutes >= at(light) && minutes < at(dark)
      : minutes >= at(light) || minutes < at(dark);
    shell.dataset.mode = day ? "light" : "dark";
  }
  setInterval(applySchedule, 60000);
  // Interface sounds, key clicks and background music are generated, not sampled.
  let audio = null,
    music = null;
  function context() {
    audio ||= new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state === "suspended") audio.resume().catch(() => {});
    return audio;
  }
  function sounds() {
    return (root.querySelector(".app-shell")?.dataset.sounds || "").split(" ");
  }
  function tone(kind) {
    if (!sounds().includes(kind === "key" ? "keys" : "ui")) return;
    const ctx = context(),
      t = ctx.currentTime,
      osc = ctx.createOscillator(),
      gain = ctx.createGain();
    const [freq, length, level] =
      kind === "key" ? [1900, 0.025, 0.035] : kind === "close" ? [420, 0.09, 0.05] : kind === "open" ? [880, 0.08, 0.05] : [660, 0.05, 0.035];
    osc.type = kind === "key" ? "square" : "sine";
    osc.frequency.setValueAtTime(freq, t);
    if (kind !== "key") osc.frequency.exponentialRampToValueAtTime(freq * (kind === "close" ? 0.7 : 1.25), t + length);
    gain.gain.setValueAtTime(level, t);
    gain.gain.exponentialRampToValueAtTime(0.0001, t + length);
    osc.connect(gain).connect(ctx.destination);
    osc.start(t);
    osc.stop(t + length + 0.02);
  }
  window.neutrinoSound = tone;
  function updateSounds() {
    const want = sounds().includes("music") && !document.hidden;
    if (want && !music) {
      const ctx = context(),
        master = ctx.createGain();
      master.gain.value = 0.0001;
      master.gain.linearRampToValueAtTime(0.03, ctx.currentTime + 3);
      master.connect(ctx.destination);
      const voices = [110, 164.81, 220, 277.18].map((f, i) => {
        const osc = ctx.createOscillator(),
          lfo = ctx.createOscillator(),
          depth = ctx.createGain(),
          g = ctx.createGain();
        osc.type = i % 2 ? "triangle" : "sine";
        osc.frequency.value = f;
        lfo.frequency.value = 0.05 + i * 0.03;
        depth.gain.value = 0.4;
        lfo.connect(depth).connect(g.gain);
        g.gain.value = 0.5;
        osc.connect(g).connect(master);
        osc.start();
        lfo.start();
        return [osc, lfo];
      });
      music = { master, voices };
    } else if (!want && music) {
      const { master, voices } = music;
      music = null;
      master.gain.linearRampToValueAtTime(0.0001, audio.currentTime + 0.6);
      setTimeout(() => voices.flat().forEach((v) => v.stop()), 700);
    }
  }
  document.addEventListener("visibilitychange", updateSounds);
  function topDialog() {
    return (
      root.querySelector(".modal-menu .popover-menu") ||
      root.querySelector(".command-palette")
    );
  }
  // Removed overlays fade out from an inert copy outside the reconciled tree,
  // so the next render can never reuse a leaving node.
  function leave(overlay) {
    const shell = root.querySelector(".app-shell");
    if (!motionAllowed() || !shell) return;
    const layer = document.createElement("div");
    for (const { name, value } of shell.attributes) layer.setAttribute(name, value);
    layer.classList.add("ghost-layer");
    layer.inert = true;
    overlay.classList.add("leaving");
    layer.append(overlay);
    document.body.append(layer);
    const panel = overlay.querySelector(".palette-frame, .popover-menu");
    const fade = overlay.animate([{ opacity: 1 }, { opacity: 0 }], {
      duration: 140,
      easing: "ease-out",
      fill: "forwards",
    });
    panel?.animate(
      [
        { transform: "none" },
        { transform: "translateY(-3px) scale(0.98)" },
      ],
      { duration: 140, easing: "ease-out", fill: "forwards" },
    );
    fade.finished.finally(() => layer.remove());
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
    const scope = menu.dataset.menu === "notes-scope"
      ? document.getElementById("notes-scope-trigger")?.getBoundingClientRect()
      : null;
    const field = ["suggest", "site"].includes(menu.dataset.menu)
      ? root.querySelector(".browser-shell:not(.editing-preview) #address-input")?.closest(".location")?.getBoundingClientRect()
      : null;
    const wide = ["clear-data", "boost", "add-panel", "space-style"].includes(menu.dataset.menu) || menu.dataset.menu?.startsWith("edit-bookmark:");
    const width = menu.dataset.menu === "suggest" && field ? Math.max(field.width, 320) : scope ? 220 : wide ? 320 : menu.dataset.menu === "site" ? 300 : 240;
    menu.style.width = Math.min(width, innerWidth - 24) + "px";
    const anchor = field
      ? { x: field.left, y: field.bottom + 4 }
      : scope
      ? { x: scope.left, y: scope.bottom + 4 }
      : menuAnchor || { x: (r?.left || 0) + 10, y: 44 };
    menu.style.left =
      Math.max(8, Math.min(anchor.x, innerWidth - menu.offsetWidth - 8)) + "px";
    const below = anchor.y + menu.offsetHeight + 8 <= innerHeight;
    menu.style.transformOrigin = below ? "top left" : "bottom left";
    menu.style.top =
      Math.max(
        8,
        below ? anchor.y : Math.min(anchor.y, innerHeight) - menu.offsetHeight - 4,
      ) + "px";
  }
  function positionDialog() {
    const dialog = root.querySelector(".palette-frame");
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
    if (["newTab", "selectTab", "tab-step", "select-index"].includes(request.op)) tone(request.op === "newTab" ? "open" : "select");
    else if (["closeTab", "closeCurrent"].includes(request.op)) tone("close");
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
      [".panel-selection", ".workspace-panel"],
    ]) {
      const selection = frame.querySelector(selector);
      let source = canvas.querySelector(target);
      if (
        target === ".workspace-rail" &&
        source &&
        getComputedStyle(source).visibility === "hidden"
      )
        source = canvas.querySelector(".horizontal-tabs");
      if (!selection) continue;
      const rect = source?.getBoundingClientRect();
      selection.hidden = !rect || !rect.width || !rect.height ||
        getComputedStyle(source).visibility === "hidden";
      if (!selection.hidden) {
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
            currentOverlay || drag?.kind === "component" || splitArmed || !!overlapsMenu ||
            // The icon-only sidebar expands over the page while hovered.
            !!root.querySelector(".compact-rail:not(.editing-preview) > .workspace-rail:hover"),
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
  for (const type of ["mouseover", "mouseout"])
    document.addEventListener(type, (e) => {
      if (e.target.closest?.(".compact-rail > .workspace-rail")) scheduleGeometry();
    });
  let tracking = 0;
  root.addEventListener("transitionrun", (e) => {
    if (!e.target.matches?.(".browser-shell") || e.propertyName !== "grid-template-columns") return;
    cancelAnimationFrame(tracking);
    const until = performance.now() + 420;
    const step = () => {
      scheduleGeometry();
      if (performance.now() < until) tracking = requestAnimationFrame(step);
    };
    tracking = requestAnimationFrame(step);
  });
  window.addEventListener("resize", scheduleGeometry);
  window.addEventListener("resize", updateBookmarkOverflow);
  function dataRequest(el) {
    const r = { op: el.dataset.op };
    for (const [key, value] of Object.entries(el.dataset)) {
      if (key === "op" || key === "type") continue;
      r[key === "folderId" ? "folderID" : key === "spaceId" ? "spaceID" : key] =
        value;
    }
    if (r.op === "editor-scope" || el.dataset.type === "bool")
      r.value = r.value === "true";
    else if (el.dataset.type === "number") r.value = Number(r.value);
    if (el.dataset.json !== undefined) {
      try {
        r.value = JSON.parse(el.dataset.json);
      } catch {}
      delete r.json;
    }
    if (r.offset !== undefined) r.offset = Number(r.offset);
    if (r.index !== undefined) r.index = Number(r.index);
    if (r.page !== undefined) r.page = Number(r.page);
    return r;
  }
  document.addEventListener("click", (e) => {
    if (e.target.closest(".editing-preview")) return;
    const generate = e.target.closest("[data-generate]");
    if (generate) {
      e.preventDefault();
      const input = generate.closest(".password-field")?.querySelector("input");
      const alphabet = "abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789-_!?";
      const bytes = crypto.getRandomValues(new Uint8Array(20));
      if (input) {
        input.value = [...bytes].map((b) => alphabet[b % alphabet.length]).join("");
        input.type = "text";
        input.select();
      }
      return;
    }
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
    else if (el.dataset.notesQuery) send({op:"native",action:"notesQuery",value:el.value});
    else if (el.dataset.moduleSearch)
      send({ op: "module-query", value: el.value });
    else if (el.id === "command-input") send({ op: "query", value: el.value });
    else if (el.id === "address-input") debounce("address", 70, () => send({ op: "address-input", value: el.value }));
    else if (el.dataset.find) debounce("find", 140, () => send({ op: "find-query", value: el.value }));
    else if (el.dataset.libraryQuery)
      debounce("library", 160, () => send({ op: "native", action: el.dataset.libraryQuery === "history" ? "historyQuery" : "bookmarkQuery", value: el.value }));
    else if (el.dataset.setup)
      send({ op: "setup-field", key: el.dataset.setup, value: el.value });
    else if (el.dataset.name !== undefined)
      send({ op: "name", value: el.value });
  });
  function debounce(key, delay, run) {
    clearTimeout(inputTimers[key]);
    inputTimers[key] = setTimeout(run, delay);
  }
  document.addEventListener("change", (e) => {
    const el = e.target;
    if (el.dataset.zoomSlider) {
      send({ op: "zoom-set", value: Number(el.value) });
      return;
    }
    if (el.dataset.editorColor) {
      send({ op: "editor-value", key: el.dataset.editorColor, value: el.value.replace("#", "") });
      return;
    }
    if (el.dataset.setupName) {send({op:"editor-rename-named",id:el.dataset.setupName,value:el.value});}
    else if (el.dataset.moduleSetting) {
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
    const f = new FormData(form);
    if (form.dataset.form === "address") {
      const value = f.get("address");
      clearTimeout(inputTimers.address);
      if (form.querySelector("#address-input") && root.querySelector('.popover-menu[data-menu="suggest"]')) send({ op: "suggest-accept" });
      else if (value?.trim()) send({ op: "navigate", value });
    } else if (form.dataset.form === "boost")
      send({ op: "boost", css: f.get("css"), hide: f.get("hide"), js: f.get("js"), hue: Number(f.get("hue") || 0) });
    else if (form.dataset.form === "clear-data")
      send({ op: "clear-data", range: f.get("range"), items: f.getAll("items") });
    else if (form.dataset.form === "edit-bookmark")
      send({ op: "edit-bookmark", id: form.dataset.id, title: f.get("title"), url: f.get("url"), folder: f.get("folder") });
    else if (form.dataset.form === "space-style")
      send({ op: "space-appearance", emoji: f.get("emoji"), gradient: [f.get("from"), f.get("to")] });
    else if (form.dataset.form === "search-engine")
      send({ op: "search-engine", value: "save", name: f.get("name"), keyword: f.get("keyword"), url: f.get("url") });
    else if (form.dataset.form === "address-book")
      send({ op: "address-book", value: "save", fields: Object.fromEntries(f) });
    else if (form.dataset.form === "chain")
      send({ op: "chain", value: "save", steps: f.getAll("steps").filter(Boolean) });
    else if (form.dataset.form === "interface-css")
      send({ op: "setting", key: "interfaceCSS", value: f.get("css") });
    else if (form.dataset.form === "schedule")
      send({ op: "setting", key: "themeSchedule", value: { enabled: f.get("enabled") === "on", light: f.get("light"), dark: f.get("dark") } });
    else if (form.dataset.form === "startup-pages")
      send({ op: "startup-pages", value: f.get("pages") });
    else if (form.dataset.form === "feed")
      send({ op: "feed", value: "add", url: f.get("url") });
    else if (form.dataset.form === "card")
      send({ op: "card", value: "save", name: f.get("name"), number: f.get("number"), expiry: f.get("expiry") });
    else if (form.dataset.form === "filter-list")
      send({ op: "filter-list", value: "add", url: f.get("url") });
    else if (form.dataset.form === "link-route")
      send({ op: "link-route", value: "add", host: f.get("host"), space: f.get("space") });
    else if (form.dataset.form === "custom-rules")
      send({ op: "custom-rules", value: "save", rules: f.get("rules") }); else if (form.dataset.form === "credential") {
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
      clearTimeout(inputTimers.find);
      send({ op: "find-query", value: f.get("find") });
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
    const recording = root.querySelector("[data-recording]");
    if (recording) {
      e.preventDefault();
      if (e.key === "Escape") send({ op: "record-shortcut", value: "" });
      else if (!["Shift", "Control", "Alt", "Meta"].includes(e.key))
        send({ op: "shortcut", action: recording.dataset.recording, value: binding(e) });
      return;
    }
    if (e.target.id === "address-input" && root.querySelector('.popover-menu[data-menu="suggest"]')) {
      if (["ArrowDown", "ArrowUp"].includes(e.key)) {
        e.preventDefault();
        send({ op: "suggest-move", value: e.key === "ArrowDown" ? 1 : -1 });
        return;
      }
    }
    if (e.target.dataset?.find) {
      if (e.key === "Enter") {
        e.preventDefault();
        clearTimeout(inputTimers.find);
        send({ op: "find-step", value: e.shiftKey ? -1 : 1 });
        return;
      }
      if (e.key === "Escape") {
        e.preventDefault();
        send({ op: "find-close" });
        return;
      }
    }
    if (!command && !e.altKey && sounds().includes("keys") && e.key.length === 1) tone("key");
    if (command && !e.altKey && !e.shiftKey && /^[1-9]$/.test(e.key)) {
      e.preventDefault();
      send({ op: "select-index", value: Number(e.key) });
      return;
    }
    if (command && e.key.toLowerCase() === "g" && root.querySelector(".find-bar")) {
      e.preventDefault();
      send({ op: "find-step", value: e.shiftKey ? -1 : 1 });
      return;
    }
    const action = shortcutMap.get(binding(e));
    if (action && !["new-tab", "palette", "bookmark", "sidebar", "settings"].includes(action) && (command || e.altKey || e.ctrlKey || /^f\d+$/.test(binding(e)))) {
      e.preventDefault();
      send({ op: "run-action", value: action });
      return;
    }
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
    // Up and Down move through a menu's items, starting from its filter field.
    const listMenu = e.target.closest?.(".popover-menu");
    if (listMenu && !e.altKey && !command && ["ArrowDown", "ArrowUp"].includes(e.key) && e.target.matches("input[data-name], button.menu-item")) {
      const items = [...listMenu.querySelectorAll("button.menu-item:not(:disabled)")].filter((x) => x.getClientRects().length);
      if (items.length) {
        e.preventDefault();
        const at = items.indexOf(e.target), field = listMenu.querySelector("input[data-name]");
        const next = e.key === "ArrowDown" ? items[at + 1] || items[0] : at > 0 ? items[at - 1] : field || items[items.length - 1];
        next.focus();
      }
      return;
    }
    if (e.key === "Enter" && e.target.matches("input[data-name]")) {
      // Tab search opens the first match, as Chrome's does.
      const action = e.target
        .closest(".popover-menu")
        ?.querySelector('button.primary[data-op], [data-menu="tab-search"] button[data-op="selectTab"]');
      if (action && (e.target.value.trim() || action.dataset.op === "selectTab")) {
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
      const r = moving.closest(".palette-frame").getBoundingClientRect();
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
      send({ op: "escape", restoreFocus: true });
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
  // A shortcut as "ctrl+alt+shift+cmd+key", named from the physical key.
  function binding(e) {
    const code = e.code || "";
    let key = code.startsWith("Key") ? code.slice(3).toLowerCase()
      : code.startsWith("Digit") ? code.slice(5)
      : /^F\d+$/.test(code) ? code.toLowerCase()
      : ({ Tab: "tab", Escape: "esc", Backspace: "delete", Delete: "delete", Enter: "enter", Space: "space", Equal: "=", Minus: "-", BracketLeft: "[", BracketRight: "]", Comma: ",", Period: ".", Slash: "/", Semicolon: ";", Quote: "'", Backquote: "`", Backslash: "\\", ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right" })[code] || e.key.toLowerCase();
    return [e.ctrlKey && "ctrl", e.altKey && "alt", e.shiftKey && "shift", e.metaKey && "cmd", key].filter(Boolean).join("+");
  }
  let pressTimer = 0;
  document.addEventListener("pointerdown", (e) => {
    const nav = e.target.closest('[data-op="back"],[data-op="forward"]');
    if (!nav || nav.disabled) return;
    pressTimer = setTimeout(() => {
      const r = nav.getBoundingClientRect();
      menuAnchor = { x: r.left, y: r.bottom + 5 };
      send({ op: "nav-history", value: nav.dataset.op });
    }, 480);
  });
  document.addEventListener("pointerup", () => clearTimeout(pressTimer));
  document.addEventListener("contextmenu", (e) => {
    const nav = e.target.closest('[data-op="back"],[data-op="forward"]');
    const panel = e.target.closest("[data-panel-id]");
    const favorite = e.target.closest("[data-favorite]");
    const dial = e.target.closest("[data-dial]");
    const target = nav ? ["nav-history", nav.dataset.op] : panel ? ["menu", "web-panel:" + panel.dataset.panelId] : favorite ? ["menu", "favorite:" + favorite.dataset.favorite] : dial ? ["menu", "edit-bookmark:" + dial.dataset.dial] : null;
    if (target) {
      e.preventDefault();
      menuAnchor = { x: e.clientX, y: e.clientY };
      send({ op: target[0], value: target[1] });
      return;
    }
    const tab = e.target.closest("[data-tab]");
    if (tab) {
      e.preventDefault();
      menuAnchor = { x: e.clientX, y: e.clientY };
      send({ op: "menu", value: "tab:" + tab.dataset.tab });
    }
  });
  function clearTargets() {
    root
      .querySelectorAll(".drop-hover,.drop-before,.drop-stack")
      .forEach((x) => x.classList.remove("drop-hover", "drop-before", "drop-stack"));
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
          : e.target.closest("[data-split-side],[data-tab],[data-space],[data-drop-group]");
  }
  // Arc and Vivaldi: a tab dragged onto the page opens beside it. Native pages sit
  // above the interface, so the drop zone appears (and the pages step aside) once the
  // drag reaches the page, or leaves the interface right beside it.
  function canSplitDrop() {
    const zone = root.querySelector(".split-drop");
    return !!(drag && drag.kind === "tab" && zone && zone.dataset.current !== drag.id);
  }
  function armSplit(on) {
    if (splitArmed === on) return;
    splitArmed = on;
    document.body.classList.toggle("split-armed", on);
    scheduleGeometry();
  }
  // Moving between elements fires dragenter on the new one just before dragleave on
  // the old one; a dragleave with no fresh dragenter means the drag left the interface.
  let dragEnteredAt = 0;
  document.addEventListener("dragenter", () => { dragEnteredAt = performance.now(); });
  document.addEventListener("dragleave", (e) => {
    if (e.relatedTarget || performance.now() - dragEnteredAt < 8 || !canSplitDrop() || !lastDragPoint) return;
    const frame = root.querySelector(".page-frame")?.getBoundingClientRect();
    if (frame && lastDragPoint.x > frame.left - 48 && lastDragPoint.x < frame.right && lastDragPoint.y > frame.top - 48 && lastDragPoint.y < frame.bottom)
      armSplit(true);
  });
  document.addEventListener("dragover", (e) => {
    if (!drag) return;
    lastDragPoint = { x: e.clientX, y: e.clientY };
    if (canSplitDrop() && e.target.closest?.(".page-frame")) armSplit(true);
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
      stacking(e, target) || nesting(e, target) ? "drop-stack"
        : target.dataset.tab || drag.kind === "folder" || drag.kind === "space"
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
  // Vivaldi: a tab dropped on the middle of another loose tab stacks the two.
  // Stacking is deliberate: the pointer rests on the middle of a loose tab, along the
  // list's own axis, for a moment. A quicker drop reorders, as in every other layout.
  let stackDwell = { target: null, since: 0 };
  function stacking(e, target) {
    if (!drag || drag.kind !== "tab" || !target.dataset.tab || target.dataset.tab === drag.id) return false;
    if (!root.querySelector(".browser-shell[data-stacks]")) return false;
    // Loose tab rows carry an empty data-folder; pinned tabs and tabs in a stack or folder can't stack.
    const loose = (row) => row && !(row.dataset.folder || "") && row.dataset.group !== "pinned";
    if (!loose(target) || !loose(root.querySelector(`[data-tab="${CSS.escape(drag.id)}"]`))) return false;
    const r = target.getBoundingClientRect();
    const across = target.closest(".horizontal-tabs") ? [e.clientX, r.left, r.width] : [e.clientY, r.top, r.height];
    if (!(across[0] > across[1] + across[2] * 0.25 && across[0] < across[1] + across[2] * 0.75)) {
      stackDwell = { target: null, since: 0 };
      return false;
    }
    if (stackDwell.target !== target) {
      stackDwell = { target, since: performance.now() };
      return false;
    }
    return performance.now() - stackDwell.since >= 600;
  }
  // Arc: a folder dropped on the middle of another folder's heading goes inside it.
  function nesting(e, target) {
    if (!drag || drag.kind !== "folder" || !target.dataset.folderSource || target.dataset.folderSource === drag.id) return false;
    const r = target.getBoundingClientRect();
    return e.clientY > r.top + r.height * 0.25 && e.clientY < r.bottom - r.height * 0.25;
  }
  document.addEventListener("drop", (e) => {
    if (!drag) return;
    const target = dropTarget(e);
    if (!target) return;
    e.preventDefault();
    if (target.dataset.splitSide) {
      send({ op: "split-with", id: drag.id });
      cleanupDrag();
      return;
    }
    if (nesting(e, target)) {
      send({ op: "nest-folder", id: drag.id, parent: target.dataset.folderSource });
      cleanupDrag();
      return;
    }
    if (stacking(e, target)) {
      send({ op: "stack-tabs", id: drag.id, onto: target.dataset.tab });
      cleanupDrag();
      return;
    }
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
    stackDwell = { target: null, since: 0 };
    lastDragPoint = null;
    armSplit(false);
    document.body.classList.remove(
      "dragging-tab",
      "dragging-component",
      "dragging-space",
      "dragging-folder",
    );
    root
      .querySelectorAll(".drag-source,.valid,.drop-stack")
      .forEach((x) => x.classList.remove("drag-source", "valid", "drop-stack"));
    clearTargets();
    scheduleGeometry();
  }
  // Tab previews: after a short hover, the host shows a picture of the tab's page beside it.
  let previewTimer = 0, previewing = "";
  const hidePreview = () => {
    clearTimeout(previewTimer);
    if (previewing) send({ op: "tab-preview", value: "hide" });
    previewing = "";
  };
  document.addEventListener("mouseover", (e) => {
    const row = e.target.closest && e.target.closest("[data-tab]");
    const id = row && row.dataset.tab;
    if (!id || id === previewing || row.classList.contains("active") || drag) return;
    clearTimeout(previewTimer);
    previewTimer = setTimeout(() => {
      const r = row.getBoundingClientRect();
      previewing = id;
      send({ op: "tab-preview", id, rect: { x: r.left, y: r.top, w: r.width, h: r.height } });
    }, previewing ? 120 : 600);
  });
  document.addEventListener("mouseout", (e) => {
    const row = e.target.closest && e.target.closest("[data-tab]");
    if (row && !(e.relatedTarget && row.contains(e.relatedTarget))) hidePreview();
  });
  ["mousedown", "wheel", "keydown"].forEach((type) => document.addEventListener(type, hidePreview, true));
  // Bookmarks: drop a row on another to reorder, or on a folder chip to move it there.
  let bookmarkDrag = null;
  document.addEventListener("dragstart", (e) => {
    const row = e.target.closest && e.target.closest("[data-bookmark]");
    if (!row) return;
    bookmarkDrag = row.dataset.bookmark;
    e.dataTransfer.effectAllowed = "move";
    e.dataTransfer.setData("text/plain", "");
  });
  document.addEventListener("dragover", (e) => {
    if (bookmarkDrag && e.target.closest && e.target.closest("[data-bookmark],[data-bookmark-folder]")) e.preventDefault();
  });
  document.addEventListener("drop", (e) => {
    if (!bookmarkDrag) return;
    const row = e.target.closest("[data-bookmark]"), chip = e.target.closest("[data-bookmark-folder]");
    if (row && row.dataset.bookmark !== bookmarkDrag) {
      e.preventDefault();
      send({ op: "move-bookmark", id: bookmarkDrag, before: row.dataset.bookmark });
    } else if (chip) {
      e.preventDefault();
      send({ op: "move-bookmark", id: bookmarkDrag, folder: chip.dataset.bookmarkFolder });
    }
    bookmarkDrag = null;
  });
  document.addEventListener("dragend", () => { bookmarkDrag = null; });
  // A tab dropped outside the window opens in a new window, as in Chrome and Arc.
  document.addEventListener("dragend", (e) => {
    const outside = e.clientX <= 0 || e.clientY <= 0 || e.clientX >= innerWidth || e.clientY >= innerHeight;
    if (drag && drag.kind === "tab" && e.dataTransfer && e.dataTransfer.dropEffect === "none" && outside)
      send({ op: "tab-action", id: drag.id, value: "new-window" });
    cleanupDrag();
  });
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
      const r = grip.closest(".palette-frame").getBoundingClientRect();
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
          ".tabs-scroll,.library-content,.note-list,.horizontal-tab-scroll,.start-surface",
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
  // Area capture: drag a rectangle over the frozen page image.
  let capture = null;
  document.addEventListener("pointerdown", (e) => {
    const overlay = e.target.closest(".capture-overlay");
    if (!overlay || e.button !== 0) return;
    const r = overlay.getBoundingClientRect();
    capture = { overlay, x: e.clientX - r.left, y: e.clientY - r.top, box: overlay.querySelector(".capture-box") };
    capture.box.hidden = false;
    e.preventDefault();
  });
  document.addEventListener("pointermove", (e) => {
    if (!capture) return;
    const r = capture.overlay.getBoundingClientRect();
    const x = Math.max(0, Math.min(e.clientX - r.left, r.width)),
      y = Math.max(0, Math.min(e.clientY - r.top, r.height));
    Object.assign(capture, { w: x - capture.x, h: y - capture.y });
    Object.assign(capture.box.style, {
      left: Math.min(x, capture.x) + "px",
      top: Math.min(y, capture.y) + "px",
      width: Math.abs(capture.w) + "px",
      height: Math.abs(capture.h) + "px",
    });
  });
  document.addEventListener("pointerup", (e) => {
    if (!capture) return;
    const { x, y, w = 0, h = 0 } = capture;
    capture = null;
    send({ op: "capture-area", x: Math.min(x, x + w), y: Math.min(y, y + h), width: Math.abs(w), height: Math.abs(h), copy: e.altKey });
  });
  // Boards: drag cards to arrange them.
  let card = null;
  document.addEventListener("pointerdown", (e) => {
    const el = e.target.closest(".board-card");
    if (!el || e.target.closest("button")) return;
    const canvas = el.closest(".board-canvas");
    card = { el, canvas, dx: e.clientX - el.offsetLeft, dy: e.clientY - el.offsetTop, moved: false };
    el.setPointerCapture?.(e.pointerId);
  });
  document.addEventListener("pointermove", (e) => {
    if (!card) return;
    card.moved = true;
    card.el.style.left = Math.max(0, e.clientX - card.dx) + "px";
    card.el.style.top = Math.max(0, e.clientY - card.dy) + "px";
  });
  document.addEventListener("pointerup", () => {
    if (!card) return;
    const { el, canvas, moved } = card;
    card = null;
    if (moved)
      send({ op: "board", value: "move", board: canvas.dataset.board, item: el.dataset.item, x: el.offsetLeft, y: el.offsetTop });
  });
  // Split view: drag the divider to resize the panes.
  let split = null;
  document.addEventListener("pointerdown", (e) => {
    const divider = e.target.closest(".split-divider");
    if (!divider) return;
    const canvas = divider.closest(".split-canvas");
    split = { canvas, stacked: canvas.dataset.axis === "stacked", ratio: null };
    divider.setPointerCapture?.(e.pointerId);
    e.preventDefault();
  });
  document.addEventListener("pointermove", (e) => {
    if (!split) return;
    const r = split.canvas.getBoundingClientRect();
    const ratio = split.stacked ? (e.clientY - r.top) / r.height : (e.clientX - r.left) / r.width;
    split.ratio = Math.max(0.2, Math.min(0.8, ratio));
    split.canvas.style.setProperty("--split", split.ratio);
    scheduleGeometry();
  });
  document.addEventListener("pointerup", () => {
    if (!split) return;
    const { ratio } = split;
    split = null;
    if (ratio !== null) send({ op: "split-ratio", value: Math.round(ratio * 100) / 100 });
  });
  // Hidden sidebar: point at the window's edge to reveal it over the page.
  document.addEventListener("pointerover", (e) => {
    if (e.target.closest("[data-rail-edge]")) send({ op: "rail-peek", value: true });
    else if (root.querySelector(".rail-peek") && !e.target.closest(".workspace-rail,.popover-menu,.menu-scrim"))
      send({ op: "rail-peek", value: false });
  });
  transport({ kind: "ready" })
    .then(patch)
    .catch((e) => announce(e.message));
})();
