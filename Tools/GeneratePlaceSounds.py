"""Rebuild Ledgerly's original, short PCM notification chimes."""
import math
from pathlib import Path
import struct
import wave

OUTPUT = Path(__file__).resolve().parents[1] / "Ledgerly IOS App/Ledgerly IOS App/Assets/NotificationSounds"
SAMPLE_RATE = 44_100


def write_chime(name, notes):
    duration = 1.35
    frames = []
    for index in range(round(duration * SAMPLE_RATE)):
        time = index / SAMPLE_RATE
        sample = 0.0
        for start, frequency in notes:
            elapsed = time - start
            if 0 <= elapsed < 0.85:
                attack = min(1, elapsed / 0.012)
                release = min(1, (0.85 - elapsed) / 0.12)
                envelope = attack * release * math.exp(-5.5 * elapsed)
                tone = math.sin(2 * math.pi * frequency * elapsed)
                tone += 0.18 * math.sin(2 * math.pi * frequency * 2 * elapsed)
                sample += 0.26 * envelope * tone
        frames.append(struct.pack("<h", round(max(-1, min(1, sample)) * 32767)))
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUTPUT / name), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(SAMPLE_RATE)
        output.writeframes(b"".join(frames))


if __name__ == "__main__":
    write_chime("ledgerly-arrival.wav", [(0, 659.255), (0.22, 830.609), (0.44, 987.767)])
    write_chime("ledgerly-departure.wav", [(0, 987.767), (0.22, 783.991), (0.44, 587.330)])
