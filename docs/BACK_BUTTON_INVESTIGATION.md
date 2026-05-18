# Back Button on ResonanceWebScreen — Investigation Log

**Status: Known limitation. Deferred.**
**Last updated: 2026-05-15**

---

## The Problem

`ResonanceWebScreen` renders a Three.js brain visualisation inside a Flutter
`HtmlElementView`, which the Flutter Web renderer backs with a native browser
`<iframe>`. The iframe element sits in the real browser DOM and intercepts
**all** pointer events at the browser level before Flutter's event system sees
them. Any Flutter widget placed in a `Stack` on top of the `HtmlElementView`
— regardless of z-index, wrapping, or overlay strategy — receives no tap or
click events because the browser delivers them to the iframe first.

This makes a conventional Flutter back button impossible on this screen.

---

## Approaches Attempted

### 1. `GestureDetector` in a `Stack`

A `GestureDetector` wrapping a visible back-button widget was placed above the
`HtmlElementView` in a `Stack`. The iframe consumed every pointer event at the
DOM level; Flutter's gesture arena never received the touch, so `onTap` never
fired.

### 2. `TextButton` in a `Stack`

Same result as `GestureDetector`. The button rendered visually but was
completely unresponsive. The iframe's DOM surface sits above all Flutter
painting layers in the browser's compositing order.

### 3. CSS `pointer-events` toggle on tap

Attempted to set `pointer-events: none` on the iframe element via Dart/JS
interop on each tap, hoping to let through a subsequent Flutter event.
The toggle arrives after the iframe has already consumed the initiating event,
so it has no effect on the tap that triggered it. Subsequent taps then miss
the iframe entirely, breaking the Three.js interaction.

### 4. Flutter `OverlayEntry`

An `OverlayEntry` was inserted into the app's `Overlay` (above all routes) to
host the back button. Flutter's overlay still renders inside `flt-glass-pane`,
which sits below the platform-view iframe in the browser's stacking context.
The button rendered but remained unresponsive to pointer events.

### 5. Transparent `HTMLDivElement` injected into `document.body`

A `<div>` with `position: fixed; z-index: 999999` was injected directly into
`document.body` via JS interop, bypassing Flutter's rendering entirely. The
Flutter platform view host (`flt-glass-pane`) and its `<iframe>` child still
intercepted pointer events before they reached the div. The button was
unresponsive.

### 6. `pointer_interceptor` package (v0.10.1)

The `pointer_interceptor` package wraps a widget in a transparent DOM element
designed specifically to recapture pointer events over platform views. The
button rendered correctly and the wrapping element was present in the DOM, but
`onPressed` never fired — confirmed by a `print` statement that never appeared
in the console. The package appears ineffective against full-document-width
`<iframe>` platform views on current Flutter Web.

### 7. HTML `postMessage` bridge

A native `<button>` was added inside `brain_visualizer.html` (hidden by
default, z-index 1000 within the iframe's own DOM). Flutter sends a
`{type: 'flutter_nav', action: 'show_back'}` postMessage to the iframe to
reveal the button when `showBackButton: true`. The button's click handler
sends `{type: 'flutter_nav', action: 'pop'}` back to `window.parent`. The
Flutter side listens on `web.window.onMessage` and calls
`Navigator.of(context, rootNavigator: true).pop()`.

This approach is architecturally sound and has been implemented, but its
end-to-end behaviour in the deployed Flutter Web shell has not been verified.
Potential failure modes include:

- `window.parent` inside the iframe resolving to a cross-origin context
  depending on how Flutter Web hosts the platform view, causing the browser to
  block the `postMessage` silently.
- `web.window.onMessage` in the Flutter page receiving (or not receiving) the
  message depending on how the Flutter engine sandboxes platform-view iframes.
- The `show_back` message arriving before the iframe's module script has
  registered its `message` listener (race condition on first load when
  `_iframeLoaded` is already `true` from a prior navigation).

---

## Recommended Future Investigation Paths

1. **Verify the `postMessage` bridge end-to-end** — add `console.log` in the
   iframe click handler and `debugPrint` in the Dart `onMessage` listener, then
   deploy to a browser and confirm both sides fire. This is the cheapest next
   step and may reveal the bridge already works.

2. **Iframe `sandbox` attribute** — check whether Flutter's platform view
   renderer adds a `sandbox` attribute to the generated `<iframe>`. A sandboxed
   iframe without `allow-same-origin` cannot reach `window.parent` and
   `postMessage` to the parent page is blocked. If present, the attribute must
   be removed or `allow-same-origin allow-scripts` must be set via JS interop
   before the iframe src is set.

3. **`postMessage` origin filtering** — tighten the `targetOrigin` argument
   from `'*'` to the actual app origin (readable from `window.location.origin`)
   on both the send and receive sides. This also surfaces any cross-origin
   blocking that `'*'` masks.

4. **Flutter engine-level platform view composition** — investigate whether the
   Flutter Web engine exposes a hook or configuration for compositing platform
   views differently (e.g., pointer-event pass-through regions). Track the
   Flutter issue tracker for `HtmlElementView` pointer-event improvements;
   engine-level support would make all the above workarounds unnecessary.

---

## References

- Flutter issue: platform views swallow pointer events on web —
  `flutter/flutter#58234` (and related issues)
- `pointer_interceptor` package: `pub.dev/packages/pointer_interceptor`
- W3C `postMessage` API: `developer.mozilla.org/en-US/docs/Web/API/Window/postMessage`
