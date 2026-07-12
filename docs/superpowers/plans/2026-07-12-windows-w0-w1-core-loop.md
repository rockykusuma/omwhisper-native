# OmWhisper Windows — W0 Bootstrap + W1 Core Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **HANDOFF NOTE:** This plan executes in a **brand-new repo `omwhisper-windows`**, not in
> `omwhisper-native`. It is written to be self-contained. The spec is
> `docs/superpowers/specs/2026-07-12-windows-native-app-design.md` in the `omwhisper-native`
> repo — copy it into the new repo's `docs/` first. The Mac app (`omwhisper-native`) is the
> functional spec: when behavior is ambiguous, do what the Mac app does.

**Goal:** Native Windows dictation app skeleton (W0) + measurable core dictation loop MVP (W1): global hotkey/PTT → WASAPI mic capture → sherpa-onnx streaming transcription → live overlay partials → paste into the foreground app on stop.

**Architecture:** Tray-first WPF app, single observable `AppState` store, engines behind `ITranscriptionEngine` returning `IAsyncEnumerable<TranscriptEvent>`. Audio and inference run off the UI thread via `Channel<T>`; `AppState` is touched only on the UI thread (Dispatcher).

**Tech Stack:** C# / .NET 10 (LTS) · WPF (`net10.0-windows`) · NAudio (WASAPI) · sherpa-onnx (NuGet `org.k2fsa.sherpa.onnx`) · xUnit · GitHub Actions (windows-latest).

## Global Constraints

- Windows 11 baseline, **any CPU** — x64 + ARM64 (`win-x64;win-arm64` RIDs). No GPU/NPU requirement.
- TFM `net10.0-windows` everywhere. `<UseWPF>true</UseWPF>`; app project also `<UseWindowsForms>true</UseWindowsForms>` (tray `NotifyIcon` only).
- **Single observable store rule:** all settings/state live in `AppState`; no view ever does its own settings read-modify-write.
- **Verify-dependency-APIs-live rule:** before writing code against sherpa-onnx or NAudio APIs, verify the API shape against the library's current source/examples (sherpa-onnx: `github.com/k2-fsa/sherpa-onnx/tree/master/dotnet-examples`). Remembered API shapes have caused real live-only failures in this project's history.
- **Testing rule:** xUnit for pure logic only. NO UI-automation tests. Everything platform-touching (audio, hooks, overlay, paste) is verified live on a real Windows 11 PC — a platform feature is not "done" until seen live.
- **Threading rule:** audio callbacks and inference never touch UI objects; marshal via `Dispatcher`. No blocking the UI thread on inference.
- Per-monitor DPI aware (PerMonitorV2) from day one.
- Keyboard hook matches registered chords only — it must never log or buffer keystrokes.
- Text is never silently dropped: any failure between stop and paste surfaces to the user (overlay error state) and, once history exists (W2), the transcript is still saved.
- Default hotkeys: toggle `Ctrl+Alt+D`, push-to-talk hold `Right Ctrl`. (Reconfigurable in W2 — hardcoded constants in W1, but read from single fields so W2 only swaps the source.)
- Commit style: `<type>(scope): message` (e.g. `feat(capture): ...`), frequent commits, one per task minimum.

---

## W0 — Bootstrap

### Task 1: Repo, solution, projects, CI

**Files:**
- Create: `.gitignore`, `OmWhisper.sln`, `src/OmWhisper/OmWhisper.csproj`, `tests/OmWhisper.Tests/OmWhisper.Tests.csproj`, `.github/workflows/ci.yml`, `README.md`

**Interfaces:**
- Produces: a building solution every later task adds to; test project referencing the app project.

- [ ] **Step 1: Initialize repo and projects**

```bash
git init omwhisper-windows && cd omwhisper-windows
dotnet new gitignore
dotnet new sln -n OmWhisper
dotnet new wpf -n OmWhisper -o src/OmWhisper
dotnet new xunit -n OmWhisper.Tests -o tests/OmWhisper.Tests
dotnet sln add src/OmWhisper tests/OmWhisper.Tests
dotnet add tests/OmWhisper.Tests reference src/OmWhisper
```

- [ ] **Step 2: Fix project files**

`src/OmWhisper/OmWhisper.csproj` — replace contents:

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <RuntimeIdentifiers>win-x64;win-arm64</RuntimeIdentifiers>
    <UseWPF>true</UseWPF>
    <UseWindowsForms>true</UseWindowsForms>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <ApplicationManifest>app.manifest</ApplicationManifest>
    <AssemblyName>OmWhisper</AssemblyName>
    <RootNamespace>OmWhisper</RootNamespace>
  </PropertyGroup>
</Project>
```

`tests/OmWhisper.Tests/OmWhisper.Tests.csproj` — set `<TargetFramework>net10.0-windows</TargetFramework>` and add `<UseWPF>true</UseWPF>` to its PropertyGroup (required to reference a WPF project).

Create `src/OmWhisper/app.manifest` (PerMonitorV2 DPI — non-negotiable global constraint):

```xml
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
</assembly>
```

- [ ] **Step 3: Verify build + test run**

Run: `dotnet build && dotnet test`
Expected: build succeeds; 1 placeholder xunit test passes.

- [ ] **Step 4: CI workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI
on: [push, pull_request]
jobs:
  build-test:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with: { dotnet-version: 10.0.x }
      - run: dotnet build --configuration Release
      - run: dotnet test --configuration Release
```

- [ ] **Step 5: README stub + commit**

`README.md`: one paragraph — "OmWhisper for Windows, native rewrite. See docs/ for the design spec. Mac sibling: omwhisper-native." Copy the design spec into `docs/`.

```bash
git add -A && git commit -m "chore: bootstrap solution, WPF app, tests, CI"
```

### Task 2: Tray-first app skeleton

**Files:**
- Modify: `src/OmWhisper/App.xaml`, `src/OmWhisper/App.xaml.cs`
- Create: `src/OmWhisper/Tray/TrayIcon.cs`
- Delete: `src/OmWhisper/MainWindow.xaml`, `src/OmWhisper/MainWindow.xaml.cs`

**Interfaces:**
- Produces: `TrayIcon` with `Action? OnToggleDictation`, `Action? OnQuit` callbacks and `void SetRecording(bool)`; `App` startup path every later task hooks into.

- [ ] **Step 1: Make App tray-first**

`App.xaml` — remove `StartupUri`, add `ShutdownMode="OnExplicitShutdown"`.

