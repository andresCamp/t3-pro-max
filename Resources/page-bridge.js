// Injected into every T3 Code Pro Max window (see ProWindowController).
//
// 1. Reports the sidebar's project filter to the app, so the window title can name the
//    folder. T3 has no API for it; its filter button carries the label
//    "Filter threads by project: <owner>/<name>" (apps/web/src/components/Sidebar.tsx),
//    and plain "Filter threads by project" when every project is shown.
// 2. Draws the Mission Control overlay when the app asks: the page blurred, with the
//    folder's own icon (cloned from that same button) and its name on top.

(() => {
  const PREFIX = "Filter threads by project";
  let lastReported;

  function scopeButton() {
    return document.querySelector(`[aria-label^="${PREFIX}"]`);
  }

  /** The filtered folder's display name, null for all projects, undefined if the sidebar is hidden. */
  function currentScope() {
    const button = scopeButton();
    if (!button) return undefined;
    const label = button.getAttribute("aria-label") || "";
    return label.startsWith(`${PREFIX}: `) ? label.slice(PREFIX.length + 2) : null;
  }

  function report() {
    const scope = currentScope();
    // A collapsed sidebar removes the button; keep the last answer rather than "all projects".
    if (scope === undefined || scope === lastReported) return;
    lastReported = scope;
    window.webkit.messageHandlers.t3pm.postMessage({ type: "scope", name: scope });
  }

  let timer;
  new MutationObserver(() => {
    clearTimeout(timer);
    timer = setTimeout(report, 120);
  }).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["aria-label"],
  });
  report();

  const OVERLAY_ID = "t3pm-mission-control";

  function isDark() {
    return (
      document.documentElement.classList.contains("dark") ||
      window.matchMedia("(prefers-color-scheme: dark)").matches
    );
  }

  /** Shows or hides the overlay. `appIcon` is a data URL used when no folder is filtered. */
  window.__t3pmOverlay = ({ show, appIcon }) => {
    document.getElementById(OVERLAY_ID)?.remove();
    // Blur T3's page itself; the overlay sits outside <body> so it stays sharp.
    // (backdrop-filter alone does not reliably reach Mission Control's thumbnails.)
    document.body.style.filter = show ? "blur(18px) saturate(.8)" : "";
    if (!show) return;

    const dark = isDark();
    const scope = currentScope() ?? lastReported ?? null;
    const slash = scope ? scope.lastIndexOf("/") : -1;
    const name = scope ? scope.slice(slash + 1) : "All projects";
    const owner = scope && slash > 0 ? scope.slice(0, slash) : "";

    const overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;
    overlay.style.cssText = [
      "position:fixed", "inset:0", "z-index:2147483647", "pointer-events:none",
      "display:flex", "flex-direction:column", "align-items:center", "justify-content:center", "gap:22px",
      `background:${dark ? "rgba(20,20,22,.6)" : "rgba(246,245,244,.6)"}`,
      "font-family:-apple-system,BlinkMacSystemFont,'SF Pro Display',system-ui,sans-serif",
    ].join(";");

    const iconBox = document.createElement("div");
    iconBox.style.cssText =
      "width:120px;height:120px;border-radius:28px;overflow:hidden;display:flex;align-items:center;justify-content:center;box-shadow:0 10px 30px rgba(0,0,0,.2)";
    const favicon = scope ? scopeButton()?.querySelector("img,svg,span") : null;
    if (favicon) {
      // The same element T3 draws in its sidebar, scaled up.
      const clone = favicon.cloneNode(true);
      clone.style.cssText = "width:100%;height:100%;display:flex";
      clone.querySelectorAll("img,svg,span").forEach((el) => {
        el.style.width = "100%";
        el.style.height = "100%";
        el.style.fontSize = "56px";
      });
      iconBox.appendChild(clone);
    } else if (appIcon) {
      const img = document.createElement("img");
      img.src = appIcon;
      img.style.cssText = "width:100%;height:100%";
      iconBox.style.boxShadow = "none";
      iconBox.appendChild(img);
    }

    const title = document.createElement("div");
    title.textContent = name;
    title.style.cssText = `font-size:64px;font-weight:600;letter-spacing:-1.5px;color:${dark ? "#f5f5f7" : "#111"};text-align:center;padding:0 40px;overflow-wrap:anywhere`;

    overlay.append(iconBox, title);
    if (owner) {
      const sub = document.createElement("div");
      sub.textContent = owner;
      sub.style.cssText = `font-size:26px;color:${dark ? "#a1a1a6" : "#666"};margin-top:-12px`;
      overlay.append(sub);
    }
    document.documentElement.appendChild(overlay);
  };
})();
