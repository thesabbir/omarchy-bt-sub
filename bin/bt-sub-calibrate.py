#!/usr/bin/env python3
"""Measure how much later the Bluetooth sub sounds than the main speakers.

Plays two independent, quiet noise probes at the same time — one on the main
speakers, one on the BT speaker — from a single 4ch stream linked straight to
both sinks (so no filter delay applies and their timing is sample-locked).
Records with a microphone and finds each probe's arrival by GCC-PHAT
correlation. Long probes give ~50 dB of processing gain, so they can sit well
under music. Starts very quiet and only gets louder if the mic can't find them.

Prints the BT-minus-main offset in seconds on stdout.

usage: bt-sub-calibrate.py MIC_SOURCE MAIN_SINK BT_SINK [LEVEL]
  LEVEL: linear master volume (0..1) the probe is scaled by; default 1.
"""
import subprocess
import sys
import threading
import time

import numpy as np

RATE = 48000
PROBE_S = 6.0
BAND = (400.0, 8000.0)  # probe and analysis band (Hz)
BASE_RMS = 0.02         # ~-34 dBFS before master volume: ~20 dB under typical music
STEPS = [1.0, 3.0, 8.0]  # escalate only if the mic can't find the probes
MIN_RMS, MAX_RMS = 0.0015, 0.05
TAIL_S = 1.0             # room for BT latency after the probe ends
RANGE = (-0.1, 0.8)      # plausible BT-minus-main offsets (s)
MIN_SNR = 10.0


def band_noise(rng, n, rms):
    spec = np.fft.rfft(rng.standard_normal(n))
    f = np.fft.rfftfreq(n, 1 / RATE)
    spec[(f < BAND[0]) | (f > BAND[1])] = 0
    x = np.fft.irfft(spec, n)
    x *= rms / np.sqrt(np.mean(x**2))
    fade = int(0.05 * RATE)
    x[:fade] *= np.linspace(0, 1, fade)
    x[-fade:] *= np.linspace(1, 0, fade)
    return x.astype(np.float32)


def gcc_phat(rec, ref):
    n = 1 << int(np.ceil(np.log2(len(rec) + len(ref))))
    g = np.fft.rfft(rec, n) * np.conj(np.fft.rfft(ref, n))
    g /= np.abs(g) + 1e-12
    f = np.fft.rfftfreq(n, 1 / RATE)
    g[(f < BAND[0]) | (f > BAND[1])] = 0
    return np.fft.irfft(g, n)[: len(rec)]


def peak(r, lo=0, hi=None):
    """Index of the strongest peak in r[lo:hi] and its SNR vs. the rest."""
    hi = len(r) if hi is None else hi
    seg = np.abs(r[lo:hi])
    i = int(np.argmax(seg))
    guard = int(0.02 * RATE)
    rest = np.concatenate([seg[: max(i - guard, 0)], seg[i + guard :]])
    noise = np.sqrt(np.mean(rest**2)) if len(rest) else 1e-12
    return lo + i, seg[i] / (noise + 1e-12)


def play_split(out, main_sink, bt_sink):
    """Play 4ch audio: FL/FR on main_sink, RL/RR on bt_sink, sample-locked."""
    name = "btsub_calibrate"
    player = subprocess.Popen(
        ["pw-cat", "-p", "--raw", "--format", "f32", f"--rate={RATE}", "--channels=4",
         "--channel-map", "FL,FR,RL,RR",
         "-P", f"{{ node.autoconnect = false node.name = {name} media.role = Test }}", "-"],
        stdin=subprocess.PIPE,
    )
    pairs = [("FL", main_sink, "FL"), ("FR", main_sink, "FR"), ("RL", bt_sink, "FL"), ("RR", bt_sink, "FR")]
    deadline = time.time() + 3
    pending = list(pairs)
    while pending and time.time() < deadline:
        pending = [
            (o, sink, i) for o, sink, i in pending
            if subprocess.run(["pw-link", f"{name}:output_{o}", f"{sink}:playback_{i}"],
                              capture_output=True).returncode != 0
        ]
        if pending:
            time.sleep(0.05)
    if pending:
        player.kill()
        sys.exit("could not link calibration stream to speakers")
    player.stdin.write(out.tobytes())
    player.stdin.close()
    player.wait()


def measure(mic, main_sink, bt_sink, rms, rng):
    n = int(PROBE_S * RATE)
    pm, pb = band_noise(rng, n, rms), band_noise(rng, n, rms)
    lead = int(0.1 * RATE)
    total = lead + n + int(TAIL_S * RATE)
    out = np.zeros((total, 4), np.float32)  # FL FR -> main, RL RR -> BT
    out[lead : lead + n, 0] = out[lead : lead + n, 1] = pm
    out[lead : lead + n, 2] = out[lead : lead + n, 3] = pb

    rec = subprocess.Popen(
        ["parec", "-d", mic, "--raw", "--format=s16le", f"--rate={RATE}", "--channels=1",
         "--latency-msec=20"],
        stdout=subprocess.PIPE,
    )
    chunks = []
    reader = threading.Thread(target=lambda: chunks.extend(iter(lambda: rec.stdout.read(4096), b"")))
    reader.start()
    time.sleep(0.3)
    play_split(out, main_sink, bt_sink)
    time.sleep(TAIL_S)
    rec.terminate()
    reader.join()

    x = np.frombuffer(b"".join(chunks), np.int16).astype(np.float32)
    if len(x) < n:
        sys.exit("recording too short")

    tm, snr_m = peak(gcc_phat(x, pm))
    rb = gcc_phat(x, pb)
    lo, hi = max(tm + int(RANGE[0] * RATE), 0), min(tm + int(RANGE[1] * RATE), len(rb))
    tb, snr_b = peak(rb, lo, hi)
    return (tb - tm) / RATE, snr_m, snr_b


def main():
    mic, main_sink, bt_sink = sys.argv[1:4]
    level = float(sys.argv[4]) if len(sys.argv) > 4 else 1.0
    rng = np.random.default_rng()
    for step in STEPS:
        rms = min(max(BASE_RMS * level * step, MIN_RMS), MAX_RMS)
        offset, snr_m, snr_b = measure(mic, main_sink, bt_sink, rms, rng)
        print(f"probe {20 * np.log10(rms):.0f} dBFS: main snr={snr_m:.1f} bt snr={snr_b:.1f} "
              f"offset={offset * 1000:.1f}ms", file=sys.stderr)
        if snr_m >= MIN_SNR and snr_b >= MIN_SNR:
            print(f"{offset:.3f}")
            return
    sys.exit("couldn't hear the speakers — check the mic, or raise the volume")


if __name__ == "__main__":
    main()
