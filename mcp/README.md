# Claude in Search

Claude Code can use Search the way Claude in Chrome uses Chrome: it opens
tabs, reads pages, clicks, types, presses keys, scrolls and takes
screenshots.

## Set it up

1. In Search, turn on Settings › General › **Let a script drive Search**.
2. To let Claude use your own tabs as well, also turn on **Let Claude use your
   tabs**. Without it, Claude works only in tabs it opens itself. They have a
   flask and never take the window from you.
3. Add the server to Claude Code:

   ```sh
   claude mcp add --scope user search -- python3 /path/to/Search/mcp/search_mcp.py
   ```

   The server needs only Python 3's standard library. To drive a
   `SEARCH_PROBE` run instead of your browser, set `SEARCH_WORLD=test`.

## The tools

| Tool | What it does |
|---|---|
| `tabs_context` | Lists the tabs Claude may use: the ones it opened, and yours if allowed |
| `tabs_create`, `tabs_close`, `tab_show` | Open a tab of Claude's at any size, close it, or bring it to the front |
| `navigate` | Go to a URL, or back, forward, reload, `hard` (past the cache), and wait for the page to load |
| `resize_page` | Give a tab of Claude's another viewport size: a phone's (with its user agent), a tablet's, a wide screen's |
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
  layout.
- **Fresh after a change.** `navigate` with `hard` reloads past the cache.

## Safety

- Claude reaches only web pages. It never reaches a private tab, an
  extension's page (a password manager's vault is one) or a `file:` address.
- Your tabs are off-limits until you turn on "Let Claude use your tabs".
  Until then Claude can't even see their addresses. Turning off "Let a script
  drive Search" turns it off too.
- Keys Claude presses never reach Search itself. A key the page doesn't use
  stops there instead of going to your window. ⌘ keys are sent to the page as
  its own events, so ⌘W can't close your tab and ⌘Q can't quit.
- A `<select>` is set with `form_input`, never clicked open: its menu would
  hold the whole app. For the same reason, a right-click is sent to the page
  as events.
- `javascript_tool` runs in the page's own world only, never in Search's.
  Code that throws is reported, not run a second time.
- Any program running as you can use the socket while "Let a script drive
  Search" is on. Keep it off when you aren't using Claude with Search.

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
