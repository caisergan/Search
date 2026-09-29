import AppKit
import Security
import SwiftUI
import WebKit

// Addresses and cards, filled in as Chrome and Safari fill them.
//
// A click into a form's name, email, phone or address box, or a card's,
// brings a list down from the box: the addresses or cards you keep, and a
// click fills every box of the form it recognises at once — through each
// box's own setter, with the events typing would fire, as a sign-in is
// filled (see Forms.swift). Fields are known by what the page says they are
// for (autocomplete="email", "cc-number"…) and otherwise by their names,
// labels and hints, in English and Turkish.
//
// Everything is kept in the macOS keychain, one item for the addresses and
// one for the cards, readable by Search alone. A card is filled only after
// Touch ID or the Mac's password, never into a page that came over plain
// http, and its security code is never kept: it is typed each time.

/// A person's details, as forms ask for them.
struct Contact: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var organization = ""
    var email = ""
    var phone = ""
    var street = ""
    var street2 = ""
    var city = ""
    var region = ""
    var postal = ""
    var country = ""

    var title: String { name.isEmpty ? (email.isEmpty ? "Address" : email) : name }
    var detail: String { [street, city, country].filter { !$0.isEmpty }.joined(separator: ", ") }
    var isEmpty: Bool { values.isEmpty }

    /// What a form's boxes are given, by what each is for.
    var values: [String: String] {
        let parts = name.split(separator: " ").map(String.init)
        var out = [
            "name": name, "email": email, "phone": phone, "organization": organization,
            "street": street, "street2": street2, "city": city, "region": region, "postal": postal, "country": country,
            "given": parts.count > 1 ? parts.dropLast().joined(separator: " ") : name,
            "family": parts.count > 1 ? parts.last! : "",
        ]
        out = out.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        return out
    }
}

/// A payment card. The code on its back is never kept.
struct PaymentCard: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    /// Digits only.
    var number = ""
    var month = 1
    var year = 2030

    var last4: String { String(number.suffix(4)) }
    var brand: String { PaymentCard.brand(of: number) }
    var title: String { "\(brand) •••• \(last4)" }
    var detail: String { String(format: "Expires %02d/%02d", month, year % 100) }

    var values: [String: String] {
        ["cardName": name, "cardNumber": number, "cardMonth": String(format: "%02d", month), "cardYear": String(year)]
            .filter { !$0.value.isEmpty }
    }

    static func brand(of number: String) -> String {
        let digits = number.filter(\.isNumber)
        func starts(_ prefixes: [String]) -> Bool { prefixes.contains { digits.hasPrefix($0) } }
        if starts(["34", "37"]) { return "American Express" }
        if starts(["9792"]) { return "Troy" }
        if starts(["4"]) { return "Visa" }
        if let two = Int(digits.prefix(2)), (51...55).contains(two) { return "Mastercard" }
        if let four = Int(digits.prefix(4)), (2221...2720).contains(four) { return "Mastercard" }
        if starts(["6011", "65"]) { return "Discover" }
        if starts(["35"]) { return "JCB" }
        return "Card"
    }

    /// The check digit every card number carries (Luhn).
    static func valid(_ number: String) -> Bool {
        let digits = number.compactMap(\.wholeNumberValue)
        guard (12...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

/// What is kept, in the keychain.
@MainActor
enum AutoFill {
    /// A test run keeps its own, apart from yours.
    private static let service = Store.world.map { "Search AutoFill (\($0))" } ?? "Search AutoFill"

    static func contacts() -> [Contact] { read("addresses") }
    static func cards() -> [PaymentCard] { read("cards") }

    @discardableResult
    static func save(_ contacts: [Contact]) -> Bool { write(contacts, "addresses") }
    @discardableResult
    static func save(_ cards: [PaymentCard]) -> Bool { write(cards, "cards") }

    private static func read<T: Decodable>(_ account: String) -> [T] {
        var out: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { NSLog("AutoFill: keychain read failed (%d)", status) }
            return []
        }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func write<T: Encodable>(_ list: [T], _ account: String) -> Bool {
        guard let data = try? JSONEncoder().encode(list) else { return false }
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var fresh = identity
        fresh[kSecValueData as String] = data
        fresh[kSecAttrLabel as String] = service
        fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        return SecItemAdd(fresh as CFDictionary, nil) == errSecSuccess
    }

    // MARK: - a new password

    /// Three groups of six, as Safari writes one: letters and digits, one
    /// capital and one digit at least, nothing that reads as something else
    /// (no l, 1, I, O, 0), from the system's secure random numbers. About 71
    /// bits, and every site's rules allow it.
    static func strongPassword() -> String {
        var random = SystemRandomNumberGenerator()
        let lower = Array("abcdefghijkmnopqrstuvwxyz"), upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), digits = Array("23456789")
        var characters = (0..<18).map { _ in lower.randomElement(using: &random)! }
        var places = Array(0..<18).shuffled(using: &random)
        characters[places.removeLast()] = upper.randomElement(using: &random)!
        characters[places.removeLast()] = digits.randomElement(using: &random)!
        let text = String(characters)
        return [0, 6, 12].map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            return String(text[from..<text.index(from, offsetBy: 6)])
        }.joined(separator: "-")
    }
}

