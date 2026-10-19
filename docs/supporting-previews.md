# Browser and artifact previews

Supporting browser tabs use native WebKit for browsing and local development previews. Cmd+T opens about:blank and focuses its address field. Cmd+L focuses the address when a browser has focus. Back, Forward, and Reload/Stop act on that tab's live page. The address accepts HTTP(S), localhost addresses, and about:blank. Other schemes offer an explicit external-open button. Script and inline-data addresses are rejected.

Download links and file responses keep the current page and its live input. An explicit Open externally action hands the URL to the default browser. Spookky does not download files automatically or retain a background download manager.

The supporting-panel menu opens local artifacts. Markdown and UTF-8 text appear as selectable, read-only native text. Markdown source remains literal, including HTML and script strings. Images and PDFs use NSImageView and PDFKit. Text and HTML are limited to 2 MiB. Text also uses the existing 20,000-line limit. Images and PDFs are limited to 20 MiB. Images above 40 million pixels are refused before decoding. Missing, oversized, and unsupported files show a notice and an external-open action.

HTML artifacts run as self-contained documents in a nonpersistent WebKit store. Inline scripts, inline styles, and embedded data images/fonts/media are allowed. A prepended content security policy blocks network requests, external scripts, frames, objects, form submission, and local base URLs. A WebKit content blocker also denies HTTP(S), FTP, and file subresources. The document has no local-file base URL or native JavaScript bridge. Relative project assets are unavailable. The user can open the original file externally when those assets are required. HTML links require the explicit external-open action.

The browser store belongs to this app identity and runtime root. It does not use Safari or Chrome profile data. Sites use their ordinary authentication flow. There is no credential extraction or agent browser interface.

## Retention and resource cost

Browser and artifact views are cached by SupportingTab.id. Rendering persisted title/URL callbacks does not navigate the page. Switching conversations or tabs, hiding a conversation, collapsing the panel, and expanding to full width reparent the same view. Restored descriptors create no WebKit views until selected. Closed IDs dispose observations, delegates, and loading work. Retained IDs are never silently evicted to meet a memory target.

Each visited browser or HTML artifact adds a retained WebKit surface and may add WebKit helper processes. A WebKit process failure shows a recovery notice. It never silently reloads a live form. Process failure and app restart can lose unsent page state; only route, title, selection, and layout metadata persist.

## Verification

Run the policy tests with `swift test --jobs 2 --filter SupportingPreviewPolicyTests`. After building this worktree's development app, run `python3 scripts/check_supporting_previews.py`. The native fixture owns a disposable data root, a private socket, a localhost server, and the coordinated GUI lock. `--hold 240` keeps the fixture app available for native accessibility and screenshot inspection. It never opens the installed app or starts a provider.

The fixture covers real page navigation, title callbacks, retained browser forms, inline HTML counters, native artifact rendering, error states, lazy restoration, closed-view release, and primary-shell preservation. It records a separate app/helper resource sample. Physical keyboard, spoken VoiceOver, long-duration retention, provider authentication, and full six-worker integration require separate acceptance.
