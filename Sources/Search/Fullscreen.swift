import AppKit
import WebKit

// Full screen in the window, as Chrome has it.
//
// WebKit puts an element that goes full screen — a video on YouTube, a game,
// slides — in a window of its own, in a space of its own, and leaves ours
// behind it blurred, with "Click to Exit Full Screen" over it. That window is
// one more space to swipe through with three fingers, and the one you land on
// between the video and everything else. Safari does the same.
//
// Chrome keeps it in the window: the element fills the window, the window
// goes full screen if it isn't, and nothing else is made. So does Search now,
// always — there is no going back to the other way. The page's own Fullscreen API is
// answered in the page's world — requestFullscreen, exitFullscreen,
// fullscreenElement, their webkit names and their events — with the element
// put in the top layer, over everything, at the size of the window. A frame
// from another site asks the page it is in, which does the same for the
// frame, all the way up; only a frame let go full screen (allowfullscreen)
// is heard, and only just after a click or a key, as the real one requires.
// The top of it tells Search, through its own world (see FormRelay), which
// hides the strip and the column and takes the window full screen.
//
// WebKit's own full screen is off (see Tab.swift): a <video> with WebKit's
// controls loses their full-screen button, which went to a space of its own,
// and goes full screen in the window with a double click instead.

@MainActor
enum Fullscreen {
    /// The page's side, in its own world, every frame, before its scripts.
    static let page = #"""
    (function () {
      var K = Symbol.for('search.fullscreen');
      if (window[K]) return;
      Object.defineProperty(window, K, { value: true });
      var D = Document.prototype, E = Element.prototype;
      var ATTR = 'data-search-fullscreen', KEY = '__searchFullscreen';
      var current = null, lifted = new WeakSet(), style = null;
      var nativeElement = Object.getOwnPropertyDescriptor(D, 'fullscreenElement') || Object.getOwnPropertyDescriptor(D, 'webkitFullscreenElement');
      var nativeExit = D.exitFullscreen || D.webkitExitFullscreen;

      function active() { return !navigator.userActivation || navigator.userActivation.isActive; }
      function whole(el) { return el === document.documentElement || el === document.body; }
      function sheet() {
        if (style && style.isConnected) return;
        style = document.createElement('style');
        style.textContent = '[' + ATTR + ']{position:fixed!important;inset:0!important;width:100vw!important;height:100vh!important;' +
          'max-width:none!important;max-height:none!important;min-width:0!important;min-height:0!important;margin:0!important;' +
          'padding:0!important;border:0!important;box-sizing:border-box!important;transform:none!important;' +
          'z-index:2147483647!important;background:#000;overflow:hidden!important}' +
          '[' + ATTR + ']::backdrop{background:#000}';
        (document.head || document.documentElement).appendChild(style);
      }
      // The top layer, as full screen itself uses: over everything, past any
      // ancestor's transform, overflow or stacking.
      function lift(el) {
        if (whole(el) || el.hasAttribute('popover') || typeof el.showPopover !== 'function') return;
        try { el.setAttribute('popover', 'manual'); el.showPopover(); lifted.add(el); } catch (e) { el.removeAttribute('popover'); }
      }
      function drop(el) {
        if (!lifted.has(el)) return;
        lifted.delete(el);
        try { el.hidePopover(); } catch (e) {}
        el.removeAttribute('popover');
      }
      function tell(el) {
        [el, document].forEach(function (target, i) {
          if (i && el.isConnected) return; // it bubbles there
          ['fullscreenchange', 'webkitfullscreenchange'].forEach(function (type) {
            target.dispatchEvent(new Event(type, { bubbles: true, composed: true }));
          });
        });
      }
      function announce(on) {
        if (window === window.top) window.dispatchEvent(new CustomEvent('search-fullscreen', { detail: on ? 'on' : 'off' }));
        else try { window.parent.postMessage(Object.defineProperty({}, KEY, { value: on ? 'enter' : 'exit', enumerable: true }), '*'); } catch (e) {}
      }

      function enter(el, quietly) {
        if (current === el) return;
        if (current) leave(true, true);
        if (!whole(el)) { sheet(); el.setAttribute(ATTR, ''); lift(el); }
        current = el;
        announce(true);
        if (!quietly) tell(el);
      }
      // `inner`: told by the page we are in, which is leaving already.
      function leave(inner, keepUp) {
        var el = current;
        if (!el) return;
        current = null;
        el.removeAttribute(ATTR);
        drop(el);
        // A frame of ours that was full screen goes back too.
        if (el.tagName === 'IFRAME' || el.tagName === 'FRAME') {
          try { el.contentWindow.postMessage(Object.defineProperty({}, KEY, { value: 'leave', enumerable: true }), '*'); } catch (e) {}
        }
        if (!inner && !keepUp) announce(false);
        tell(el);
      }

      function request(options) {
        var el = this;
        if (!(el instanceof Element) || !el.isConnected) return Promise.reject(new TypeError('Not an element in the page.'));
        if (!active()) {
          document.dispatchEvent(new Event('fullscreenerror', { bubbles: true }));
          return Promise.reject(new TypeError('Full screen needs a click or a key.'));
        }
        enter(el);
        return Promise.resolve();
      }
      function exit() {
        if (!current) return nativeExit ? nativeExit.call(document) : Promise.resolve();
        leave(false);
        return Promise.resolve();
      }
      function put(target, name, value) {
        try { Object.defineProperty(target, name, { value: value, configurable: true, writable: true }); } catch (e) {}
      }
      function getter(target, name, get) {
        try { Object.defineProperty(target, name, { get: get, configurable: true }); } catch (e) {}
      }
      put(E, 'requestFullscreen', request);
      put(E, 'webkitRequestFullscreen', function () { request.call(this); });
      put(E, 'webkitRequestFullScreen', function () { request.call(this); });
      put(D, 'exitFullscreen', exit);
      put(D, 'webkitExitFullscreen', function () { exit(); });
      put(D, 'webkitCancelFullScreen', function () { exit(); });
      function element() { return current || (nativeElement && nativeElement.get ? nativeElement.get.call(document) : null); }
      getter(D, 'fullscreenElement', element);
      getter(D, 'webkitFullscreenElement', element);
      getter(D, 'webkitCurrentFullScreenElement', element);
      getter(D, 'webkitIsFullScreen', function () { return !!element(); });
      getter(D, 'fullscreen', function () { return !!element(); });
      getter(D, 'fullscreenEnabled', function () { return true; });
      getter(D, 'webkitFullscreenEnabled', function () { return true; });
      // With WebKit's own full screen off, its event handler properties are
      // gone too, and a page that looks for them before offering full screen
      // — YouTube hides its button — decides there is none.
      ['fullscreenchange', 'fullscreenerror', 'webkitfullscreenchange', 'webkitfullscreenerror'].forEach(function (type) {
        var handlers = new WeakMap();
        [D, E].forEach(function (proto) {
          if (('on' + type) in proto) return;
          try {
            Object.defineProperty(proto, 'on' + type, {
              configurable: true, enumerable: true,
              get: function () { var h = handlers.get(this); return h ? h.fn : null; },
              set: function (fn) {
                var h = handlers.get(this);
                if (h) this.removeEventListener(type, h.listener);
                if (typeof fn !== 'function') { handlers.delete(this); return; }
                var self = this, listener = function (e) { return fn.call(self, e); };
                handlers.set(this, { fn: fn, listener: listener });
                this.addEventListener(type, listener);
              }
            });
          } catch (e) {}
        });
      });

      // Safari's own names for a video's full screen, used by players made
      // for it: the same full screen in the window.
      var V = window.HTMLVideoElement && HTMLVideoElement.prototype;
      if (V) {
        put(V, 'webkitEnterFullscreen', function () { request.call(this); });
        put(V, 'webkitEnterFullScreen', function () { request.call(this); });
        put(V, 'webkitExitFullscreen', function () { if (current === this) exit(); });
        put(V, 'webkitExitFullScreen', function () { if (current === this) exit(); });
        getter(V, 'webkitSupportsFullscreen', function () { return true; });
        getter(V, 'webkitDisplayingFullscreen', function () { return current === this; });
      }
      // A video with WebKit's own controls has no full-screen button of its
      // own now — that one went to a space of its own — so a double click on
      // it goes full screen in the window, and back, as in Chrome.
      document.addEventListener('dblclick', function (e) {
        var v = e.target && e.target.closest ? e.target.closest('video') : null;
        if (!v || !v.controls || e.defaultPrevented) return;
        if (current === v) leave(false); else request.call(v);
      }, true);

      // A frame in this page asks for itself, or says it has left.
      window.addEventListener('message', function (e) {
        var what = e.data && typeof e.data === 'object' ? e.data[KEY] : null;
        if (!what) return;
        if (what === 'leave') { if (e.source === window.parent) leave(true); return; }
        var frames = document.querySelectorAll('iframe, frame'), frame = null;
        for (var i = 0; i < frames.length; i++) if (frames[i].contentWindow === e.source) { frame = frames[i]; break; }
        if (!frame) return;
        if (what === 'enter') {
          var allowed = frame.allowFullscreen || /(^|;|\s)fullscreen/.test(frame.getAttribute('allow') || '') || frame.hasAttribute('webkitallowfullscreen');
          if (!allowed || !active()) return;
          enter(frame);
        } else if (what === 'exit' && current === frame) {
          leave(true);
          announce(false);
        }
      }, true);

      // Esc leaves, before the page can keep it — as in every browser.
      window.addEventListener('keydown', function (e) {
        if (e.key === 'Escape' && current && window === window.top) { e.stopImmediatePropagation(); e.preventDefault(); leave(false); }
      }, true);
      // Search's word that the window has left full screen, or the tab the screen.
      window.addEventListener('search-fullscreen-leave', function () { if (current) leave(false); });
    })();
    """#
}

extension Browser {
    /// A page in the tab on screen went full screen in the window, or came
    /// out of it: the window follows, and goes back as it was — full screen
    /// already, it stays so.
    func wholeWindow(_ tab: Tab, _ on: Bool) {
        guard tab.id == activeID, let window = Links.window else { return }
        let full = window.styleMask.contains(.fullScreen)
        if on {
            if !full {
                Fullscreen.tookWindow = true
                window.toggleFullScreen(nil)
            }
            announce("Full screen — esc to leave")
        } else if Fullscreen.tookWindow {
            Fullscreen.tookWindow = false
            if full { window.toggleFullScreen(nil) }
        }
        Fullscreen.watch(window, browser: self)
    }
}

extension Fullscreen {
    /// Whether the window went full screen for a page, to go back after.
    static var tookWindow = false
    private static var watching: NSObjectProtocol?

    /// The window taken out of full screen by hand — the green button, ⌃⌘F —
    /// takes the page out too.
    static func watch(_ window: NSWindow, browser: Browser) {
        guard watching == nil else { return }
        watching = NotificationCenter.default.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak browser] _ in
            MainActor.assumeIsolated {
                tookWindow = false
                browser?.active?.leaveFullscreen()
            }
        }
    }
}