// MARK: - the page's side

/// The boxes a click lands in, and what each is for — told to Search as the
/// caret enters one — and filling a whole form's worth at once.
final class AutoFillRelay: NSObject, WKScriptMessageHandler {
    static let name = "searchAutoFill"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated {
            guard let tab else { return }
            let kind = body["category"] as? String
            var spot: CGRect?
            if let rect = body["rect"] as? [String: Double], let x = rect["x"], let y = rect["y"], let w = rect["w"], let h = rect["h"] {
                let zoom = tab.built?.pageZoom ?? 1
                spot = CGRect(x: x * zoom, y: y * zoom, width: w * zoom, height: h * zoom)
            }
            tab.onAutoFill?(tab, kind, spot)
        }
    }

    /// In Search's own world, in the page itself only. Boxes in a form with
    /// a sign-in in it are the sign-in's (see Forms.swift), except where the
    /// form asks for a new password — a sign-up, whose name and email are
    /// asked for like any other form's.
    static let script = """
    (function () {
      if (window.__searchAutoFill) return;
      var post = function (m) { try { window.webkit.messageHandlers.\(name).postMessage(m); } catch (e) {} };
      var TOKENS = { 'name': 'name', 'given-name': 'given', 'additional-name': 'middle', 'family-name': 'family',
        'email': 'email', 'tel': 'phone', 'tel-national': 'phone', 'organization': 'organization',
        'street-address': 'street', 'address-line1': 'street', 'address-line2': 'street2', 'address-level2': 'city',
        'address-level1': 'region', 'postal-code': 'postal', 'country': 'country', 'country-name': 'country',
        'cc-name': 'cardName', 'cc-number': 'cardNumber', 'cc-exp': 'cardExpiry', 'cc-exp-month': 'cardMonth',
        'cc-exp-year': 'cardYear', 'cc-csc': 'cardCode' };
      // Most particular first: a card's name before a person's.
      var WORDS = [
        [/card.?holder|name.?on.?card|cc.?name|kart.?(sahibi|üzerindeki|üstündeki)/i, 'cardName'],
        [/card.?(number|no\\b|num)|cc.?num|credit.?card|kart.?(numara|no\\b)|kredi.?kart/i, 'cardNumber'],
        [/cvc|cvv|csc|security.?code|güvenlik.?kod/i, 'cardCode'],
        [/exp\\w*.?(month|mm\\b)|son.?kullanma.?ay|\\bay\\b/i, 'cardMonth'],
        [/exp\\w*.?(year|yy)|son.?kullanma.?yıl|\\byıl\\b/i, 'cardYear'],
        [/expir|exp.?date|mm.?\\/.?yy|son.?kullanma/i, 'cardExpiry'],
        [/e-?mail|e-?posta/i, 'email'],
        [/phone|mobile|\\btel\\b|telefon|gsm|cep/i, 'phone'],
        // A whole name before either half of it: "Ad Soyad" holds "soyad".
        [/full.?name|^name$|your.?name|ad.?soyad|adınız.?soyadınız|^[iİ]sim$|^ad.?ve.?soyad/i, 'name'],
        [/first.?name|given.?name|forename|^ad$|^adı(nız)?$/i, 'given'],
        [/last.?name|surname|family.?name|soyad/i, 'family'],
        [/company|organi[sz]ation|firma|şirket|kurum/i, 'organization'],
        [/address.?(line)?.?2|apartment|suite|\\bapt\\b|daire|kapı.?no/i, 'street2'],
        [/address|street|adres|sokak|mahalle|cadde/i, 'street'],
        [/postal|zip|post.?code|posta.?kod/i, 'postal'],
        [/city|town|şehir|\\bil\\b|ilçe/i, 'city'],
        [/state|province|region|county|bölge|eyalet/i, 'region'],
        [/country|ülke/i, 'country']
      ];
      function label(el) {
        var text = '';
        if (el.labels) for (var i = 0; i < el.labels.length; i++) text += ' ' + el.labels[i].textContent;
        var near = el.closest && el.closest('label');
        if (near) text += ' ' + near.textContent;
        return text;
      }
      // Each thing the box is called, apart: its name, its id, its hint,
      // its label — so a rule for a label that is just "Ad" can say so.
      function words(el) {
        return [el.name, el.id, el.getAttribute('placeholder'), el.getAttribute('aria-label'), label(el)]
          .filter(Boolean).map(function (w) { return w.replace(/\\s+/g, ' ').trim(); }).filter(Boolean);
      }
      function kindOf(el) {
        if (!el || !/^(INPUT|SELECT|TEXTAREA)$/.test(el.tagName) || el.disabled || el.readOnly) return null;
        var type = (el.type || 'text').toLowerCase();
        if (['hidden', 'submit', 'button', 'checkbox', 'radio', 'file', 'image', 'reset', 'search', 'range', 'color', 'password'].indexOf(type) >= 0) return null;
        var auto = (el.getAttribute('autocomplete') || '').toLowerCase().split(/\\s+/);
        if (auto.indexOf('off') >= 0 && auto.length === 1) auto = [];
        for (var i = auto.length - 1; i >= 0; i--) if (TOKENS[auto[i]]) return TOKENS[auto[i]];
        if (type === 'email') return 'email';
        if (type === 'tel') return 'phone';
        var said = words(el);
        for (var j = 0; j < WORDS.length; j++) {
          for (var k = 0; k < said.length; k++) if (WORDS[j][0].test(said[k])) return WORDS[j][1];
        }
        return null;
      }
      function category(kind) { return !kind ? null : /^card/.test(kind) ? 'card' : 'address'; }
      function scope(el) { return el.form || (el.closest && el.closest('form')) || document; }
      function fields(root) {
        var found = [], all = root.querySelectorAll('input, select, textarea');
        for (var i = 0; i < all.length; i++) {
          var kind = kindOf(all[i]);
          var r = all[i].getBoundingClientRect();
          if (kind && r.width > 0 && r.height > 0) found.push([all[i], kind]);
        }
        return found;
      }
      // A sign-in's boxes are the sign-in's; a sign-up's, asking for a new
      // password, are anybody's.
      function signIn(root) {
        var boxes = root.querySelectorAll('input[type="password"]');
        if (!boxes.length) return false;
        for (var i = 0; i < boxes.length; i++) if ((boxes[i].getAttribute('autocomplete') || '').indexOf('new-password') >= 0) return false;
        return boxes.length === 1;
      }
      var here = null;
      function focused(e) {
        var el = e.target, kind = kindOf(el), cat = category(kind);
        if (cat) {
          var root = scope(el), found = fields(root), same = 0;
          for (var i = 0; i < found.length; i++) if (category(found[i][1]) === cat) same++;
          // One box on its own that merely looks like a name is no form.
          if (signIn(root) || (cat === 'address' && same < 2 && !(el.getAttribute('autocomplete') || '').trim())) cat = null;
        }
        here = cat ? el : null;
        var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
        post({ category: cat, rect: cat && r ? { x: r.left, y: r.top, w: r.width, h: r.height } : null });
      }
      document.addEventListener('focusin', focused, true);
      document.addEventListener('focusout', function () { setTimeout(function () {
        if (!document.activeElement || document.activeElement === document.body) { here = null; post({ category: null }); }
      }, 0); }, true);
      function put(el, value) {
        if (el.tagName === 'SELECT') {
          var want = String(value).toLowerCase(), pick = -1;
          for (var i = 0; i < el.options.length; i++) {
            var o = el.options[i], v = (o.value || '').toLowerCase(), t = (o.textContent || '').trim().toLowerCase();
            if (v === want || t === want) { pick = i; break; }
            if (pick < 0 && want.length > 1 && (t.indexOf(want) === 0 || (/^\\d+$/.test(want) && Number(v) === Number(want)))) pick = i;
          }
          if (pick < 0) return false;
          el.selectedIndex = pick;
        } else {
          var proto = el.tagName === 'TEXTAREA' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, value); else el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
        }
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      }
      // A card's expiry in the shape its box wants — MM/YY, MM / YY, MM/YYYY
      // — read off its hint, or with none, off how long it may be.
      function expiry(el, month, year) {
        var hint = el.getAttribute('placeholder') || '';
        var four = hint ? /yyyy|aaaa/i.test(hint) : Number(el.getAttribute('maxlength')) === 7;
        var y = four ? String(year) : String(year).slice(-2);
        return / \\/ /.test(hint) ? month + ' / ' + y : month + '/' + y;
      }
      window.__searchAutoFill = {
        // Every box of the form the caret is in that has something for it.
        fill: function (cat, values, host) {
          var h = location.hostname.toLowerCase().replace(/^www\\./, '');
          if (host && h !== host) return 0;
          var from = here || document.activeElement;
          if (!from) return 0;
          var filled = 0, found = fields(scope(from));
          for (var i = 0; i < found.length; i++) {
            var el = found[i][0], kind = found[i][1];
            if (category(kind) !== cat) continue;
            var value = kind === 'cardExpiry' ? (values.cardMonth && values.cardYear ? expiry(el, values.cardMonth, values.cardYear) : null)
              : kind === 'cardYear' && (el.getAttribute('maxlength') === '2' || /yy(?!yy)/i.test(el.getAttribute('placeholder') || '')) ? String(values.cardYear || '').slice(-2)
              : values[kind];
            // What is already typed stays, but for the box the caret is in.
            if (value === undefined || value === null || value === '' || (el !== from && el.value && el.tagName !== 'SELECT')) continue;
            if (put(el, value)) filled++;
          }
          return filled;
        }
      };
    })();
    """
}

