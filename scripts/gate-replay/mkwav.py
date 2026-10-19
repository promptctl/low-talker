# The knock provocation as wavs: each fixture at -20 dB after 0.5 s of -51 dBFS room, alone and with a 0.2 s burst at 0.9 one second into the speech.
import os
import numpy as np, soundfile as sf
from scipy.signal import resample_poly
root = "/Users/bmf/code/low-talker/.claude/worktrees/low-dist-wgp/bench/librispeech/"
os.makedirs("/tmp/b4b/wav", exist_ok=True)
rng = np.random.default_rng(1)
for name in ["2277-149896-0000", "3536-8226-0018", "777-126732-0070"]:
    x, sr = sf.read(root + name + ".wav", dtype="float32", always_2d=True); x = x.mean(1)
    x = resample_poly(x, 16000, sr).astype(np.float32) if sr != 16000 else x
    y = np.concatenate([np.zeros(8000, np.float32), x * 0.1])
    y = y + (rng.uniform(-1, 1, len(y)) * 0.00282).astype(np.float32)
    sf.write(f"/tmp/b4b/wav/{name}-alone.wav", y, 16000, subtype="FLOAT")
    at = 8000 + 16000
    knock = np.where(rng.uniform(-1, 1, 3200) > 0, 0.9, -0.9).astype(np.float32)
    sf.write(f"/tmp/b4b/wav/{name}-knock.wav", np.concatenate([y[:at], knock, y[at:]]), 16000, subtype="FLOAT")