`App.xaml.cs`:

```csharp
using System.Windows;

namespace OmWhisper;

public partial class App : Application
{
    private Tray.TrayIcon? _tray;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _tray = new Tray.TrayIcon();
        _tray.OnQuit = () => Shutdown();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        base.OnExit(e);
    }
}
```

- [ ] **Step 2: TrayIcon via WinForms NotifyIcon**

`src/OmWhisper/Tray/TrayIcon.cs`:

```csharp
using System.Windows.Forms;

namespace OmWhisper.Tray;

public sealed class TrayIcon : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _toggleItem;
    public Action? OnToggleDictation;
    public Action? OnQuit;

    public TrayIcon()
    {
        _toggleItem = new ToolStripMenuItem("Start Dictation", null, (_, _) => OnToggleDictation?.Invoke());
        var menu = new ContextMenuStrip();
        menu.Items.Add(_toggleItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Quit OmWhisper", null, (_, _) => OnQuit?.Invoke()));
        _icon = new NotifyIcon
        {
            // ponytail: system placeholder icon; real brand .ico lands in W2
            Icon = System.Drawing.SystemIcons.Application,
            Text = "OmWhisper",
            Visible = true,
            ContextMenuStrip = menu,
        };
    }

    public void SetRecording(bool recording) => _toggleItem.Text = recording ? "Stop Dictation" : "Start Dictation";

    public void Dispose() { _icon.Visible = false; _icon.Dispose(); }
}
```

- [ ] **Step 3: Live-verify on the real PC**

Run: `dotnet run --project src/OmWhisper`
Expected: no window appears; tray icon shows; right-click menu shows Start Dictation / Quit; Quit exits the process cleanly (check Task Manager).

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(tray): tray-first app skeleton with NotifyIcon menu"
```

### Task 3: AppState + dictation phase machine (TDD)

**Files:**
- Create: `src/OmWhisper/AppState.cs`
- Test: `tests/OmWhisper.Tests/DictationPhaseTests.cs`

**Interfaces:**
- Produces: `enum DictationPhase { Idle, Starting, Recording, Stopping, Pasting }`; `AppState` class with `DictationPhase Phase { get; }`, `static bool CanStart(DictationPhase)`, `static bool CanStop(DictationPhase)`, and `event Action<DictationPhase>? PhaseChanged`. Task 9 adds the Start/Stop orchestration methods to this same class.

- [ ] **Step 1: Write failing tests**

`tests/OmWhisper.Tests/DictationPhaseTests.cs`:

```csharp
using OmWhisper;
using Xunit;

public class DictationPhaseTests
{
    [Theory]
    [InlineData(DictationPhase.Idle, true)]
    [InlineData(DictationPhase.Starting, false)]
    [InlineData(DictationPhase.Recording, false)]
    [InlineData(DictationPhase.Stopping, false)]
    [InlineData(DictationPhase.Pasting, false)]
    public void CanStart_OnlyFromIdle(DictationPhase phase, bool expected)
        => Assert.Equal(expected, AppState.CanStart(phase));

    [Theory]
    [InlineData(DictationPhase.Recording, true)]
    [InlineData(DictationPhase.Starting, true)]
    [InlineData(DictationPhase.Idle, false)]
    [InlineData(DictationPhase.Stopping, false)]
    [InlineData(DictationPhase.Pasting, false)]
    public void CanStop_FromStartingOrRecording(DictationPhase phase, bool expected)
        => Assert.Equal(expected, AppState.CanStop(phase));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `dotnet test`
Expected: FAIL — `DictationPhase`/`AppState` not defined.

- [ ] **Step 3: Minimal implementation**

`src/OmWhisper/AppState.cs`:

```csharp
namespace OmWhisper;

public enum DictationPhase { Idle, Starting, Recording, Stopping, Pasting }

public sealed class AppState
{
    private DictationPhase _phase = DictationPhase.Idle;
    public DictationPhase Phase
    {
        get => _phase;
        private set { if (_phase == value) return; _phase = value; PhaseChanged?.Invoke(value); }
    }
    public event Action<DictationPhase>? PhaseChanged;

    public static bool CanStart(DictationPhase p) => p == DictationPhase.Idle;
    public static bool CanStop(DictationPhase p) => p is DictationPhase.Starting or DictationPhase.Recording;

    // Task 9 replaces the bodies below with real orchestration.
    internal void SetPhaseForOrchestration(DictationPhase p) => Phase = p;
}
```

- [ ] **Step 4: Run tests**

Run: `dotnet test`
Expected: PASS (all).

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat(state): AppState with dictation phase machine"
```

---

## W1 — Core Loop

### Task 4: AudioCapture — WASAPI mic → 16kHz mono float chunks

**Files:**
- Create: `src/OmWhisper/Capture/AudioCapture.cs`

**Interfaces:**
- Produces: `AudioCapture` with `IAsyncEnumerable<float[]> Start()` (16kHz mono float chunks) and `void Stop()` (completes the stream). No pure helper to unit-test here — mono downmix and resampling both come from NAudio (`ToMono()`, `WdlResamplingSampleProvider`); this component is verified live in Task 10.

- [ ] **Step 1: Add NAudio**

```bash
dotnet add src/OmWhisper package NAudio
```

- [ ] **Step 2: AudioCapture (effectful, live-verified not unit-tested)**

Resampling uses NAudio's `WdlResamplingSampleProvider` (high quality, pure managed — do NOT hand-roll a linear resampler; ASR accuracy is core product value). Pattern: `WasapiCapture.DataAvailable` pushes into a `BufferedWaveProvider`; a reader task pulls through `ToSampleProvider() → ToMono() → WdlResamplingSampleProvider(16000)` and writes chunks to a `Channel<float[]>`.

`src/OmWhisper/Capture/AudioCapture.cs`:

```csharp
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace OmWhisper.Capture;

public sealed class AudioCapture
{
    private WasapiCapture? _capture;
    private Channel<float[]>? _channel;
    private CancellationTokenSource? _cts;