// MARK: - the list, hanging from the box

/// What the box the caret is in can be given, hanging from it.
struct AutoFillOffer: Equatable {
    let tab: Tab.ID
    let spot: CGRect
    let category: String
    let contacts: [Contact]
    let cards: [PaymentCard]
    /// The page it was made for: a click fills only a page still of it.
    let host: String
}

struct AutoFillList: View {
    @ObservedObject var browser: Browser
    let offer: AutoFillOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if offer.category == "card" {
                ForEach(offer.cards) { card in
                    Line(mark: "creditcard", title: card.title, detail: card.detail) { browser.fill(card) }
                }
            } else {
                ForEach(offer.contacts) { contact in
                    Line(mark: nil, title: contact.title, detail: contact.detail.isEmpty ? contact.email : contact.detail) { browser.fill(contact) }
                }
            }
            Button { browser.dropAutoFill(); browser.fillingForms = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: offer.category == "card" ? "lock" : "person.text.rectangle")
                        .font(.system(size: 9, weight: .medium))
                    Text(offer.category == "card" ? "Touch ID first · Manage cards…" : "Manage addresses…")
                        .font(.system(size: 10.5))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Palette.faint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.wash.opacity(0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: max(250, min(360, offer.spot.width)), alignment: .leading)
        .background(Palette.ground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
        .offset(x: offer.spot.minX, y: offer.spot.maxY + 6)
    }

