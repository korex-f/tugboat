# Tugboat

An Omarchy Quattro bar widget for aria2 HTTP/FTP/SFTP downloads, magnet links, and `.torrent` files.

## Install

Install `aria2` using your system package manager, then use the plugin folder directly:

```sh
omarchy plugin add /home/dki/Desktop/open-source/tugboat --enable
```

The first panel open creates `~/.config/tugboat/` (mode `0700`), generates a random RPC secret, chooses a free loopback port unless configured otherwise, writes a mode-`0600` aria2 configuration, and enables a user systemd service. No aria2 configuration is required.

## Video and audio URLs

Tugboat checks submitted URLs with yt-dlp. Ordinary file URLs, magnets, and torrents continue to aria2 unchanged. A URL recognized by yt-dlp opens a format picker with **Best quality**, **Audio only**, and the available resolutions for that item.

yt-dlp uses its Python API and progress hooks; video jobs appear beside aria2 jobs in the same queue with the same progress, speed, ETA, pause, resume, remove, completion, and failure behavior. Raw media transfers are delegated to `aria2c` as yt-dlp’s external downloader.

Both `yt-dlp` and `ffmpeg` must already be installed. Tugboat checks this at startup and shows a clear panel error if either is absent; it never installs packages itself. An extraction error for a media site is shown in the panel.

## Queue cleanup

**Remove** stops an active job or removes one queue/history entry. **Pause all** and **Resume all** apply to both aria2 and media jobs. **Clear finished** removes all completed and failed queue entries at once. Neither action deletes downloaded files from disk.

## Browser connection

Choose **Connect Chrome** or **Connect Firefox**. It opens the relevant store page and reveals a one-time local JSON payload containing the RPC URL and secret. Paste those values into the extension’s connection options after installing it.

The extension-store Install button must be clicked by the user. This plugin does not sideload or inject extensions. It also does not install a native-messaging host because neither supported store flow requires one for direct local aria2 RPC; if an extension build explicitly requires one, use that extension’s signed, documented host package.

The daemon listens only on `127.0.0.1`. The secret is never logged; it is only read for local RPC calls and rendered in the explicitly requested browser handoff field.

## Manual fallback

Start the daemon with `systemctl --user enable --now ~/.config/tugboat/tugboat-aria2.service`, then configure an aria2-compatible extension with the URL and secret in `~/.config/tugboat/config.json` (keep that file private). Change global bandwidth in the plugin Settings view or through aria2-compatible clients.

## Troubleshooting

If the panel says aria2 is unavailable, install `aria2`, reopen the panel, and inspect `systemctl --user status tugboat-aria2.service`. An RPC authentication error generally means another local client changed the secret; remove only `~/.config/tugboat/` to reprovision, knowing that this resets the plugin’s aria2 session state.
