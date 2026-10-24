# dsh-a11y-warmup

Make Electron apps readable by UI Automation — including DeepSeek Harness's own
window — **without** launching them with `--force-renderer-accessibility`.

This is a [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
plugin bundle: install it into a profile and `accessibility_tree`, `find`,
`invoke`, `set_value` and element-id clicks start working on the app's real
controls instead of falling back to OCR and guessed coordinates.

## The problem

Chromium builds its accessibility tree lazily. A freshly started Electron window
reports only:

```
Window
└─ RootView
   └─ NonClientView
      └─ WinFrameView
         ├─ WinCaptionButtonContainer   (minimize / maximize / close)
         └─ ClientView                  (empty)
```

About 7 nodes, no sidebar, no input box, no buttons. Two things are needed to
fix that, and the second one is the one everybody misses:

1. **Knock**: send `WM_GETOBJECT` (`0x003D`) with `UiaRootObjectId` (`-25`) to the
   renderer's `Chrome_RenderWidgetHostHWND`. This switches Chromium's
   accessibility mode on.
2. **Enter**: attach an actual UI Automation client to that renderer window
   (`AutomationElement.FromHandle` + `FindAll(Descendants)`). Only then is the
   web content tree built and bridged into the parent window's UIA tree.

Doing (1) alone leaves the window at ~14 nodes: the browser-side views appear,
the page does not. That was the first version of this plugin and it did not work.

Measured on the same window:

| State | `accessibility_tree` nodes |
|---|---|
| nothing | 7 |
| after `WM_GETOBJECT` only | 14 (`RootWebArea` still absent) |
| after client attach | 100+ with `RootWebArea`, `Button "新建会话"`, `Edit "发消息…"` … |

## How it works

A small PowerShell watcher runs as a child of the DSH host:

- scans every top-level window every `intervalMs`
- keeps only the configured process names
- for each `Chrome_RenderWidgetHostHWND` it finds: knock, then attach with a
  full descendant walk
- if the walk returns 0 nodes (page not rendered yet), retries every 10 s
- once content exists, does a shallow keepalive walk every 45 s

On a cold start of DeepSeek Harness the tree is ready about 27 s after launch.

## Install

```powershell
dsh plugin --profile desktop add file:C:\path\to\dsh-a11y-warmup
```

or from a checkout:

```powershell
dsh plugin --profile desktop add link:C:\path\to\dsh-a11y-warmup
```

## Config

In the profile's `cordis.patch.yml`, or in this bundle's own patch:

```yaml
- id: a11y-warmup
  config:
    targets:            # process names, without .exe
      - DeepSeek Harness
    intervalMs: 4000    # rescan interval; new windows are picked up here
```

## Behaviour

- One watcher per user session: a lock file (`%TEMP%\dsh-a11y-warmup.lock`,
  opened `FileShare.None`) plus a named mutex. A second host process loading the
  same profile backs off instead of duplicating every scan.
- The watcher is a child of the DSH host and dies with it.
- Log: `%TEMP%\dsh-a11y-warmup.log`.

## Limits

- **Electron only.** Verified on DeepSeek Harness and on an unrelated Electron
  app. Google Chrome's renderer exposes nothing even after the attach, and
  transparent/click-through windows never bridge to their parent — use
  `--force-renderer-accessibility` or a DOM-level tool for those.
- Windows only (PowerShell + user32).
- `nodeLinker: hoisted` copies this package into the profile's `node_modules`
  instead of symlinking it, so editing the source requires reinstalling.

## Cost

Chromium keeps maintaining the tree once it is enabled: a little memory and CPU
per warmed window. Processes not listed in `targets` are never touched.

## License

MIT