    private struct Line: View {
        let mark: String?
        let title: String
        let detail: String
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                HStack(spacing: 10) {
                    Group {
                        if let mark {
                            Image(systemName: mark).font(.system(size: 10.5, weight: .medium))
                        } else {
                            Text(String(title.first.map { String($0).uppercased() } ?? "•")).font(.system(size: 11, weight: .medium))
                        }
                    }
                    .foregroundStyle(Palette.ink)
                    .frame(width: 22, height: 22)
                    .background(Palette.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12.5)).foregroundStyle(Palette.ink).lineLimit(1)
                        if !detail.isEmpty {
                            Text(detail).font(.system(size: 10.5)).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(hovering ? Palette.hover : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(Motion.quick, value: hovering)
        }
    }
}

// MARK: - the browser's side

extension Browser {
    /// The caret entered a box a form can be filled from, or left one.
    func autoFillFocused(_ tab: Tab, category: String?, spot: CGRect?) {
        guard let category, let spot else {
            if autofilling?.tab == tab.id {
                let shown = autofilling
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                    if self?.autofilling == shown { self?.autofilling = nil }
                }
            }
            return
        }
        guard prefs.fillsForms, tab.id == activeID, !tab.bench, suggesting?.tab != tab.id,
              let url = tab.address, let host = url.host()?.lowercased()
        else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        switch category {
        case "card":
            // Never a card into a page anyone on the way could have written:
            // https, or this Mac itself.
            guard url.scheme?.lowercased() == "https" || Dialogs.isLoopback(host) else { return }
            let cards = AutoFill.cards()
            autofilling = cards.isEmpty ? nil : AutoFillOffer(tab: tab.id, spot: spot, category: category, contacts: [], cards: cards, host: bare)
        default:
            let contacts = AutoFill.contacts().filter { !$0.isEmpty }
            autofilling = contacts.isEmpty ? nil : AutoFillOffer(tab: tab.id, spot: spot, category: "address", contacts: contacts, cards: [], host: bare)
        }
    }

