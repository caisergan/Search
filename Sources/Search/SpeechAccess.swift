import AppKit
import Speech
import WebKit

// Turning what you say into text, for the pages that ask.
//
// WebKit does the listening itself, through macOS's speech recognition, and
// asks macOS the first time a site wants it — once the app says what it is
// for (NSSpeechRecognitionUsageDescription, in build.sh). Refused there, or
// with macOS's speech recognition switched off, a page's SpeechRecognition
// only hears "service-not-allowed", and all the page can do is write you a
// sentence about settings it can't open. Search hears that answer too and,
// when the reason is macOS's, says at the top of the page where the switch
// is, with a button to it — as it does for your location (see Location.swift).

@MainActor
enum SpeechAccess {
    /// Why macOS says no: Search isn't allowed (Privacy & Security › Speech
    /// Recognition), or speech recognition is off on this Mac (Siri and
    /// Dictation both off), which WebKit takes for the same refusal.
    enum Refusal: String {
        case permission, service
    }

    /// Told once a launch.
    static var onRefused: ((Refusal) -> Void)?
    private static var told = false
    /// For the bench: how many times a page heard the refusal.
    private(set) static var heard = 0

    /// What macOS says about Search and speech recognition.
    static var authorization: String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .notDetermined: return "not asked yet"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "allowed"
        @unknown default: return "unknown"
        }
    }

    /// A page's recognizer was refused, listening in `language` ("tr-TR"; ""
    /// when the page didn't say). Not asked yet, there is nothing to point
    /// at: WebKit asks macOS itself the next time the page listens.
    static func refused(language: String) {
        heard += 1
        let reason: Refusal?
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied, .restricted:
            reason = .permission
        case .authorized:
            let recognizer = language.isEmpty ? SFSpeechRecognizer() : SFSpeechRecognizer(locale: Locale(identifier: language))
            reason = recognizer?.isAvailable == false ? .service : nil
        default:
            reason = nil
        }
        guard let reason, !told else { return }
        told = true
        onRefused?(reason)
    }

    /// System Settings at the switch: Privacy & Security › Speech Recognition,
    /// or Keyboard › Dictation when speech recognition itself is off.
    static func openSettings(for reason: Refusal) {
        let pane = reason == .permission
            ? "com.apple.preference.security?Privacy_SpeechRecognition"
            : "com.apple.Keyboard-Settings.extension?Dictation"
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// The page's word that its recognizer was refused, passed to Search's side.
final class SpeechRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeSpeech"
    /// The event the page's side tells Search's side with, through the DOM
    /// both worlds share. Made afresh each launch, so a page can neither
    /// listen for it nor send it: it never appears in anything the page can
    /// read.
    static let refused = "search-speech-" + UUID().uuidString.prefix(8).lowercased()

    /// In the page's own world, before the site's scripts: each recognizer the
    /// page starts is listened to, once however often it starts, for
    /// "service-not-allowed". Nothing the page hears changes. `start` is
    /// wrapped in a Proxy, which keeps its name and length and shows no
    /// source — WebKit prints it as "function ProxyObject() { [native code]
    /// }" — and what the wrapper uses is taken before the site's scripts
    /// run, so a page that replaces addEventListener or dispatchEvent
    /// neither breaks it nor sees it.
    static let page = """
    (function () {
      var name = '\(refused)', apply = Reflect.apply, Custom = CustomEvent;
      var listen = EventTarget.prototype.addEventListener, tell = EventTarget.prototype.dispatchEvent;
      var has = WeakSet.prototype.has, add = WeakSet.prototype.add, seen = [];
      [window.SpeechRecognition, window.webkitSpeechRecognition].forEach(function (Recognition) {
        if (typeof Recognition !== 'function' || seen.indexOf(Recognition) >= 0) return;
        seen.push(Recognition);
        var start = Recognition.prototype.start, watched = new WeakSet();
        if (typeof start !== 'function') return;
        Recognition.prototype.start = new Proxy(start, {
          apply: function (target, recognizer, args) {
            if (recognizer && typeof recognizer === 'object' && !apply(has, watched, [recognizer])) {
              apply(add, watched, [recognizer]);
              try {
                apply(listen, recognizer, ['error', function (event) {
                  if (event.error !== 'service-not-allowed') return;
                  apply(tell, window, [new Custom(name, { detail: String(recognizer.lang || '') })]);
                }]);
              } catch (e) {}
            }
            return apply(target, recognizer, args);
          }
        });
      });
    })();
    """

    /// Search's side of it, in Search's own world, where the handler is.
    static let bridge = """
    (function () {
      var handler = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!handler || window.__officeSpeech) return;
      window.__officeSpeech = true;
      window.addEventListener('\(refused)', function (event) {
        handler.postMessage({ lang: typeof event.detail === 'string' ? event.detail.slice(0, 35) : '' });
      });
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        let language = (message.body as? [String: Any])?["lang"] as? String ?? ""
        MainActor.assumeIsolated { SpeechAccess.refused(language: language) }
    }
}
