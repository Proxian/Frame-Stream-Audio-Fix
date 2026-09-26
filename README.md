# frame-stream-audio-fix

Unofficial workaround for **Steam Frame audio dying while streaming games from a PC**: the volume popup appears in the headset, then there's no sound until you restart the stream or the game.

## What's going on

Nothing is wrong with your PC, Windows audio drivers or Discord. The problem is on the headset.

While you stream from a PC, the Frame's audio server (**PipeWire**) gets killed by the kernel. PipeWire runs its audio thread with real-time priority, and Linux limits how long a real-time thread may run without pausing (`RLIMIT_RTTIME`, 200 ms on the Frame). Something in the streaming audio path goes over that limit, the kernel sends `SIGKILL`, and PipeWire restarts (that restart is the volume popup). The streaming client (`vrlink`) never reconnects its audio to the new PipeWire, so you get silence until the stream restarts.

In testing it happened repeatedly during PC streaming, sometimes within 30 seconds of a session starting, and never in standalone play.

### Check whether this is your problem

In Desktop Mode, open Konsole and run:

```
journalctl --user -u pipewire | grep "status=9/KILL"
```

If there are lines at the times your audio cut out, this is it.

## What the script does

While a PC stream (`vrlink`) is running, it moves the real-time audio threads of `pipewire`, `pipewire-pulse` and `wireplumber` to high-priority normal scheduling (nice -11). The kernel limit only applies to real-time threads, so PipeWire can't be killed that way. When the stream ends, it asks rtkit to make the threads real-time again, so standalone play runs exactly as SteamOS ships it.

- No sudo, and no system files changed. Everything lives in your home folder:
  - `~/.local/bin/frame-stream-audio-fix`
  - `~/.config/systemd/user/frame-stream-audio-fix.service`
  - `~/.local/state/frame-stream-audio-fix.log`
- Nothing is installed on your PC.
- Stopping or uninstalling it puts the threads back to real-time immediately, even in the middle of a stream.

**Result in testing:** a 53-minute PC streaming session with zero PipeWire kills and no audio drops. Without the script, PipeWire was killed 6 times the same evening.

## Install

In Desktop Mode, open Konsole:

```
curl -fsSLO https://raw.githubusercontent.com/YOUR-USERNAME/frame-stream-audio-fix/main/frame-stream-audio-fix.sh
less frame-stream-audio-fix.sh        # read it first, it's short
bash frame-stream-audio-fix.sh install
```

It starts right away and on every boot. If a stream has already lost its audio, restart that stream.

## Use

```
bash ~/.local/bin/frame-stream-audio-fix status      # running? how many PipeWire kills in the last 7 days?
bash ~/.local/bin/frame-stream-audio-fix uninstall   # remove everything
```

## Caveats

- **Unofficial.** It has only been tested on one Frame (SteamOS build `20260923.6105317`, PipeWire 1.6.8, vrlink 2.17.10). Use it at your own risk.
- Without real-time priority, audio could in theory crackle under very heavy load while streaming. None was heard in testing.
- **Remove it once Valve fixes this.** A proper fix belongs in SteamOS: keep long-running work off PipeWire's real-time threads, and have vrlink reconnect its audio when PipeWire restarts.

## Please report it to Valve

help.steampowered.com, then Steam Hardware, then Steam Frame. The more reports that name the actual cause (PipeWire SIGKILLed by `RLIMIT_RTTIME` during vrlink streaming), the faster it gets fixed.

## License

MIT. See [LICENSE](LICENSE).