    func dropAutoFill() { autofilling = nil }

    /// An address picked: every box of the form that asks for part of it.
    func fill(_ contact: Contact) {
        guard let offer = autofilling, let tab = tabs.first(where: { $0.id == offer.tab }) else { return }
        autofilling = nil
        tab.autoFill("address", values: contact.values, host: offer.host) { [weak self] filled in
            if filled == 0 { self?.announce("Couldn't find the form's boxes anymore") }
        }
    }

    /// A card picked: you, first — Touch ID or the Mac's password — then
    /// its number, name and expiry into the form. The code on its back is
    /// for you to type.
    func fill(_ card: PaymentCard) {
        guard let offer = autofilling, let tab = tabs.first(where: { $0.id == offer.tab }) else { return }
        autofilling = nil
        // A test run asks nobody: there is nobody there to ask.
        let prove: (String, @escaping (Bool) -> Void) -> Void = Store.testing ? { _, done in done(true) } : Vault.prove
        prove("fill in your \(card.title)") { [weak self, weak tab] ok in
            guard ok, let tab, let self else { return }
            // The page may have gone elsewhere while you were asked.
            guard let host = tab.address?.host()?.lowercased(),
                  tab.address?.scheme?.lowercased() == "https" || Dialogs.isLoopback(host),
                  host.replacingOccurrences(of: "www.", with: "", options: .anchored) == offer.host
            else { return }
            tab.autoFill("card", values: card.values, host: offer.host) { filled in
                if filled == 0 { self.announce("Couldn't find the card's boxes anymore") }
            }
        }
    }
}

// MARK: - kept, and changed

/// Every address and card kept, in the panel Settings › Passwords opens.
/// Cards show only their last four digits; changing one means typing it anew.
struct AutoFillPanel: View {
    @ObservedObject var browser: Browser

    @State private var contacts = AutoFill.contacts()
    @State private var cards = AutoFill.cards()
    @State private var editingContact: Contact?
    @State private var addingCard = false

