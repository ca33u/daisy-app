#!/usr/bin/env python3
"""How far apart are a session's microphone and system-audio tracks?

Play the click track (Benchmarks/track_offset.py --make-fixture) through the
speakers during a recording, without headphones, then run this on the session
folder. It finds the clicks in each track and reports the offset between them:
the system track's first click minus the microphone's, in milliseconds. A
positive number means the system track starts later.

    python3 Benchmarks/track_offset.py --make-fixture click-track.wav
    python3 Benchmarks/track_offset.py "<session folder>"

Needs numpy and macOS's afconvert. It writes nothing into the session.
"""
import argparse
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

RATE = 16_000


def make_fixture(path, seconds=60, interval=1.0):
    """A click every `interval` seconds: a 10 ms 1 kHz tone, with silence between."""
    n = int(seconds * RATE)
    x = np.zeros(n, dtype=np.float32)
    burst = (np.sin(2 * np.pi * 1000 * np.arange(int(0.010 * RATE)) / RATE) * 0.8).astype(np.float32)
    for k in range(int(seconds / interval)):
        start = int((k * interval + 0.5) * RATE)
        x[start:start + len(burst)] = burst
    pcm = (np.clip(x, -1, 1) * 32767).astype(np.int16)
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(pcm.tobytes())
    print(f"wrote {path}: {seconds:.0f} s, a click every {interval:g} s")


def load_mono16k(caf):
    with tempfile.TemporaryDirectory() as tmp:
        wav = os.path.join(tmp, "t.wav")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", caf, wav],
                       check=True, capture_output=True)
        with wave.open(wav) as w:
            data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return data.astype(np.float32) / 32768.0


def click_times(x, min_gap=0.5):
    """Onsets of loud bursts, in seconds: 10 ms energy frames above 25% of the peak."""
    frame = RATE // 100
    n = len(x) // frame
    energy = np.sqrt((x[:n * frame].reshape(n, frame) ** 2).mean(axis=1))
    if energy.max() <= 0:
        return np.array([])
    above = energy > 0.25 * energy.max()
    onsets = np.flatnonzero(above & ~np.roll(above, 1))
    times = []
    for i in onsets:
        t = i / 100.0
        if not times or t - times[-1] >= min_gap:
            times.append(t)
    return np.array(times)


def offset_ms(session_dir):
    mic = os.path.join(session_dir, "microphone.caf")
    sys_ = os.path.join(session_dir, "system_audio.caf")
    for path in (mic, sys_):
        if not os.path.exists(path):
            sys.exit(f"missing {os.path.basename(path)} in {session_dir}")
    mic_clicks = click_times(load_mono16k(mic))
    sys_clicks = click_times(load_mono16k(sys_))
    print(f"microphone clicks: {len(mic_clicks)}, system clicks: {len(sys_clicks)}")
    if len(mic_clicks) < 3 or len(sys_clicks) < 3:
        sys.exit("too few clicks in one track: the system track did not hear the speakers")
    # Pair each system click with the nearest microphone click, then take the median.
    diffs = [s - mic_clicks[np.argmin(np.abs(mic_clicks - s))] for s in sys_clicks]
    diffs = [d for d in diffs if abs(d) < 0.5]
    med = float(np.median(diffs)) * 1000
    spread = float(np.std(diffs)) * 1000
    print(f"system minus microphone: {med:+.0f} ms (spread {spread:.0f} ms over {len(diffs)} clicks)")
    return med


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session", nargs="?", help="session folder")
    ap.add_argument("--make-fixture", metavar="WAV", help="write the click track and exit")
    args = ap.parse_args()
    if args.make_fixture:
        make_fixture(args.make_fixture)
        return
    if not args.session:
        ap.error("give a session folder, or --make-fixture")
    offset_ms(args.session)


if __name__ == "__main__":
    main()
