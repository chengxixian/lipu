"""Generate reference fixtures for the Dart port of Basic Pitch.

Runs the *official* basic_pitch functions (windowing / unwrapping / peak
decoding) against the same ONNX model the app ships, and dumps:

  audio.f32    mono 22050Hz float32 PCM (the Dart test input)
  windows.f32  windowed model inputs, shape (n_windows, AUDIO_N_SAMPLES)
  note.f32     unwrapped note activations,  shape (n_frames, 88)
  onset.f32    unwrapped onset activations, shape (n_frames, 88)
  notes.json   decoded note events (start/end frame, midi, amplitude)
  meta.json    shapes and parameters used

Usage:
  python basicpitch_reference.py <wav> <outdir> <model.onnx> [seconds]
"""

import json
import os
import sys

import librosa
import numpy as np
import onnxruntime as ort

from basic_pitch.constants import AUDIO_N_SAMPLES, AUDIO_SAMPLE_RATE, FFT_HOP
from basic_pitch.inference import unwrap_output, window_audio_file
from basic_pitch.note_creation import model_frames_to_time, model_output_to_notes

INPUT_NAME = "serving_default_input_2:0"
NOTE_OUT = "StatefulPartitionedCall:1"
ONSET_OUT = "StatefulPartitionedCall:2"
CONTOUR_OUT = "StatefulPartitionedCall:0"
OVERLAP_FRAMES = 30


def _unwrap(output, audio_original_length, n_overlapping_frames, hop_size):
    """`unwrap_output` as implemented on basic-pitch main.

    The released 0.4.0 uses `floor(length * ANNOTATIONS_FPS / SR)` instead of
    `int(length / hop_size * frames_per_window)`; on a 3 minute file the two
    differ by ~1.2s at the tail, and main's value is the one consistent with
    `model_frames_to_time` (hop = 256), so the Dart port and this reference
    both follow main.
    """
    n_olap = int(0.5 * n_overlapping_frames)
    if n_olap > 0:
        output = output[:, n_olap:-n_olap, :]
    frames_per_window = output.shape[1]
    flat = output.reshape(output.shape[0] * output.shape[1], output.shape[2])
    expected = int(audio_original_length / hop_size * frames_per_window)
    return flat[:expected, :]


def main() -> int:
    wav = sys.argv[1]
    outdir = sys.argv[2]
    model = sys.argv[3]
    seconds = float(sys.argv[4]) if len(sys.argv) > 4 else 3.0

    os.makedirs(outdir, exist_ok=True)

    # Same front-end the Dart side uses: 22050 Hz mono float32.
    y, _ = librosa.load(wav, sr=AUDIO_SAMPLE_RATE, mono=True)
    y = np.ascontiguousarray(y[: int(seconds * AUDIO_SAMPLE_RATE)], dtype=np.float32)
    y.tofile(os.path.join(outdir, "audio.f32"))

    sess = ort.InferenceSession(model, providers=["CPUExecutionProvider"])

    overlap_len = OVERLAP_FRAMES * FFT_HOP
    hop_size = AUDIO_N_SAMPLES - overlap_len

    padded = np.concatenate([np.zeros(overlap_len // 2, dtype=np.float32), y])
    windows = []
    note_chunks = []
    onset_chunks = []
    for window, _ in window_audio_file(padded, hop_size):
        windows.append(window[:, 0].copy())
        batch = np.expand_dims(window, axis=0)  # (1, AUDIO_N_SAMPLES, 1)
        note, onset, _contour = sess.run(
            [NOTE_OUT, ONSET_OUT, CONTOUR_OUT], {INPUT_NAME: batch}
        )
        note_chunks.append(note)
        onset_chunks.append(onset)

    note = _unwrap(np.concatenate(note_chunks), y.shape[0], OVERLAP_FRAMES, hop_size)
    onset = _unwrap(np.concatenate(onset_chunks), y.shape[0], OVERLAP_FRAMES, hop_size)

    np.asarray(windows, dtype=np.float32).tofile(os.path.join(outdir, "windows.f32"))
    note.astype(np.float32).tofile(os.path.join(outdir, "note.f32"))
    onset.astype(np.float32).tofile(os.path.join(outdir, "onset.f32"))

    # Official peak decoding (melodia trick on, pitch bends off -> contour unused).
    dummy_contour = np.zeros((note.shape[0], 264), dtype=np.float32)
    _midi, note_events = model_output_to_notes(
        {"note": note, "onset": onset, "contour": dummy_contour},
        onset_thresh=0.5,
        frame_thresh=0.3,
        min_note_len=11,
        melodia_trick=True,
        include_pitch_bends=False,
    )

    # note_events are (start_sec, end_sec, pitch, amplitude, bends); recover the
    # frame indices through the same time mapping the model uses.
    times = model_frames_to_time(note.shape[0])
    events = []
    for start_sec, end_sec, pitch, amp, _bends in note_events:
        events.append(
            {
                "startFrame": int(np.argmin(np.abs(times - start_sec))),
                "endFrame": int(np.argmin(np.abs(times - end_sec))),
                "midi": int(pitch),
                "amplitude": float(amp),
                "startSec": float(start_sec),
                "endSec": float(end_sec),
            }
        )

    with open(os.path.join(outdir, "notes.json"), "w", encoding="utf-8") as fh:
        json.dump(events, fh, indent=1)

    meta = {
        "sampleRate": AUDIO_SAMPLE_RATE,
        "fftHop": FFT_HOP,
        "audioNSamples": AUDIO_N_SAMPLES,
        "hopSize": hop_size,
        "overlapFrames": OVERLAP_FRAMES,
        "samples": int(y.shape[0]),
        "nWindows": int(len(windows)),
        "nFrames": int(note.shape[0]),
        "nNoteBins": int(note.shape[1]),
        "onsetThreshold": 0.5,
        "frameThreshold": 0.3,
        "minNoteLen": 11,
        "melodiaTrick": True,
        "noteEvents": len(events),
    }
    with open(os.path.join(outdir, "meta.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=1)

    print(json.dumps(meta, indent=1))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