    public IAsyncEnumerable<float[]> Start()
    {
        _channel = Channel.CreateUnbounded<float[]>();
        _cts = new CancellationTokenSource();
        _capture = new WasapiCapture(); // default device; W2 adds the device picker (persist device ID, not name)

        var buffered = new BufferedWaveProvider(_capture.WaveFormat) { DiscardOnBufferOverflow = true };
        ISampleProvider samples = buffered.ToSampleProvider();
        if (_capture.WaveFormat.Channels > 1) samples = samples.ToMono();
        var resampled = new WdlResamplingSampleProvider(samples, 16000);

        _capture.DataAvailable += (_, e) => buffered.AddSamples(e.Buffer, 0, e.BytesRecorded);

        var token = _cts.Token;
        Task.Run(async () =>
        {
            var chunk = new float[1600]; // 100ms at 16k
            try
            {
                while (!token.IsCancellationRequested)
                {
                    var n = resampled.Read(chunk, 0, chunk.Length);
                    if (n > 0) await _channel.Writer.WriteAsync(chunk[..n], token);
                    else await Task.Delay(10, token); // buffer empty; wait for more mic data
                }
            }
            catch (OperationCanceledException) { }
            finally { _channel.Writer.TryComplete(); }
        });

        _capture.StartRecording();
        return _channel.Reader.ReadAllAsync();
    }

