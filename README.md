# Tugboat

An Omarchy Quattro bar widget for aria2 HTTP/FTP/SFTP downloads, magnet links, and `.torrent` files.

## Install

Install `aria2` using your system package manager, then use the plugin folder directly:

```sh
omarchy plugin add /home/dki/Desktop/open-source/tugboat --enable
```

To install from GitHub instead:

```sh
omarchy plugin add https://github.com/korex-f/tugboat.git --enable
```

With an interactive `--enable` install, Omarchy asks whether to place Tugboat on the left, center, or right of the bar. This is the standard placement flow for bar-widget plugins; non-interactive installs use Tugboat's right-side default.

The first panel open creates `~/.config/tugboat/` (mode `0700`), generates a random RPC secret, chooses a free loopback port unless configured otherwise, writes a mode-`0600` aria2 configuration, and enables a user systemd service. No aria2 configuration is required.

## Video and audio URLs

Tugboat checks submitted URLs with yt-dlp. Ordinary file URLs, magnets, and torrents continue to aria2 unchanged. A URL recognized by yt-dlp opens a format picker with **Highest available quality**, **Audio only**, and the available resolutions for that item. Choosing a numbered resolution selects the best stream at or below that height, with audio merged by ffmpeg.

Playlist URLs stay playlists. Tugboat creates a folder named after the playlist in the selected download directory and names each entry like `01. Video title.ext`, using yt-dlp's playlist index and title. The picker shows the detected video count before you start the job.

yt-dlp uses its Python API and progress hooks; video jobs appear beside aria2 jobs in the same queue with the same progress, speed, ETA, pause, resume, remove, completion, and failure behavior. Raw media transfers are delegated to `aria2c` as yt-dlp’s external downloader.

Both `yt-dlp` and `ffmpeg` must already be installed. Tugboat checks this at startup and shows a clear panel error if either is absent; it never installs packages itself. An extraction error for a media site is shown in the panel.

## Queue cleanup

**Remove** stops an active job or removes one queue/history entry. **Pause all** and **Resume all** apply to both aria2 and media jobs. **Clear finished** removes all completed and failed queue entries at once. Neither action deletes downloaded files from disk.

## Panel layout

The panel is organized as a compact download center: a live aria2 status header, one URL/magnet input that also accepts `.torrent` files dropped anywhere on the panel, an icon-only queue toolbar, and transfer cards with progress and primary pause/resume actions. Secondary per-transfer actions are behind the `⋯` menu. The header gear opens the settings surface, which contains the current download directory, bandwidth control, aria2 health, and browser-extension connection flow.

## Browser connection

Choose **Connect** beside the browser family you use. **Chromium browsers** covers Chrome, Brave, Vivaldi, Edge, Opera, and Chromium; **Firefox-based browsers** covers Firefox and Zen. It opens the relevant store page and displays a one-time local connection payload.

1. Install the extension from the store page that opens, then open its Options or Settings page.
2. Copy the payload’s `rpcUrl` value into the extension field named **RPC URL**, **JSON-RPC URL**, or similar. Keep the `/jsonrpc` suffix.
3. Copy `rpcSecret` into the extension field named **RPC secret**, **Secret key**, or **Token**. Use the raw value as shown; do not add `token:` unless that extension explicitly asks for it.
4. Save the extension settings and send a small download or magnet link to confirm that it reaches Tugboat.

The payload is shown only for the current handoff. It is cleared when you close Settings or Tugboat, and it appears again only after you click **Connect**. Keep the secret private: it authorizes local aria2 RPC requests.

The extension-store Install button must be clicked by the user. This plugin does not sideload or inject extensions. It also does not install a native-messaging host because neither supported store flow requires one for direct local aria2 RPC; if an extension build explicitly requires one, use that extension’s signed, documented host package.

The daemon listens only on `127.0.0.1`. The secret is never logged; it is only read for local RPC calls and rendered in the explicitly requested browser handoff field.

## Manual fallback

Start the daemon with `systemctl --user enable --now ~/.config/tugboat/tugboat-aria2.service`, then configure an aria2-compatible extension with the URL and secret in `~/.config/tugboat/config.json` (keep that file private). Change global bandwidth in the plugin Settings view or through aria2-compatible clients.

## Troubleshooting

If the panel says aria2 is unavailable, install `aria2`, reopen the panel, and inspect `systemctl --user status tugboat-aria2.service`. An RPC authentication error generally means another local client changed the secret; remove only `~/.config/tugboat/` to reprovision, knowing that this resets the plugin’s aria2 session state.

## Remove

Disable and remove the plugin with:

```sh
omarchy plugin remove io.github.dki.tugboat
```

This removes the plugin only. To also remove Tugboat's local aria2 service,
configuration, and download history, run `systemctl --user disable --now
tugboat-aria2.service` and then remove `~/.config/tugboat/`. Downloaded files
in your download directory are not removed.
