# math-synth

A VST3 instrument written in Zig that turns a math formula into a waveform.

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

You need Zig 0.16 and macOS. The editor uses Cocoa through the Objective-C
runtime.

```bash
zig build -Doptimize=ReleaseFast
```

This produces `zig-out/MathSynth.vst3`. To sign the bundle ad hoc and copy it
to `~/Library/Audio/Plug-Ins/VST3`:

```bash
zig build install-plugin -Doptimize=ReleaseFast
```

Then rescan plugins in your DAW (REAPER, Bitwig, Ableton Live, Cubase and so
on). GarageBand and Logic only load Audio Units, not VST3.

To run the unit tests:

```bash
zig build test
```

## Test host

`tools/host.zig` is a minimal VST3 host for checking the bundle without a DAW:

```bash
zig build host -- info
zig build host -- render out.wav "sin(x) + 0.3sin(5x)" 0 2pi
zig build host -- snapshot editor.png "tanh(4sin(x))"
zig build host -- gui
```

`render` loads the formula through the plugin state and plays an arpeggio
into a WAV file. `snapshot` opens the editor off-screen, types the given
formula/from/to into its fields and saves a PNG. `gui` opens the editor in a
window. It has no audio output.

## Layout

| Path | Contents |
|---|---|
| `src/expr.zig` | Tokenizer, recursive-descent parser and stack-machine evaluator, with error positions |
| `src/wavetable.zig` | Input validation, table building, lock-free triple buffer to the audio thread |
| `src/synth.zig` | 16-voice wavetable oscillator with attack/release |
| `src/plugin.zig` | VST3 factory, component/processor/controller, plug view, state save/load |
| `src/gui/objc.zig` | Thin Objective-C runtime and CoreGraphics bindings |
| `src/gui/editor.zig` | The Cocoa editor |
| `vendor/vst3_c_api` | Steinberg's VST3 C API header (BSD-3 licence), translated with `translate-c` at build time |

The plugin is a single component: one object implements `IComponent`,
`IAudioProcessor` and `IEditController`, so the editor and the audio engine
share state directly. The formula, from and to strings are saved in the
plugin state, so projects and presets reopen with the same sound.

## Current limits

- macOS only. The DSP and VST3 parts are portable, but there is no
  Windows or Linux editor yet.
- No band-limiting, so harsh shapes (saw, square) alias on high notes.
- There are no automatable parameters yet, so envelope times and gain are
  fixed.
