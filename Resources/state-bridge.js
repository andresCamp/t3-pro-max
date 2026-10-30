// Runs before T3 reads its UI state. The native backup follows the window even
// when restarting the server changes the localStorage origin (host or port).
if (location.protocol === "http:" || location.protocol === "https:") {
  const key = "t3code:ui-state:v1";
  const storage = window.localStorage;
  if (saved !== null) storage.setItem(key, saved);

  function report() {
    window.webkit.messageHandlers.t3pm.postMessage({
      type: "ui-state", value: storage.getItem(key),
    });
  }

  for (const method of ["setItem", "removeItem", "clear"]) {
    const original = Storage.prototype[method];
    Storage.prototype[method] = function (...args) {
      const result = original.apply(this, args);
      if (this === storage && (method === "clear" || String(args[0]) === key)) report();
      return result;
    };
  }
  // Capture pre-existing WebKit state on the first launch with this version.
  report();
}