    public void Stop()
    {
        _capture?.StopRecording();
        _capture?.Dispose();
        _capture = null;
        _cts?.Cancel(); // reader loop drains and completes the channel
    }
}
```

Build check: `dotnet build` — Expected: succeeds. (Real audio verified live in Task 9's checklist.)

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(capture): WASAPI mic capture to 16k mono float chunks"
```

### Task 5: Keyboard hook — global hotkey + push-to-talk

**Files:**
- Create: `src/OmWhisper/Hotkeys/KeyboardHook.cs`, `src/OmWhisper/Hotkeys/ChordMatcher.cs`
- Test: `tests/OmWhisper.Tests/ChordMatcherTests.cs`

**Interfaces:**
- Produces: `KeyboardHook` (singleton lifetime, installed at startup) with events `Action? OnToggleChord`, `Action? OnPttDown`, `Action? OnPttUp`; pure `static bool ChordMatcher.Matches(int vk, bool ctrl, bool alt, bool shift, Chord chord)` with `record Chord(int Vk, bool Ctrl, bool Alt, bool Shift)`.
- Constants (W1 hardcoded, single source): toggle = `Chord(0x44 /*D*/, Ctrl: true, Alt: true, Shift: false)`; PTT key = `0xA3` (VK_RCONTROL).

- [ ] **Step 1: Failing tests for chord matching**

`tests/OmWhisper.Tests/ChordMatcherTests.cs`:

```csharp
using OmWhisper.Hotkeys;
using Xunit;

public class ChordMatcherTests
{
    private static readonly Chord ToggleChord = new(0x44, Ctrl: true, Alt: true, Shift: false);

    [Fact]
    public void Matches_ExactChord()
        => Assert.True(ChordMatcher.Matches(0x44, ctrl: true, alt: true, shift: false, ToggleChord));

    [Fact]
    public void Rejects_ExtraModifier()
        => Assert.False(ChordMatcher.Matches(0x44, ctrl: true, alt: true, shift: true, ToggleChord));

    [Fact]
    public void Rejects_MissingModifier()
        => Assert.False(ChordMatcher.Matches(0x44, ctrl: true, alt: false, shift: false, ToggleChord));

    [Fact]
    public void Rejects_WrongKey()
        => Assert.False(ChordMatcher.Matches(0x45, ctrl: true, alt: true, shift: false, ToggleChord));
}
```

Run: `dotnet test` — Expected: FAIL.

- [ ] **Step 2: Implement ChordMatcher**

`src/OmWhisper/Hotkeys/ChordMatcher.cs`:

```csharp
namespace OmWhisper.Hotkeys;

public record Chord(int Vk, bool Ctrl, bool Alt, bool Shift);

public static class ChordMatcher
{
    public static bool Matches(int vk, bool ctrl, bool alt, bool shift, Chord chord)
        => vk == chord.Vk && ctrl == chord.Ctrl && alt == chord.Alt && shift == chord.Shift;
}
```

Run: `dotnet test` — Expected: PASS.

- [ ] **Step 3: Implement KeyboardHook (WH_KEYBOARD_LL)**

Hook hygiene rules (from the spec, non-negotiable): callback does minimal work and returns fast; **skips injected events** (`LLKHF_INJECTED`) so our own synthetic Ctrl+V never re-enters; never logs or buffers keys; events marshal to the UI thread via the captured `Dispatcher`.

`src/OmWhisper/Hotkeys/KeyboardHook.cs`:

```csharp
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace OmWhisper.Hotkeys;

public sealed class KeyboardHook : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101, WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;
    private const uint LLKHF_INJECTED = 0x10;
    private const int VK_LCONTROL = 0xA2, VK_RCONTROL = 0xA3, VK_LMENU = 0xA4, VK_RMENU = 0xA5,
                      VK_LSHIFT = 0xA0, VK_RSHIFT = 0xA1;

    public static readonly Chord ToggleChord = new(0x44 /*D*/, Ctrl: true, Alt: true, Shift: false);
    public const int PttVk = VK_RCONTROL;

    public Action? OnToggleChord;
    public Action? OnPttDown;
    public Action? OnPttUp;

    private readonly Dispatcher _dispatcher;
    private readonly LowLevelKeyboardProc _proc; // kept as a field so GC never collects the delegate
    private readonly IntPtr _hook;
    private bool _ctrl, _alt, _shift, _pttHeld;

    public KeyboardHook(Dispatcher dispatcher)
    {
        _dispatcher = dispatcher;
        _proc = Callback;
        using var module = Process.GetCurrentProcess().MainModule!;
        _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(module.ModuleName), 0);
        if (_hook == IntPtr.Zero) throw new InvalidOperationException("SetWindowsHookEx failed");
    }

    private IntPtr Callback(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0) return CallNextHookEx(_hook, code, wParam, lParam);
        var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        if ((data.flags & LLKHF_INJECTED) != 0) return CallNextHookEx(_hook, code, wParam, lParam);

        var msg = wParam.ToInt32();
        var down = msg is WM_KEYDOWN or WM_SYSKEYDOWN;
        var vk = (int)data.vkCode;

        switch (vk)
        {
            case VK_LCONTROL or VK_RCONTROL: _ctrl = down || OtherHeld(vk, VK_LCONTROL, VK_RCONTROL); break;
            case VK_LMENU or VK_RMENU: _alt = down || OtherHeld(vk, VK_LMENU, VK_RMENU); break;
            case VK_LSHIFT or VK_RSHIFT: _shift = down || OtherHeld(vk, VK_LSHIFT, VK_RSHIFT); break;
        }

        if (vk == PttVk)
        {
            if (down && !_pttHeld) { _pttHeld = true; _dispatcher.BeginInvoke(() => OnPttDown?.Invoke()); }
            else if (!down && _pttHeld) { _pttHeld = false; _dispatcher.BeginInvoke(() => OnPttUp?.Invoke()); }
        }
        else if (down && ChordMatcher.Matches(vk, _ctrl, _alt, _shift, ToggleChord))
        {
            _dispatcher.BeginInvoke(() => OnToggleChord?.Invoke());
        }

        return CallNextHookEx(_hook, code, wParam, lParam);
    }

    private static bool OtherHeld(int released, int left, int right)
        => (GetAsyncKeyState(released == left ? right : left) & 0x8000) != 0;

    public void Dispose() => UnhookWindowsHookEx(_hook);

    private delegate IntPtr LowLevelKeyboardProc(int code, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT { public uint vkCode, scanCode, flags, time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetModuleHandle(string lpModuleName);
}
```

Build check: `dotnet build` — Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(hotkeys): low-level keyboard hook with toggle chord + PTT"
```

### Task 6: ITranscriptionEngine contract + SherpaEngine + model spike

**Files:**
- Create: `src/OmWhisper/Transcription/ITranscriptionEngine.cs`, `src/OmWhisper/Transcription/SherpaEngine.cs`, `src/OmWhisper/Transcription/ModelDownloader.cs`
- Test: `tests/OmWhisper.Tests/TranscriptAssemblerTests.cs` (assembler lives in `ITranscriptionEngine.cs`)

**Interfaces:**
- Produces:

```csharp
public abstract record TranscriptEvent
{
    public sealed record Partial(string Text) : TranscriptEvent;
    public sealed record Final(string Text) : TranscriptEvent;
}

public interface ITranscriptionEngine
{
    IAsyncEnumerable<TranscriptEvent> TranscribeAsync(
        IAsyncEnumerable<float[]> audio,          // 16kHz mono float chunks
        IReadOnlyList<string> vocabulary,          // W1: pass empty list; biasing wired in W2
        CancellationToken ct);
}

public static class TranscriptAssembler
{
    // Joins finalized segments + trailing partial into the text to paste.
    public static string Assemble(IReadOnlyList<string> finals, string? trailingPartial);
}
```

- Consumes: Task 4's `IAsyncEnumerable<float[]>`.

- [ ] **Step 1: VERIFY sherpa-onnx API against live source (standing rule — do not skip)**

Before writing engine code: fetch and read `https://github.com/k2-fsa/sherpa-onnx/tree/master/dotnet-examples` (the streaming/online decode example) and the NuGet package README for `org.k2fsa.sherpa.onnx`. Confirm the current names for: `OnlineRecognizer`, `OnlineRecognizerConfig` (feature config sample rate/dim, transducer model paths, tokens path, decoding method, hotwords fields, endpoint fields), `CreateStream()`, `AcceptWaveform`, `IsReady`, `Decode`, `GetResult`, `IsEndpoint`, `Reset`. **Adjust the code in Step 4 to whatever the live API actually is** — the shapes below are the expected pattern, not gospel. Record any differences in the commit message.

- [ ] **Step 2: TDD the pure assembler**

`tests/OmWhisper.Tests/TranscriptAssemblerTests.cs`:

```csharp
using OmWhisper.Transcription;
using Xunit;

public class TranscriptAssemblerTests
{
    [Fact]
    public void JoinsFinalsWithSpaces()
        => Assert.Equal("hello world. next part.", TranscriptAssembler.Assemble(new[] { "hello world.", "next part." }, null));

    [Fact]
    public void AppendsTrailingPartial()
        => Assert.Equal("done. still going", TranscriptAssembler.Assemble(new[] { "done." }, "still going"));

    [Fact]
    public void EmptyInputs_YieldEmpty()
        => Assert.Equal("", TranscriptAssembler.Assemble(System.Array.Empty<string>(), null));

    [Fact]
    public void PartialOnly()
        => Assert.Equal("just partial", TranscriptAssembler.Assemble(System.Array.Empty<string>(), "just partial"));
}
```

Run: `dotnet test` — Expected: FAIL. Then implement in `ITranscriptionEngine.cs`:

```csharp
public static class TranscriptAssembler
{
    public static string Assemble(IReadOnlyList<string> finals, string? trailingPartial)
    {
        var parts = finals.Where(f => !string.IsNullOrWhiteSpace(f)).ToList();
        if (!string.IsNullOrWhiteSpace(trailingPartial)) parts.Add(trailingPartial.Trim());
        return string.Join(" ", parts);
    }
}
```

Run: `dotnet test` — Expected: PASS.

- [ ] **Step 3: ModelDownloader**

Models live in `%LOCALAPPDATA%\OmWhisper\models\<model-name>\`. "Ready" means **downloaded on disk** (all listed files exist), never loaded-in-memory (the Mac download-state lesson). Download from sherpa-onnx's published model releases (`https://github.com/k2-fsa/sherpa-onnx/releases` — verify current URLs in the spike, Step 5) with `HttpClient`, `IProgress<double>`, `.partial`-file-then-rename so a killed download never reads as Ready.

`src/OmWhisper/Transcription/ModelDownloader.cs`:

```csharp
namespace OmWhisper.Transcription;

public sealed record ModelSpec(string Name, string ArchiveUrl, string[] RequiredFiles);

public static class ModelDownloader
{
    public static string ModelsDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OmWhisper", "models");

    public static string DirFor(ModelSpec spec) => Path.Combine(ModelsDir, spec.Name);

    public static bool IsReady(ModelSpec spec)
        => spec.RequiredFiles.All(f => File.Exists(Path.Combine(DirFor(spec), f)));

    public static async Task DownloadAsync(ModelSpec spec, IProgress<double> progress, CancellationToken ct)
    {
        var dir = DirFor(spec);
        Directory.CreateDirectory(dir);
        var archive = Path.Combine(dir, "model.tar.bz2.partial");
        using (var http = new HttpClient())
        using (var resp = await http.GetAsync(spec.ArchiveUrl, HttpCompletionOption.ResponseHeadersRead, ct))
        {
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? -1;
            await using var src = await resp.Content.ReadAsStreamAsync(ct);
            await using var dst = File.Create(archive);
            var buf = new byte[81920]; long read = 0; int n;
            while ((n = await src.ReadAsync(buf, ct)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n), ct);
                read += n;
                if (total > 0) progress.Report((double)read / total);
            }
        }
        ExtractInto(archive, dir); // sherpa models ship as .tar.bz2: use SharpCompress (add package) — verify archive format in the spike
        File.Delete(archive);
        if (!IsReady(spec)) throw new InvalidOperationException($"Model {spec.Name} incomplete after extract");
    }

    private static void ExtractInto(string archivePath, string dir)
    {
        // Implement with SharpCompress (dotnet add src/OmWhisper package SharpCompress):
        // open archive, extract entries flattened into dir (model archives nest a top-level folder).
        using var archive = SharpCompress.Archives.ArchiveFactory.Open(archivePath);
        foreach (var entry in archive.Entries.Where(e => !e.IsDirectory))
        {
            var fileName = Path.GetFileName(entry.Key!);
            using var s = entry.OpenEntryStream();
            using var f = File.Create(Path.Combine(dir, fileName));
            s.CopyTo(f);
        }
    }
}
```

```bash
dotnet add src/OmWhisper package SharpCompress
```

- [ ] **Step 4: SherpaEngine**

```bash
dotnet add src/OmWhisper package org.k2fsa.sherpa.onnx
```

Lifecycle: persistent recognizer, loaded once (multi-second load), one stream per dictation session — the Mac `ParakeetEngine` pattern. Endpoint-terminated segments map to `.Final`; in-flight text maps to `.Partial` (the Mac `SpeechTranscriber` volatile/finalized mapping).

`src/OmWhisper/Transcription/SherpaEngine.cs` (adjust names per Step 1's verification):

```csharp
using System.Runtime.CompilerServices;
using SherpaOnnx;

namespace OmWhisper.Transcription;

public sealed class SherpaEngine : ITranscriptionEngine, IDisposable
{
    private readonly ModelSpec _spec;
    private OnlineRecognizer? _recognizer;
    private readonly object _lock = new();

    public SherpaEngine(ModelSpec spec) => _spec = spec;

    private OnlineRecognizer Recognizer
    {
        get
        {
            lock (_lock)
            {
                if (_recognizer != null) return _recognizer;
                var dir = ModelDownloader.DirFor(_spec);
                var config = new OnlineRecognizerConfig();
                config.FeatConfig.SampleRate = 16000;
                config.FeatConfig.FeatureDim = 80;
                config.ModelConfig.Transducer.Encoder = Path.Combine(dir, "encoder.onnx");
                config.ModelConfig.Transducer.Decoder = Path.Combine(dir, "decoder.onnx");
                config.ModelConfig.Transducer.Joiner = Path.Combine(dir, "joiner.onnx");
                config.ModelConfig.Tokens = Path.Combine(dir, "tokens.txt");
                config.DecodingMethod = "greedy_search"; // W2 vocab biasing switches to modified_beam_search + hotwords
                config.EnableEndpoint = 1;
                _recognizer = new OnlineRecognizer(config);
                return _recognizer;
            }
        }
    }

    public async IAsyncEnumerable<TranscriptEvent> TranscribeAsync(
        IAsyncEnumerable<float[]> audio,
        IReadOnlyList<string> vocabulary,
        [EnumeratorCancellation] CancellationToken ct)
    {
        var recognizer = Recognizer;                 // triggers lazy load off the UI thread (caller runs this in a Task)
        using var stream = recognizer.CreateStream();
        var lastPartial = "";

        await foreach (var chunk in audio.WithCancellation(ct))
        {
            stream.AcceptWaveform(16000, chunk);
            while (recognizer.IsReady(stream)) recognizer.Decode(stream);

            var text = recognizer.GetResult(stream).Text;
            if (recognizer.IsEndpoint(stream))
            {
                if (!string.IsNullOrWhiteSpace(text)) yield return new TranscriptEvent.Final(text);
                recognizer.Reset(stream);
                lastPartial = "";
            }
            else if (text != lastPartial && !string.IsNullOrWhiteSpace(text))
            {
                lastPartial = text;
                yield return new TranscriptEvent.Partial(text);
            }
        }

        // Mic stream ended (user released PTT / toggled off): flush what's left as final.
        stream.InputFinished();
        while (recognizer.IsReady(stream)) recognizer.Decode(stream);
        var tail = recognizer.GetResult(stream).Text;
        if (!string.IsNullOrWhiteSpace(tail)) yield return new TranscriptEvent.Final(tail);
    }

    public void Dispose() { lock (_lock) { _recognizer?.Dispose(); _recognizer = null; } }
}
```

Build check: `dotnet build` — Expected: succeeds (fix any API-name drift found in Step 1).

- [ ] **Step 5: THE MODEL SPIKE (decides the default model — gate for W1 sign-off)**

On the real PC, from sherpa-onnx's published **streaming (online) model list** (verify current list at `https://k2-fsa.github.io/sherpa/onnx/pretrained_models/online-transducer/index.html`), pick 2–3 English candidates across size tiers (e.g. a streaming Zipformer small + large; a NeMo streaming FastConformer if published). For each: download, run a scripted dictation (same 3 sentences incl. technical vocabulary), measure with `Stopwatch` logging:
1. first-partial latency from first audio chunk,
2. partial cadence (feels live?),
3. final WER by eyeball against the script,
4. sustained CPU% during dictation.

Write the results table + the decision into `docs/MODEL_SPIKE.md` in the new repo, set the winning `ModelSpec` as the app default, and commit. **If no streaming model gives acceptable quality, stop and re-plan W1 around an offline-model sliding-window approach (the Mac FluidAudio pattern) before proceeding.**

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "feat(engine): sherpa-onnx streaming engine + model downloader + default model from spike"
```

### Task 7: Overlay window (minimal Full-style pill)

**Files:**
- Create: `src/OmWhisper/UI/OverlayWindow.xaml`, `src/OmWhisper/UI/OverlayWindow.xaml.cs`

**Interfaces:**
- Produces: `OverlayWindow` with `void ShowOver(IntPtr targetHwnd)`, `void SetPartial(string)`, `void SetFinalized(string)`, `void SetStatus(string)` (e.g. "LISTENING", "FINISHING"), `void HideOverlay()`. W1 ships only the Full-style pill; Orb/Whisper-line styles are a W2+ port.

- [ ] **Step 1: XAML — dark pill, never activates**

`src/OmWhisper/UI/OverlayWindow.xaml`:

```xml
<Window x:Class="OmWhisper.UI.OverlayWindow"
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowActivated="False" ShowInTaskbar="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize">
    <Border CornerRadius="18" Background="#F0071A12" Padding="16,10" MaxWidth="560">
        <StackPanel>
            <TextBlock x:Name="StatusLabel" Text="LISTENING" FontSize="10" Foreground="#7FE0C9"
                       FontWeight="SemiBold" Margin="0,0,0,4"/>
            <TextBlock x:Name="TranscriptText" FontSize="14" Foreground="#EAF6F0" TextWrapping="Wrap"/>
        </StackPanel>
    </Border>
</Window>
```

(Colors are the Mac dark-HUD family — emerald-on-green-black; exact token port happens with the design-system pass in W2.)

- [ ] **Step 2: Code-behind — click-through + non-activating + positioning**

`src/OmWhisper/UI/OverlayWindow.xaml.cs`:

```csharp
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Interop;
using System.Windows.Media;

namespace OmWhisper.UI;

public partial class OverlayWindow : Window
{
    private const int GWL_EXSTYLE = -20;
    private const long WS_EX_TRANSPARENT = 0x20, WS_EX_TOOLWINDOW = 0x80, WS_EX_NOACTIVATE = 0x08000000;

    public OverlayWindow()
    {
        InitializeComponent();
        SourceInitialized += (_, _) =>
        {
            var hwnd = new WindowInteropHelper(this).Handle;
            var ex = GetWindowLongPtr(hwnd, GWL_EXSTYLE).ToInt64();
            SetWindowLongPtr(hwnd, GWL_EXSTYLE, new IntPtr(ex | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE));
        };
    }

    public void ShowOver(IntPtr targetHwnd)
    {
        SetPartial(""); SetStatus("LISTENING");
        Show();
        PositionBottomCenterOf(targetHwnd);
    }

    public void SetStatus(string s) => StatusLabel.Text = s;
    public void SetPartial(string s) { TranscriptText.Text = s; TranscriptText.Opacity = 0.65; Reposition(); }
    public void SetFinalized(string s) { TranscriptText.Text = s; TranscriptText.Opacity = 1.0; Reposition(); }
    public void HideOverlay() => Hide();

    private IntPtr _target;
    private void PositionBottomCenterOf(IntPtr hwnd) { _target = hwnd; Reposition(); }

    private void Reposition()
    {
        // Bottom-center of the monitor containing the target window, in WPF DIPs (per-monitor DPI aware).
        var monitor = MonitorFromWindow(_target, 2 /*MONITOR_DEFAULTTONEAREST*/);
        var info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
        if (!GetMonitorInfo(monitor, ref info)) return;
        var dpi = VisualTreeHelper.GetDpi(this);
        UpdateLayout();
        var workW = (info.rcWork.right - info.rcWork.left) / dpi.DpiScaleX;
        var workBottom = info.rcWork.bottom / dpi.DpiScaleY;
        var workLeft = info.rcWork.left / dpi.DpiScaleX;
        Left = workLeft + (workW - ActualWidth) / 2;
        Top = workBottom - ActualHeight - 24;
    }

    [StructLayout(LayoutKind.Sequential)] private struct RECT { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
}
```

Build check: `dotnet build` — Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add -A && git commit -m "feat(overlay): non-activating click-through overlay pill"
```

### Task 8: PasteService

**Files:**
- Create: `src/OmWhisper/Paste/PasteService.cs`

**Interfaces:**
- Produces: `static IntPtr PasteService.CaptureForegroundWindow()`; `static bool IsElevated(IntPtr hwnd)`; `static async Task<PasteResult> PasteAsync(string text, IntPtr targetHwnd)` with `enum PasteResult { Pasted, BlockedElevated, NoTarget }`. Never a silent no-op (Mac paste-hardening rule).

- [ ] **Step 1: Implement**

`src/OmWhisper/Paste/PasteService.cs`:

```csharp
using System.Runtime.InteropServices;
using System.Windows;

namespace OmWhisper.Paste;

public enum PasteResult { Pasted, BlockedElevated, NoTarget }

public static class PasteService
{
    public static IntPtr CaptureForegroundWindow() => GetForegroundWindow();

    public static bool IsElevated(IntPtr hwnd)
    {
        GetWindowThreadProcessId(hwnd, out var pid);
        var h = OpenProcess(0x1000 /*PROCESS_QUERY_LIMITED_INFORMATION*/, false, pid);
        if (h == IntPtr.Zero) return true; // can't even query it → assume elevated (UIPI would block us anyway)
        try
        {
            if (!OpenProcessToken(h, 0x0008 /*TOKEN_QUERY*/, out var token)) return true;
            try
            {
                int elevation = 0, size = sizeof(int);
                GetTokenInformation(token, 20 /*TokenElevation*/, ref elevation, size, out _);
                return elevation != 0;
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(h); }
    }

    public static async Task<PasteResult> PasteAsync(string text, IntPtr targetHwnd)
    {
        if (targetHwnd == IntPtr.Zero) return PasteResult.NoTarget;
        if (IsElevated(targetHwnd)) return PasteResult.BlockedElevated; // caller surfaces "run as administrator to paste here"

        var saved = Clipboard.ContainsText() ? Clipboard.GetText() : null; // ponytail: text-only save/restore; rich formats if users complain
        Clipboard.SetText(text);
        SetForegroundWindow(targetHwnd);
        await Task.Delay(50);            // let focus settle
        SendCtrlV();
        await Task.Delay(300);           // let the target read the clipboard before restore (Mac timing)
        if (saved != null) Clipboard.SetText(saved); else Clipboard.Clear();
        return PasteResult.Pasted;
    }

    private static void SendCtrlV()
    {
        const ushort VK_CONTROL = 0x11, VK_V = 0x56;
        const uint KEYEVENTF_KEYUP = 0x2;
        var inputs = new[]
        {
            KeyInput(VK_CONTROL, 0), KeyInput(VK_V, 0),
            KeyInput(VK_V, KEYEVENTF_KEYUP), KeyInput(VK_CONTROL, KEYEVENTF_KEYUP),
        };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    private static INPUT KeyInput(ushort vk, uint flags) => new()
    { type = 1 /*INPUT_KEYBOARD*/, U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = flags } } };

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT { public uint type; public InputUnion U; }
    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion { [FieldOffset(0)] public KEYBDINPUT ki; [FieldOffset(0)] public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
    [DllImport("kernel32.dll")] private static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
    [DllImport("advapi32.dll")] private static extern bool OpenProcessToken(IntPtr proc, uint access, out IntPtr token);
    [DllImport("advapi32.dll")] private static extern bool GetTokenInformation(IntPtr token, int infoClass, ref int info, int size, out int retSize);
}
```

Build check: `dotnet build` — Expected: succeeds.

- [ ] **Step 2: Commit**

```bash
git add -A && git commit -m "feat(paste): SendInput Ctrl+V paste with clipboard restore + UIPI detection"
```

### Task 9: Wire the core loop

**Files:**
- Modify: `src/OmWhisper/AppState.cs`, `src/OmWhisper/App.xaml.cs`

**Interfaces:**
- Consumes: everything above. Produces: `AppState.ToggleDictation()`, `AppState.StartDictation()`, `AppState.StopDictation()` — called from tray menu, toggle chord, and PTT down/up.

- [ ] **Step 1: Orchestration in AppState**

Replace the placeholder region of `src/OmWhisper/AppState.cs` with:

```csharp
using OmWhisper.Capture;
using OmWhisper.Paste;
using OmWhisper.Transcription;
using OmWhisper.UI;

public sealed partial class AppState   // split: make the Task-3 class `partial`, or merge — one class either way
{
    private readonly AudioCapture _audio = new();
    private readonly ITranscriptionEngine _engine;
    private readonly OverlayWindow _overlay;
    private readonly List<string> _finals = new();
    private string? _trailingPartial;
    private IntPtr _targetHwnd;
    private Task? _sessionTask;

    public AppState(ITranscriptionEngine engine, OverlayWindow overlay)
    { _engine = engine; _overlay = overlay; }

    public void ToggleDictation()
    { if (CanStart(Phase)) StartDictation(); else if (CanStop(Phase)) StopDictation(); }

    public void StartDictation()
    {
        if (!CanStart(Phase)) return;
        SetPhaseForOrchestration(DictationPhase.Starting);
        _targetHwnd = PasteService.CaptureForegroundWindow();   // BEFORE the overlay shows
        _finals.Clear(); _trailingPartial = null;
        _overlay.ShowOver(_targetHwnd);

        var audioStream = _audio.Start();
        var dispatcher = System.Windows.Application.Current.Dispatcher;
        SetPhaseForOrchestration(DictationPhase.Recording);

        _sessionTask = Task.Run(async () =>
        {
            try
            {
                await foreach (var ev in _engine.TranscribeAsync(audioStream, Array.Empty<string>(), CancellationToken.None))
                {
                    switch (ev)
                    {
                        case TranscriptEvent.Partial(var text):
                            _trailingPartial = text;
                            await dispatcher.BeginInvoke(() => _overlay.SetPartial(TranscriptAssembler.Assemble(_finals, text)));
                            break;
                        case TranscriptEvent.Final(var text):
                            _finals.Add(text); _trailingPartial = null;
                            await dispatcher.BeginInvoke(() => _overlay.SetFinalized(TranscriptAssembler.Assemble(_finals, null)));
                            break;
                    }
                }
            }
            catch (Exception ex)
            {
                await dispatcher.BeginInvoke(() => _overlay.SetStatus($"ERROR: {ex.Message}")); // text is never silently dropped
                await Task.Delay(2000);
            }
        });
    }

    public async void StopDictation()
    {
        if (!CanStop(Phase)) return;
        SetPhaseForOrchestration(DictationPhase.Stopping);
        _overlay.SetStatus("FINISHING");
        _audio.Stop();                                   // completes the stream → engine flushes finals
        if (_sessionTask != null) await _sessionTask;    // drain

        var text = TranscriptAssembler.Assemble(_finals, _trailingPartial);
        SetPhaseForOrchestration(DictationPhase.Pasting);
        _overlay.HideOverlay();
        if (!string.IsNullOrWhiteSpace(text))
        {
            var result = await PasteService.PasteAsync(text, _targetHwnd);
            if (result == PasteResult.BlockedElevated)
                _tray?.ShowBalloon("Can't paste into an elevated app", "Run OmWhisper as administrator to paste here. Text is on the clipboard.");
            // BlockedElevated still leaves the text on the clipboard: skip the restore in that path (adjust PasteAsync call order accordingly).
        }
        SetPhaseForOrchestration(DictationPhase.Idle);
    }

    private Tray.TrayIcon? _tray;
    public void AttachTray(Tray.TrayIcon tray)
    {
        _tray = tray;
        PhaseChanged += p => tray.SetRecording(p is DictationPhase.Recording or DictationPhase.Starting);
    }
}
```

Note on the elevated path: modify `PasteService.PasteAsync` so `BlockedElevated` is returned **after** `Clipboard.SetText(text)` and skips the restore — the user's words must survive on the clipboard. Add `ShowBalloon(string title, string text)` to `TrayIcon` (`_icon.ShowBalloonTip(4000, title, text, ToolTipIcon.Warning)`).

- [ ] **Step 2: Wire it all in App.OnStartup**

```csharp
protected override void OnStartup(StartupEventArgs e)
{
    base.OnStartup(e);
    var overlay = new UI.OverlayWindow();
    var engine = new Transcription.SherpaEngine(DefaultModel); // the ModelSpec chosen by the Task 6 spike
    _state = new AppState(engine, overlay);
    _tray = new Tray.TrayIcon();
    _tray.OnToggleDictation = () => _state.ToggleDictation();
    _tray.OnQuit = () => Shutdown();
    _state.AttachTray(_tray);
    _hook = new Hotkeys.KeyboardHook(Dispatcher);
    _hook.OnToggleChord = () => _state.ToggleDictation();
    _hook.OnPttDown = () => _state.StartDictation();
    _hook.OnPttUp = () => _state.StopDictation();
}
```

If the default model isn't downloaded yet (`!ModelDownloader.IsReady(DefaultModel)`), the tray menu gets a "Download model…" item that runs `ModelDownloader.DownloadAsync` and balloons progress at 25/50/75/100% — first-run UX polish is W2's onboarding job, this just makes W1 usable.

- [ ] **Step 3: Build + full test suite**

Run: `dotnet build && dotnet test`
Expected: build succeeds; all tests pass.

- [ ] **Step 4: Commit**

```bash
git add -A && git commit -m "feat(core): wire hotkey/PTT -> capture -> engine -> overlay -> paste loop"
```

### Task 10: W1 live verification (real PC — this IS the W1 gate)

No code. Run through this checklist on the physical Windows 11 machine and record results (numbers, not adjectives) in `docs/W1_VERIFICATION.md`:

- [ ] Model downloads with progress; kill mid-download → still shows not-Ready (no false Ready — the `.partial` rename guard works).
- [ ] Hold Right-Ctrl in Notepad, speak a sentence, release: partials appear in the overlay while speaking (**measure: <1s behind speech**), text pastes into Notepad (**measure stop-to-paste with `Stopwatch` logs: <700ms typical**), clipboard's prior content is restored.
- [ ] `Ctrl+Alt+D` toggles the same flow in a browser text field (partial lag + paste both verified there too).
- [ ] PTT keydown → capture starts instantly (no perceptible delay before the overlay shows LISTENING).
- [ ] Overlay: never steals focus (caret stays blinking in the target app), click passes through it, positions on the correct monitor in a 2-monitor + mixed-DPI setup if available.
- [ ] Paste into an elevated app (e.g. an admin Terminal): balloon appears, text is on the clipboard, no silent loss.
- [ ] Empty dictation (start, say nothing, stop): no paste, no crash, clean return to Idle.
- [ ] Rapid double-toggle and PTT-during-toggle-session: no crash, no stuck phase (the `CanStart`/`CanStop` guards hold).
- [ ] Quit from tray while recording: process exits cleanly, hook uninstalled (typing works normally afterward).
- [ ] Task Manager during dictation: CPU load matches the spike's numbers; UI stays responsive.

```bash
git add docs/W1_VERIFICATION.md && git commit -m "docs: W1 live verification results"
```

---

## W2–W5 Milestone Briefs (expand into full plans at execution time)

These are deliberately briefs, not task lists — each becomes its own plan (this same format) written when reached, because their details depend on W1's spike results and live learnings. The Mac repo is the functional spec throughout: **port behavior and pure logic; rebuild platform code natively.**

### W2 — Daily-driver parity
Settings window (Porcelain design system — port tokens from `omwhisper-native` `UI/OmColors.swift` + the `omwhisper-design` skill; WPF ResourceDictionary), reconfigurable hotkeys (swap Task 5's constants for settings-backed chords + a key-recorder control — Mac: `KeyRecorderView`), vocabulary UI + engine biasing (sherpa hotwords need `modified_beam_search` — Mac: `Vocabulary/VocabularyProcessing.swift` ports as pure C#, replacements + bounded-Levenshtein fuzzy correction, applied to partials AND finals in AppState), history (Microsoft.Data.Sqlite, **same schema as Mac `History/HistoryStore.swift`**, which is the Tauri schema → `LegacyHistoryImporter` reads the old Windows Tauri `history.db` from `%APPDATA%\com.omwhisper.app\`), settings JSON in `%APPDATA%\OmWhisper\settings.json`, sounds + volume, launch-at-login (`HKCU\...\Run` key), mic device picker (MMDeviceEnumerator, persist device ID), overlay styles Orb/Whisper-line port, real app icon, Velopack live (`dotnet vpk` pack + release feed on omwhisper.in; signing cert), onboarding window (port the Mac 4-step flow incl. the real try-it demo with paste/history suppressed — Mac: `UI/OnboardingView.swift` + `onboardingDemoActive` bracket pattern).

### W3 — AI polish
`IPolishBackend` interface (Mac: `Polish/PolishBackend.swift`). Port `PolishStyles` (7 built-ins, fixed GUIDs, canonical prompts — Mac: `Polish/PolishStyles.swift`), `stripLLMWrapper` post-processing, and the **unconditional fail-safe: any polish failure pastes raw text**. LocalLLM via LLamaSharp (+ `LLamaSharp.Backend.Cpu`): **model spike first** (candidates ~1–2B instruct Q4 GGUF, e.g. Qwen/Phi/Gemma tiers — verify current best small models at spike time), download-on-first-enable via `ModelDownloader`, hard timeout (Mac uses 5s). Ollama backend (HTTP port of `Polish/Ollama.swift` incl. `/api/tags` test-connection). CloudLLM + Redactor (port `Polish/Redactor.swift`'s 10-detector registry to .NET Regex + `Polish/CloudLLM.swift`'s redact→send→rehydrate; keys in Credential Manager via `CredentialManagement`-style P/Invoke or the `Meziantou.Framework.Win32.CredentialManager` package). Smart Dictation (second chord) + Polish Selected Text (SendInput Ctrl+C; clipboard **sequence number** `GetClipboardSequenceNumber` plays the Mac changeCount role — the "re-copying identical text" bug lesson). AI settings section.

### W4 — Engine flexibility
Whisper batch engine via sherpa-onnx offline mode (accumulate → single Final — Mac: `WhisperEngine.swift` behavior incl. "Ready = on disk" and downloads owned by AppState). Cloud engines: port the 5-provider dispatcher (Mac: `Transcription/CloudEngine.swift` + providers — AssemblyAI/Deepgram streaming WS, ElevenLabs/OpenAI/Groq batch WAV multipart; **all pure helpers have existing Mac tests to port as xUnit**; re-verify each provider's API against live docs — the M4.2 lesson: the never-live-verified auth path is where the bugs were). Screen-terms-never-egress rule ports with it (cloud engines get only explicit custom vocabulary). Engine selector UI with per-provider key fields + Test Connection.

### W5 — Beta → release
Parity audit vs. the Mac M1–M4 checklist, signed installer (Velopack + cert), omwhisper.in Windows download + release feed, beta soak, ship.

### Post-v1 (not gating)
S2 context dictation via UI Automation (`FlaUI` or raw UIA — the Mac `ScreenContextReader` 0.6s-budget pattern + exclusions), meetings (WASAPI **loopback** capture — dramatically simpler than the Mac's CoreAudio tap saga), reply assist, memory + MCP server, full hub window.

---

## Plan Self-Review Notes

- **Spec coverage:** W0–W1 tasks cover spec §1–§3 core loop + engine default path; §4 polish/cloud, §5 W2–W5, and post-v1 items are covered by the milestone briefs by design (spike-dependent details deferred to their own plans, per the spec's own two spike gates).
- **Known deliberate simplifications (ponytail-marked in code):** placeholder tray icon (W2), text-only clipboard restore (revisit on complaint), tray-balloon download progress (W2 onboarding replaces).
- **API-shape caveat repeated on purpose:** sherpa-onnx C# names in Task 6 and the model list URLs must be re-verified live at execution time (Step 1 of Task 6 is mandatory, not advisory).
