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
| `tabs_context` | Lists the tabs: which one is in front and which ones Claude opened |
| `tabs_create`, `tabs_close`, `tab_show` | Open a tab of Claude's, close it, or bring it to the front |
| `navigate` | Go to a URL, or back, forward, reload, and wait for the page to load |
| `read_page` | Lists what can be used on the page, one element per line with a ref and its place on screen |
| `find` | Finds elements by their words |
| `get_page_text` | The page's text, or the text under one ref |
| `computer` | Clicks, types, presses keys, scrolls, hovers, waits, takes a screenshot |
| `form_input` | Sets a field, select or checkbox directly |
| `wait_for` | Waits until a selector matches or some text is on the page |
| `javascript_tool` | Runs JavaScript and returns the result, awaiting promises |
| `read_console_messages`, `read_network_requests` | What the page logged and what it loaded |
| `batch` | Several steps in one call |

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
