# Claude in Search

Claude Code can use Search the way Claude in Chrome uses Chrome: it opens
tabs, reads pages, clicks, types, presses keys, scrolls and takes
screenshots.

## Set it up

1. In Search, turn on Settings › General › **Let Claude use Search** and pick
   how far it reaches (see [Access levels](#access-levels)). It stays as you
   set it from one launch to the next.
2. Add the server to Claude Code:

   ```sh
   claude mcp add --scope user search -- python3 /path/to/Search/mcp/search_mcp.py
   ```

   The server needs only Python 3's standard library. To drive a
   `SEARCH_PROBE` run instead of your browser, set `SEARCH_WORLD=test`.

## The tools

| Tool | What it does |
|---|---|
| `tabs_context` | Lists the tabs Claude may use: the ones it opened, and yours if allowed |
| `tabs_create`, `tabs_close`, `tab_show` | Open a tab of Claude's at any size (as a phone with `mobile`), close it, or bring it to the front |
| `navigate` | Go to a URL, or back, forward, reload, `hard` (every file checked with the server, as ⇧⌘R), `empty` (the site's cache emptied first), and wait for the page to load |
| `resize_page` | Give a tab of Claude's another viewport size: a phone's (with its user agent, the page loaded again for it), a tablet's, a wide screen's. It keeps it in your window too |
| `read_page` | Lists what can be used on the page, one element per line with a ref and its place on screen. Same-site frames and shadow DOM included |
| `find` | Finds elements by their words |
| `get_page_text` | The page's text, or the text under one ref |
| `computer` | Clicks, drags, types, presses keys, scrolls, hovers, waits, takes a screenshot of the page or of one element |
| `form_input` | Sets a field, select or checkbox directly |
| `upload_file` | Puts files from the Mac into a file field, or drops them on a drop zone |
| `wait_for` | Waits for a selector, some text, or the page to go quiet (no fetch or XHR open) |
| `handle_dialog` | Sets how the next confirm, prompt or login is answered, or lists what was asked |
| `javascript_tool` | Runs JavaScript in the page and returns the result, awaiting promises |
| `read_console_messages` | Console output, uncaught errors, failed files and CSP blocks |
| `read_network_requests` | Every file, fetch and XHR, with status, time and failures |
| `batch` | Several steps in one call |

## Building web pages with it

- **From the first line.** Claude's own tabs and any page served from this Mac
  (localhost, 127.x, *.local, *.test) have their console, errors and requests
  recorded from the start of the page. Other pages are recorded from the
  first time Claude asks.
- **Nothing blocks.** An alert, confirm, prompt, login or file chooser in a
  tab of Claude's is answered on the spot and reported with the next result.
  It would otherwise open on a window nobody sees and hold the page forever.
  A pop-up the page opens becomes a tab of Claude's too.
- **Any size.** `resize_page` 390×844 with `mobile: true` shows the phone
  layout, with an iPhone's user agent: the page loads again for it, so the
  site serves what it serves a phone. It answers once the page has laid
  itself out at the new size. Brought to the front of your window, by Claude
  or by a click on its tab, the tab keeps that size, in the middle, the way
  a responsive design mode shows a page. `tabs_create` with `mobile: true`
  opens a tab as a phone from its first request.
- **Fresh after a change.** `navigate` with `hard` checks every file with the
  server and drops what a service worker kept, as ⇧⌘R does. `empty` empties
  the site's cache first, for a server that says a changed file hasn't
  changed.

## Access levels

One setting, **Let Claude use Search**, decides how far Claude reaches. Each
level allows everything the one before it does, and more.

| Level | Claude's own tabs | Your tabs | Clipboard |
|---|---|---|---|
| **Off** | — the socket is closed, for `./bench` too | — | — |
| **Its own tabs** (lowest risk) | Signed in to nothing of yours: a cookie store of Claude's own, kept between launches, with no extensions in it. *Forget Claude's sign-ins* empties it | Not seen, not even their addresses | No |
| **Signed in as you** | Share your cookies and sign-ins: what you are signed in to, Claude is too | Not seen | No |
| **Your tabs too** (highest risk) | As above | The one in front and the others — read, click, type, bring forward | ⌘C, ⌘X, ⌘V |

Changing the level closes Claude's tabs that don't fit the new one: going
down to *Its own tabs* closes every tab of Claude's that was signed in as
you.

The level is kept in Search's settings and, beside it, as a mark in the
keychain that only Search itself can write. A level the settings file says
without that mark — written by another program, or left by a build of Search
signed another way — isn't taken on its word: Search starts at the level the
mark allows and asks at the bottom of the window, *Allow* or *Don't allow*.

## Safety

- Claude reaches only web pages. It never reaches a private tab, an
  extension's page (a password manager's vault is one) or a `file:` address,
  at any level.
- Below *Your tabs too*, your tabs are off-limits: Claude can't even see
  their addresses, through the MCP server or through the socket itself.
- From *Signed in as you* up, Claude's own tabs are signed in as you. Pick
  *Its own tabs* when Claude doesn't need your accounts.
- Copy, cut and paste reach your clipboard only at *Your tabs too*; below it
  Claude types text instead.
- Keys Claude presses never reach Search itself. A key the page doesn't use
  stops there instead of going to your window. ⌘ keys are sent to the page as
  its own events, so ⌘W can't close your tab and ⌘Q can't quit.
- A `<select>` is set with `form_input`, never clicked open: its menu would
  hold the whole app. For the same reason, a right-click is sent to the page
  as events.
- `javascript_tool` runs in the page's own world only, never in Search's.
  Code that throws is reported, not run a second time.
- Any program running as you can use the socket while "Let Claude use
  Search" is on, with the same reach as Claude. Keep it off when you aren't
  using Claude with Search.
- A request that runs out of time is answered as failed and stops there: the
  steps of a batch after it are not done.

## How it's faster than a Chrome extension

- **One local socket.** No extension, no background worker and no Chrome
  DevTools Protocol in between. A read or a find takes a few milliseconds.
- **Refs, not selectors.** `read_page` gives every element a ref (`r12`).
  The same element keeps the same ref across reads, and an action names it.
- **Real events.** Clicks and keys go to the page's view as NSEvents, so the
  page can't tell them from a person's. Typing is one insert, like Chrome's
  `Input.insertText`, and keeps its order with the keys around it.
- **Screenshots in CSS pixels.** A point on the picture is the point to click.
- **Waiting is built in.** A click or a key that starts loading a page answers
  once the page has loaded.
- **`batch`** runs a whole sequence in one round trip, for example click, type,
  Enter, wait, read.
- **Out of sight.** The reading runs in Search's own isolated world, so the
  page sees none of it. Only JavaScript you run and the console listener are
  in the page's world.
