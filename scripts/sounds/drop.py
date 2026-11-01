# Generates Daisy's cues «Капля» (Daisy/Resources/Sounds/DaisyDropStart.wav, DaisyDropDone.wav).
# Run: python3 scripts/sounds/drop.py <scratch-dir>  (needs numpy; the shipped files are the approved drafts, see below)
# 01.11 (Egor: the bell H3 was «писклявый и системный», wanted softer and alive): K2, a water
# drop — a bubble's resonance, one sine whose pitch rises fast as the bubble closes
# (van den Doel 2005), ~620 Hz with a little body an octave below, a faint touch of the
# surface, a small warm room. «Готово» is two drops, the second lower. H3 is in git history.
# The shipped files are the drafts Egor listened to; a rerun draws other noise for the
# splash and the room (same sound, not the same bytes).
import importlib.util, sys, os, numpy as np
spec = importlib.util.spec_from_file_location("amb", os.path.join(os.path.dirname(__file__), "ambient_lib.py"))
amb = importlib.util.module_from_spec(spec); spec.loader.exec_module(amb)
OUT = sys.argv[1]; amb.OUT = OUT; SR = amb.SR

def lowpass(x, fc):
    a = 1 - np.exp(-2 * np.pi * fc / SR); y = np.empty_like(x); s = 0.0
    for i in range(len(x)): s += a * (x[i] - s); y[i] = s
    return y

def drop(f0, rise, tau, decay, d=0.25, body=0.0, splash=0.04, level=1.0):
    t = amb.t_of(d)
    f = f0 * (1 + rise * (1 - np.exp(-t / tau)))          # pitch glides up, then settles
    ph = 2 * np.pi * np.cumsum(f) / SR
    y = np.sin(ph) * np.exp(-decay * t) * np.clip(t / 0.003, 0, 1) ** 2
    if body: y += body * np.sin(ph * 0.5) * np.exp(-decay * 1.3 * t) * np.clip(t / 0.004, 0, 1)
    if splash:                                             # the touch of the surface, very faint
        n = int(0.012 * SR); k = np.arange(n)
        s = lowpass(amb.rng.standard_normal(n), 1800) * np.exp(-k / (0.003 * SR)) * np.clip(k / (0.001 * SR), 0, 1)
        y[:n] += splash * s / (np.max(np.abs(s)) + 1e-9)
    return level * y

def room(x): return amb.reverb(x, length=0.35, decay=11.0, mix=0.22, lp=2500)

def trim(y, keep):
    y = y[: int(keep * SR)]; f = int(0.05 * SR); y[-f:] *= np.linspace(1, 0, f) ** 2
    return y

first = lambda: drop(620, 0.4, 0.025, 30, body=0.25)
amb.save("DaisyDropStart.wav", trim(room(first()), 0.32), 0.14)
amb.save("DaisyDropDone.wav",  trim(room(amb.mix((first(), 0), (drop(500, 0.35, 0.028, 27, body=0.25, level=0.75), 0.12))), 0.46), 0.14)
print("ok")
