# math-synth

An instrument plugin written in Zig that turns a math formula into a waveform.
It builds as both a VST3 and an Audio Unit, so it works in GarageBand and Logic
as well as VST3 hosts.

![Editor](docs/editor.png)

Type a formula in `x`, choose the `x` range that makes up one period, and the
synth plays that shape as a single-cycle wavetable. The editor checks the input
on every keystroke: valid input updates the preview and the sound right away.
Invalid input shows the error and points at it, and the last valid waveform
keeps playing.

## Formula language

| | |
|---|---|
| Variable | `x` |
| Constants | `pi`, `tau`, `e` |
| Operators | `+ - * / % ^`. `^` is right associative and binds tighter than unary minus, so `-x^2 = -(x^2)`. `%` is floored modulo. |
| Implicit multiplication | `2x`, `3sin(x)`, `(x+1)(x-1)`, `2pi` |
| Functions (1 arg) | `sin cos tan asin acos atan sinh cosh tanh exp ln log log2 sqrt cbrt abs floor ceil round trunc frac sign` |
| Functions (2 args) | `atan2 pow min max mod` |
| Functions (3 args) | `clamp(v, lo, hi)` |

`log` is base 10 and `ln` is natural. The **from** and **to** fields take
constant expressions such as `-pi` or `4*pi`.

Some examples to try:

| Formula | from | to |
|---|---|---|
| `sin(x)` | `0` | `2pi` |
| `x` (saw) | `0` | `1` |
| `sign(sin(x))` (square) | `0` | `2pi` |
| `abs(frac(x) - 0.5)` (triangle) | `0` | `1` |
| `sin(x) + 0.5sin(2x) + 0.25sin(3x)` | `0` | `2pi` |
| `tanh(4sin(x))` | `0` | `2pi` |
| `sin(x)exp(-x/4) + 0.3sign(sin(3x))` | `0` | `4pi` |

The formula is sampled into a 2048-point table across `[from, to)`. The table
is then centred (DC removed) and peak-normalised, so any formula plays at a
reasonable level. A formula that isn't finite anywhere in the range (for
example `1/x` across 0) is rejected.

## Building

You need Zig 0.16 and macOS. The editor uses Cocoa.

```bash
zig build -Doptimize=ReleaseFast
```

This produces `zig-out/MathSynth.vst3` and `zig-out/MathSynth.component`. To
sign both ad hoc and copy them into `~/Library/Audio/Plug-Ins`:

```bash
zig build install-plugin -Doptimize=ReleaseFast
```

Use `install-vst3` or `install-au` to install just one of them.

To run the unit tests:

```bash
zig build test
```

## Using it in GarageBand or Logic

1. Run `zig build install-au -Doptimize=ReleaseFast`. This also restarts the
   macOS Audio Unit registrar so the new build is picked up.
2. Optionally, check it with Apple's validator, which GarageBand also relies on:
   ```bash
   auval -v aumu MSyn Mthx
   ```
3. In GarageBand, make sure **Settings → Audio/MIDI → Enable Audio Units** is
   checked. It's off by default.
4. Quit and reopen GarageBand. Create a **Software Instrument** track, open the
   track's **Smart Controls** (press B), and under **Plug-ins** click the
   instrument slot. Choose **Audio Units → MathSynth → MathSynth**.
5. Click the plugin slot again to open the editor.

If it isn't listed, run `killall -9 AudioComponentRegistrar` and restart the
app. In Logic you can also rescan it from **Logic Pro → Settings → Plug-in
Manager**.

## VST3 hosts

`zig build install-vst3 -Doptimize=ReleaseFast`, then rescan plugins in your
DAW (REAPER, Bitwig, Ableton Live, Cubase and so on).

## Test hosts

Two minimal hosts check the built bundles without a DAW.

```bash
zig build host -- info
zig build host -- render out.wav "sin(x) + 0.3sin(5x)" 0 2pi
zig build host -- snapshot editor.png "tanh(4sin(x))"
zig build host -- gui
```

`host` drives the VST3. `render` loads the formula through the plugin state
and plays an arpeggio into a WAV file. `snapshot` opens the editor off-screen,
types the given formula/from/to into its fields and saves a PNG. `gui` opens
the editor in a window. It has no audio output.

```bash
zig build au-host -- info
zig build au-host -- render out.wav x 0 1
zig build au-host -- snapshot editor.png "sin(x"
```

`au-host` does the same for the Audio Unit without installing it. It
registers the component in-process, then only uses the public Audio Unit API:
state goes through `ClassInfo`, notes through `MusicDeviceMIDIEvent`, and the
editor is created through the `CocoaUI` view factory, the way Logic and
GarageBand do it.

GarageBand and Logic run third-party Audio Units in a separate helper process
(`AUHostingService`) and show the editor remotely. To check that path against
the installed plugin:

```bash
zig build install-au && zig build au-oop
```

`zig build au-oop -- render 48000` also plays A4 through the out-of-process
unit with AVAudioEngine and reports its level and measured pitch.

## Layout

| Path | Contents |
|---|---|
| `src/expr.zig` | Tokenizer, recursive-descent parser and stack-machine evaluator, with error positions |
| `src/wavetable.zig` | Input validation, table building, lock-free triple buffer to the audio thread |
| `src/synth.zig` | 16-voice wavetable oscillator with attack/release |
| `src/engine.zig` | Format-independent core: synth, table handoff, settings and saved state |
| `src/plugin.zig` | VST3 factory, component/processor/controller, plug view |
| `src/au.zig` | Audio Unit v2 music device: properties, MIDI queue, render, view factory glue |
| `src/au_view.m` | The AU view factory class (Objective-C, because AU hosts look it up by name in the bundle) |
| `src/gui/objc.zig` | Thin Objective-C runtime and CoreGraphics bindings |
| `src/gui/editor.zig` | The Cocoa editor, shared by both formats |
| `vendor/vst3_c_api` | Steinberg's VST3 C API header (BSD-3 licence), translated with `translate-c` at build time |

The VST3 is a single component: one object implements `IComponent`,
`IAudioProcessor` and `IEditController`, so the editor and the audio engine
share state directly. Both formats save the formula, from and to strings in
the plugin state (the AU puts them in `ClassInfo`), so projects and presets
reopen with the same sound.

The Audio Unit is identified as type `aumu`, subtype `MSyn`, manufacturer
`Mthx`.

## Current limits

- macOS only. The DSP and VST3 parts are portable, but there is no
  Windows or Linux editor yet.
- The Audio Unit is v2 and expects to run in the host's process. GarageBand
  and Logic do this for native Apple Silicon plugins.
- No band-limiting, so harsh shapes (saw, square) alias on high notes.
- There are no automatable parameters yet, so envelope times and gain are
  fixed.
