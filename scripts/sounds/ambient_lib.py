# Ambient cues: soft sine/triangle pads and bells with a synthetic reverb tail.
import numpy as np, wave, sys, os
SR = 48000
rng = np.random.default_rng(23)

def t_of(d): return np.arange(int(SR * d)) / SR

def voice(f, d, attack, release, detune=0.0, shape="sine", level=1.0):
    t = t_of(d); y = 0
    for cents in ([0] if detune == 0 else [-detune, detune]):
        ff = f * 2 ** (cents / 1200); ph = 2 * np.pi * ff * t
        y = y + (np.sin(ph) if shape == "sine" else (2 / np.pi) * np.arcsin(np.sin(ph)))
    n = len(t); env = np.ones(n)
    a = int(attack * SR); r = int(release * SR)
    env[:a] = 0.5 - 0.5 * np.cos(np.linspace(0, np.pi, a))
    env[n - r:] *= 0.5 + 0.5 * np.cos(np.linspace(0, np.pi, r))
    return level * y * env

def bell(f, d, decay, level=1.0):
    t = t_of(d)
    partials = [(1, 1.0), (2.0, 0.35), (3.01, 0.12), (4.2, 0.05)]
    y = sum(a * np.sin(2 * np.pi * f * m * t) * np.exp(-decay * m ** 0.7 * t) for m, a in partials)
    return level * y * np.clip(t / 0.006, 0, 1)

def reverb(x, length=1.8, decay=3.2, mix=0.35, lp=4000):
    n = int(length * SR); t = np.arange(n) / SR
    ir = rng.standard_normal(n) * np.exp(-decay * t)
    # darken the tail: one-pole low-pass on the IR
    a = 1 - np.exp(-2 * np.pi * lp / SR); s = 0.0
    for i in range(n): s += a * (ir[i] - s); ir[i] = s
    ir /= np.sqrt(np.sum(ir ** 2))
    m = len(x) + n - 1; N = 1 << (m - 1).bit_length()
    wet = np.fft.irfft(np.fft.rfft(x, N) * np.fft.rfft(ir, N), N)[:m]
    dry = np.concatenate([x, np.zeros(n - 1)])
    return (1 - mix) * dry + mix * wet / (np.max(np.abs(wet)) + 1e-9) * np.max(np.abs(x))

def mix(*parts):
    n = max(int(o * SR) + len(p) for p, o in parts); y = np.zeros(n)
    for p, o in parts: s = int(o * SR); y[s:s + len(p)] += p
    return y

def save(name, y, peak):
    y = y / (np.max(np.abs(y)) + 1e-9) * peak
    f = int(0.05 * SR); y[-f:] *= np.linspace(1, 0, f)
    with wave.open(os.path.join(OUT, name), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
        w.writeframes((y * 32767).astype(np.int16).tobytes())

A4 = 440.0
def note(semi): return A4 * 2 ** (semi / 12)
