"""Full-screen recorder for the end-to-end test (Windows, ffmpeg gdigrab).

Usage:
    python recorder.py start <output.mp4> [--area WxH+X+Y] [--max-seconds N]
    python recorder.py stop <output.mp4>

start  launches a small detached supervisor process that runs ffmpeg (desktop capture, 15 fps, libx264 ultrafast,
       yuv420p) and keeps ffmpeg's stdin open. The PIDs are written to <output.mp4>.pid and the ffmpeg messages to
       <output.mp4>.ffmpeg.log. --area limits the capture to one rectangle (for example one monitor:
       1920x1080+0+0); without it the whole virtual desktop is recorded. --max-seconds (default 3600) is a safety
       limit passed to ffmpeg (-t) so a forgotten recording ends on its own.
stop   creates <output.mp4>.stop; the supervisor sends "q" to ffmpeg, which finalises the mp4 (moov atom) and exits.
       stop waits for that, removes the helper files and prints the file size and the duration (ffprobe, when found).

The file is never killed mid-write: if ffmpeg does not finish within the grace period, stop reports it and leaves the
process running so the owner can decide (closing it by force would corrupt the mp4).

Exit codes: 0 ok, 1 runtime problem, 2 usage error.
"""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

FRAMERATE = "15"
DEFAULT_MAX_SECONDS = 3600
START_CHECK_SECONDS = 2.0
STOP_GRACE_SECONDS = 60.0
POLL_SECONDS = 0.25
AREA_PATTERN = re.compile(r"^(\d+)x(\d+)\+(-?\d+)\+(-?\d+)$")


def helper_paths(output: Path) -> dict[str, Path]:
    """Paths of the helper files that live next to the recording."""
    return {
        "pid": output.with_name(output.name + ".pid"),
        "stop": output.with_name(output.name + ".stop"),
        "log": output.with_name(output.name + ".ffmpeg.log"),
    }


def find_ffmpeg() -> str:
    """Return the ffmpeg executable or exit with a clear message."""
    path = shutil.which("ffmpeg")
    if not path:
        sys.exit("ffmpeg not found on the PATH: install it (https://ffmpeg.org/download.html) and open a new terminal")
    return path


def ffmpeg_command(ffmpeg: str, output: Path, area: str | None, max_seconds: int) -> list[str]:
    """Build the ffmpeg command line for a gdigrab desktop capture."""
    capture = ["-f", "gdigrab", "-framerate", FRAMERATE, "-draw_mouse", "1"]
    if area:
        width, height, x, y = AREA_PATTERN.match(area).groups()  # type: ignore[union-attr]  # validated by the caller
        capture += ["-offset_x", x, "-offset_y", y, "-video_size", f"{width}x{height}"]
    return [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "warning",
        "-y",
        *capture,
        "-i",
        "desktop",
        "-t",
        str(max_seconds),
        # yuv420p needs even dimensions; pad by one pixel when the desktop size is odd.
        "-vf",
        "pad=ceil(iw/2)*2:ceil(ih/2)*2",
        "-c:v",
        "libx264",
        "-preset",
        "ultrafast",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(output),
    ]


def pid_alive(pid: int) -> bool:
    """True when a process with this PID exists (Windows and POSIX)."""
    if pid <= 0:
        return False
    if sys.platform == "win32":
        import ctypes  # Windows only

        synchronize = 0x00100000
        query_limited = 0x1000
        handle = ctypes.windll.kernel32.OpenProcess(synchronize | query_limited, False, pid)
        if not handle:
            return False
        try:
            exit_code = ctypes.c_ulong()
            ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
            return exit_code.value == 259  # STILL_ACTIVE
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def supervise(output: Path, area: str | None, max_seconds: int) -> int:
    """Run ffmpeg, keep its stdin open and send "q" when the stop file appears (internal command)."""
    paths = helper_paths(output)
    ffmpeg = find_ffmpeg()
    with paths["log"].open("ab") as log:
        # No console window: it would appear on the recorded monitor on top of the browser.
        no_window = 0
        if sys.platform == "win32":
            no_window = subprocess.CREATE_NO_WINDOW
        process = subprocess.Popen(  # fixed argument list, no shell
            ffmpeg_command(ffmpeg, output, area, max_seconds),
            stdin=subprocess.PIPE,
            stdout=log,
            stderr=log,
            creationflags=no_window,
        )
        paths["pid"].write_text(json.dumps({"supervisor": os.getpid(), "ffmpeg": process.pid}), encoding="utf-8")
        while process.poll() is None:
            if paths["stop"].exists():
                try:
                    process.stdin.write(b"q")  # type: ignore[union-attr]
                    process.stdin.flush()  # type: ignore[union-attr]
                    process.stdin.close()  # type: ignore[union-attr]
                except OSError:
                    pass
                break
            time.sleep(POLL_SECONDS)
        return process.wait()


