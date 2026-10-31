# Generates Daisy's dictation cues (31.10, «Капля» H3 shipped as Daisy/Resources/Sounds/DaisyDrop*.wav).
# Run: python3 scripts/sounds/drop.py <out-dir>  (needs numpy)
# «Капля», shorter: same bell, faster decay, a short dark room; trimmed to the tail's end.
import importlib.util, sys, os, numpy as np
spec = importlib.util.spec_from_file_location("amb", os.path.join(os.path.dirname(__file__), "ambient_lib.py"))
amb = importlib.util.module_from_spec(spec); spec.loader.exec_module(amb)
OUT = sys.argv[1]; amb.OUT = OUT; SR = amb.SR; note = amb.note

def trim(y, keep):
    y = y[: int(keep * amb.SR)]; f = int(0.06 * amb.SR); y[-f:] *= np.linspace(1, 0, f) ** 2
    return y

# H2 — about half as long (≈0.6 s / 0.8 s).
amb.save("H2-start.wav", trim(amb.reverb(amb.bell(note(15), 0.35, 11.0), length=0.7, decay=6.5, mix=0.35), 0.6), 0.14)
amb.save("H2-done.wav",  trim(amb.reverb(amb.mix((amb.bell(note(10), 0.40, 9.0), 0), (amb.bell(note(3), 0.45, 8.0, level=0.7), 0.09)), length=0.8, decay=6.0, mix=0.35), 0.8), 0.14)
# H3 — barely more than the drop itself (≈0.35 s / 0.5 s).
amb.save("H3-start.wav", trim(amb.reverb(amb.bell(note(15), 0.25, 16.0), length=0.4, decay=10.0, mix=0.25), 0.35), 0.14)
amb.save("H3-done.wav",  trim(amb.reverb(amb.mix((amb.bell(note(10), 0.28, 14.0), 0), (amb.bell(note(3), 0.30, 12.0, level=0.7), 0.07)), length=0.45, decay=9.0, mix=0.25), 0.5), 0.14)
print("ok")
