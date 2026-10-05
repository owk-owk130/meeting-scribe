import argparse
import array
import json
import wave

import torch
from pyannote.audio import Pipeline


def load_waveform(path):
    with wave.open(path) as w:
        samples = array.array("h", w.readframes(w.getnframes()))
        rate = w.getframerate()
    return {"waveform": torch.tensor(samples, dtype=torch.float32).unsqueeze(0) / 32768, "sample_rate": rate}


def attendee_count(path):
    try:
        with open(path, encoding="utf-8") as f:
            return len(json.load(f)[0]["attendees"])
    except (OSError, ValueError, IndexError, KeyError, TypeError):
        return 0


parser = argparse.ArgumentParser()
parser.add_argument("wav")
parser.add_argument("out")
parser.add_argument("--event")
args = parser.parse_args()

pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-community-1")
pipeline.to(torch.device("mps" if torch.backends.mps.is_available() else "cpu"))

# 招待者は欠席者を含み、自分を含むかも一定しないので、人数は上限としてだけ使う
attendees = attendee_count(args.event) if args.event else 0
hints = {"max_speakers": attendees} if attendees >= 2 else {}

output = pipeline(load_waveform(args.wav), **hints)
turns = [
    [round(turn.start * 1000), round(turn.end * 1000), speaker]
    for turn, speaker in output.exclusive_speaker_diarization
]
with open(args.out, "w", encoding="utf-8") as f:
    json.dump(turns, f)