def start(output: Path, area: str | None, max_seconds: int) -> int:
    """Launch the detached supervisor and confirm that ffmpeg is recording."""
    find_ffmpeg()
    paths = helper_paths(output)
    if paths["pid"].exists():
        print(f"a recording seems to be running already ({paths['pid']} exists); run stop first", file=sys.stderr)
        return 1
    output.parent.mkdir(parents=True, exist_ok=True)
    for name in ("stop", "log"):
        paths[name].unlink(missing_ok=True)
    args = [sys.executable, str(Path(__file__).resolve()), "_supervise", str(output), "--max-seconds", str(max_seconds)]
    if area:
        args += ["--area", area]
    flags = 0
    if sys.platform == "win32":
        flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW
    subprocess.Popen(  # fixed argument list, no shell
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=flags,
        close_fds=True,
        start_new_session=sys.platform != "win32",
    )
    deadline = time.monotonic() + START_CHECK_SECONDS + 5
    while time.monotonic() < deadline and not paths["pid"].exists():
        time.sleep(POLL_SECONDS)
    if not paths["pid"].exists():
        print("the recorder did not start (no PID file); see " + str(paths["log"]), file=sys.stderr)
        return 1
    time.sleep(START_CHECK_SECONDS)
    pids = json.loads(paths["pid"].read_text(encoding="utf-8"))
    if not pid_alive(int(pids["ffmpeg"])):
        log_tail = paths["log"].read_text(encoding="utf-8", errors="replace")[-800:] if paths["log"].exists() else ""
        paths["pid"].unlink(missing_ok=True)
        print(f"ffmpeg exited right after starting:\n{log_tail}", file=sys.stderr)
        return 1
    print(f"recording started: {output} (ffmpeg pid {pids['ffmpeg']}, {FRAMERATE} fps, max {max_seconds} s)")
    return 0


def describe(output: Path) -> str:
    """Size and duration of the recording (duration only when ffprobe is available)."""
    size = output.stat().st_size
    text = f"file: {output}\nsize: {size} bytes ({size / 1048576:.2f} MiB)"
    ffprobe = shutil.which("ffprobe")
    if not ffprobe:
        return text + "\nduration: unknown (ffprobe not found)"
    probe = subprocess.run(  # fixed argument list, no shell
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=codec_name,width,height",
            "-of",
            "json",
            str(output),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if probe.returncode != 0:
        return text + f"\nduration: unreadable (ffprobe: {probe.stderr.strip()[:300]})"
    info = json.loads(probe.stdout or "{}")
    duration = float(info.get("format", {}).get("duration", 0.0))
    stream = (info.get("streams") or [{}])[0]
    video = f"{stream.get('codec_name')} {stream.get('width')}x{stream.get('height')}"
    return text + f"\nduration: {duration:.2f} s\nvideo: {video}"


def stop(output: Path) -> int:
    """Ask the supervisor to stop ffmpeg gracefully and report the recording."""
    paths = helper_paths(output)
    if not paths["pid"].exists():
        print(f"no recording is running for {output} ({paths['pid']} not found)", file=sys.stderr)
        return 1
    pids = json.loads(paths["pid"].read_text(encoding="utf-8"))
    paths["stop"].write_text("stop\n", encoding="utf-8")
    deadline = time.monotonic() + STOP_GRACE_SECONDS
    while time.monotonic() < deadline and (pid_alive(int(pids["ffmpeg"])) or pid_alive(int(pids["supervisor"]))):
        time.sleep(POLL_SECONDS)
    if pid_alive(int(pids["ffmpeg"])):
        print(
            f"ffmpeg (pid {pids['ffmpeg']}) did not finish within {STOP_GRACE_SECONDS:.0f} s; it was left running so "
            "the file is not corrupted. Check it and stop it by hand if needed.",
            file=sys.stderr,
        )
        return 1
    paths["pid"].unlink(missing_ok=True)
    paths["stop"].unlink(missing_ok=True)
    if not output.exists():
        print(f"the recording {output} was not written; see {paths['log']}", file=sys.stderr)
        return 1
    if paths["log"].exists() and paths["log"].stat().st_size == 0:
        paths["log"].unlink()
    print("recording stopped\n" + describe(output))
    return 0


def primary_monitor_area() -> str:
    """Rectangle of the primary monitor in physical pixels (gdigrab offsets start at its top-left corner)."""
    if sys.platform != "win32":
        sys.exit("--area primary needs Windows; pass an explicit WxH+X+Y")
    import ctypes  # Windows only

    user32 = ctypes.windll.user32
    with contextlib.suppress(AttributeError, OSError):
        user32.SetProcessDPIAware()  # physical pixels instead of the scaled (125 %, 150 %) values
    width, height = user32.GetSystemMetrics(0), user32.GetSystemMetrics(1)  # SM_CXSCREEN, SM_CYSCREEN
    return f"{width - width % 2}x{height - height % 2}+0+0"  # even sizes for yuv420p


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse and validate the command line."""
    parser = argparse.ArgumentParser(description="Start or stop a full-screen ffmpeg recording (Windows gdigrab).")
    parser.add_argument("command", choices=["start", "stop", "_supervise"], help="start or stop the recording")
    parser.add_argument("output", help="output file, must end in .mp4")
    parser.add_argument(
        "--area",
        default="primary",
        help="what to capture: 'primary' (default: the main monitor, where the browser opens), 'all' (the whole "
        "virtual desktop) or a rectangle WxH+X+Y in physical pixels (for example 1920x1080+0+0)",
    )
    parser.add_argument("--max-seconds", type=int, default=DEFAULT_MAX_SECONDS, help="safety limit of the recording")
    args = parser.parse_args(argv)
    if not args.output.lower().endswith(".mp4"):
        parser.error("the output file must end in .mp4")
    if args.area == "primary":
        # Only start needs the rectangle (it passes it to the supervisor); stop ignores the area.
        args.area = primary_monitor_area() if args.command == "start" else None
    elif args.area == "all":
        args.area = None
    if args.area and not AREA_PATTERN.match(args.area):
        parser.error("--area must look like WxH+X+Y, for example 1920x1080+0+0")
    if not 1 <= args.max_seconds <= 4 * 3600:
        parser.error("--max-seconds must be between 1 and 14400")
    return args


def main(argv: list[str]) -> int:
    """Entry point."""
    args = parse_args(argv)
    output = Path(args.output).resolve()
    if args.command == "start":
        return start(output, args.area, args.max_seconds)
    if args.command == "stop":
        return stop(output)
    return supervise(output, args.area, args.max_seconds)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
