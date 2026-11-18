# builtin-display

Turn a MacBook's built-in display off while you work on external monitors, with the lid open, and keep it off after sleep and login.

macOS has no setting for this. With the lid open, the built-in panel stays on as an extra screen. `builtin-display` disables it the way display utilities do when they "disconnect" a display: macOS stops treating it as a screen, so windows and the pointer cannot end up there.

It is one Swift file with no dependencies.

## Requirements

- An Apple Silicon MacBook with at least one external display connected. It has not been tested on Intel Macs.
- The Xcode Command Line Tools, for the Swift compiler: `xcode-select --install`
- Tested on macOS 27.3 on an M1 Max MacBook Pro.

## Install

```sh
git clone https://github.com/ssoonngg123/builtin-display.git
cd builtin-display
./install.sh
```

This builds the program, installs it to `~/.local/bin/builtin-display`, and starts a login agent that turns the built-in display off whenever an external display is connected.

To use the commands without the login agent, build it yourself instead:

```sh
swiftc -O builtin-display.swift -o builtin-display
```

## Usage

| Command | What it does |
|---|---|
| `builtin-display off` | Turn the built-in display off. Refuses if no external display is active, so you are never left without a screen. |
| `builtin-display on` | Turn it back on and keep it on until the next `off`. |
| `builtin-display list` | Show the connected displays and whether the built-in one is off. |
| `builtin-display watch` | Stay running and turn the built-in display off whenever it comes back. The login agent runs this. |

macOS turns the built-in display back on at login and after sleep. The watcher notices within a few seconds and turns it off again, so expect the panel to light up briefly after a wake.

`builtin-display on` pauses the watcher. Run `builtin-display off` to resume.

The watcher logs each time it acts to `~/Library/Logs/builtin-display.log`.

## If something goes wrong

The setting only lasts for the current login session. Restarting the Mac brings the built-in display back.

## How it works

The program calls `CGSConfigureDisplayEnabled`, a private CoreGraphics function, inside a normal display configuration transaction. Private functions are undocumented and can change or disappear in any macOS update.

Two things about this call shaped the watcher:

- A process that has disabled the display never sees it come back. Its own list of displays stops updating.
- macOS does not deliver display-change callbacks to a plain command-line process.

So the watcher never changes the configuration itself. It polls the display list every 2 seconds, which is cheap and read-only, and starts a fresh `builtin-display check` process to do the switching. A second check runs once a minute as a safety net.

## Uninstall

```sh
./uninstall.sh
```

This stops the login agent, turns the built-in display back on, and removes the program, the agent, the log and the two small state files in your home folder.

## License

MIT. See [LICENSE](LICENSE).