    var body: some View {
        Plate("Addresses and cards", width: 620, close: { browser.fillingForms = false }) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Caption("Addresses")
                    Card {
                        if contacts.isEmpty && editingContact == nil {
                            Nothing("None yet. Add yours, and a form's boxes fill from it with a click.")
                        }
                        ForEach(Array(contacts.enumerated()), id: \.element.id) { index, contact in
                            if index > 0 { Rule() }
                            if editingContact?.id == contact.id {
                                ContactForm(contact: contact, save: save, cancel: { editingContact = nil })
                            } else {
                                Line(contact.title, contact.detail.isEmpty ? contact.email : contact.detail) {
                                    HStack(spacing: 6) {
                                        Pill("Edit") { editingContact = contact }
                                        Pill("Remove") {
                                            contacts.removeAll { $0.id == contact.id }
                                            AutoFill.save(contacts)
                                        }
                                    }
                                }
                            }
                        }
                        if let editing = editingContact, !contacts.contains(where: { $0.id == editing.id }) {
                            if !contacts.isEmpty { Rule() }
                            ContactForm(contact: editing, save: save, cancel: { editingContact = nil })
                        }
                    }
                    Caption("Cards")
                    Card {
                        if cards.isEmpty && !addingCard {
                            Nothing("None yet. A card is filled only after Touch ID, and never its security code.")
                        }
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            if index > 0 { Rule() }
                            Line(card.title, "\(card.name.isEmpty ? "" : card.name + " · ")\(card.detail)") {
                                Pill("Remove") {
                                    cards.removeAll { $0.id == card.id }
                                    AutoFill.save(cards)
                                }
                            }
                        }
                        if addingCard {
                            if !cards.isEmpty { Rule() }
                            CardForm(save: { card in
                                cards.append(card)
                                AutoFill.save(cards)
                                addingCard = false
                            }, cancel: { addingCard = false })
                        }
                    }
                }
                .padding(.bottom, 2)
            }
            .frame(maxHeight: 480)
        } foot: {
            HStack(spacing: 8) {
                Pill("Add address") { editingContact = Contact() }
                    .disabled(editingContact != nil)
                Pill("Add card") { addingCard = true }
                    .disabled(addingCard)
                Spacer(minLength: 0)
                Text("In the macOS keychain, for Search alone")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.muted)
            }
        }
        .animation(Motion.settle, value: editingContact)
        .animation(Motion.settle, value: addingCard)
    }

    private func save(_ contact: Contact) {
        if let index = contacts.firstIndex(where: { $0.id == contact.id }) {
            contacts[index] = contact
        } else {
            contacts.append(contact)
        }
        AutoFill.save(contacts)
        editingContact = nil
    }

    private struct ContactForm: View {
        @State var contact: Contact
        let save: (Contact) -> Void
        let cancel: () -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Box("Full name", $contact.name)
                    Box("Organization", $contact.organization)
                }
                HStack(spacing: 8) {
                    Box("Email", $contact.email)
                    Box("Phone", $contact.phone)
                }
                Box("Street address", $contact.street)
                Box("Apartment, suite, floor", $contact.street2)
                HStack(spacing: 8) {
                    Box("City", $contact.city)
                    Box("State or region", $contact.region)
                    Box("Postal code", $contact.postal)
                }
                HStack(spacing: 8) {
                    Box("Country", $contact.country)
                    Pill("Cancel", action: cancel)
                    Pill("Save", filled: true) { save(contact) }
                        .disabled(contact.isEmpty)
                }
            }
            .padding(14)
        }
    }

    private struct CardForm: View {
        let save: (PaymentCard) -> Void
        let cancel: () -> Void
        @State private var name = ""
        @State private var number = ""
        @State private var expiry = ""

        private var digits: String { number.filter(\.isNumber) }
        /// MM/YY, or MM/YYYY.
        private var parsed: (Int, Int)? {
            let parts = expiry.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard parts.count == 2, (1...12).contains(parts[0]) else { return nil }
            let year = parts[1] < 100 ? 2000 + parts[1] : parts[1]
            return (parts[0], year)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Box("Card number", $number)
                    Box("MM/YY", $expiry).frame(width: 90)
                }
                HStack(spacing: 8) {
                    Box("Name on card", $name)
                    Pill("Cancel", action: cancel)
                    Pill("Save", filled: true) {
                        guard let (month, year) = parsed else { return }
                        save(PaymentCard(name: name.trimmingCharacters(in: .whitespaces), number: digits, month: month, year: year))
                    }
                    .disabled(!PaymentCard.valid(digits) || parsed == nil)
                }
                if !digits.isEmpty && !PaymentCard.valid(digits) && digits.count >= 12 {
                    Text("That number doesn't check out — a digit may be off.")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.unsafe)
                }
            }
            .padding(14)
        }
    }

    private struct Box: View {
        let name: String
        @Binding var text: String
        init(_ name: String, _ text: Binding<String>) {
            self.name = name
            _text = text
        }

        var body: some View {
            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(name).foregroundStyle(Palette.ink.opacity(0.3)).padding(.leading, 10)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
            }
            .font(.system(size: 12.5))
            .background(Palette.wash, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }
}
