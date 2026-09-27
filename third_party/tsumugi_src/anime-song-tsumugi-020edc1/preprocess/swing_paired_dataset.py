"""
音声とMIDIのペアデータから、拍内だけを swing 化した拡張データを生成する前処理。

このスクリプトはピッチ変更や全体速度変更を行わず、
各 beat の前半を少し長く、後半を少し短くすることで
中くらいの swing / shuffle 感を疑似生成する。
既定では `.wav/.flac` と `.mid/.midi` を扱い、
`_pitch_` / `_stretch_` / `_swing_` 付きファイルは再入力しない。
"""

from __future__ import annotations

import argparse
import logging
import os
from bisect import bisect_right
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
import shutil
import subprocess
import tempfile

import mido
import numpy as np
import pretty_midi
import soundfile as sf

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

DEFAULT_MAX_MIDI_TICK = 1_000_000
DEFAULT_TEMPO = 500_000
MAX_TEMPO_VALUE = 16_777_215
DEFAULT_AUDIO_EXTENSIONS = (".wav", ".flac")
DEFAULT_MIDI_EXTENSIONS = (".mid", ".midi")
DEFAULT_EXCLUDE_FILENAME_MARKERS = ("_pitch_", "_stretch_", "_swing_")
DEFAULT_SWING_RATIO = 0.625
DEFAULT_MIN_BEAT_DURATION_MS = 180.0
SCRIPT_PATH_EXAMPLE = "preprocess/swing_paired_dataset.py"
INPUT_AUDIO_EXAMPLE = "path/to/audio_dir/song__vocal.wav"
INPUT_MIDI_EXAMPLE = "path/to/midi_dir/song__vocal.mid"


@dataclass(frozen=True)
class RuntimeSwingConfig:
    """CLI解決後の実行設定を保持する。"""

    generate_audio: bool
    generate_midi: bool
    audio_dir: Path
    midi_dir: Path
    output_audio_dir: Path
    output_midi_dir: Path
    audio_extensions: tuple[str, ...]
    midi_extensions: tuple[str, ...]
    exclude_filename_markers: tuple[str, ...]
    swing_ratio: float
    min_beat_duration_seconds: float
    workers: int
    overwrite: bool
    max_midi_tick: int

    @classmethod
    def from_arguments(cls, arguments: argparse.Namespace) -> RuntimeSwingConfig:
        """引数を後段の処理が扱いやすい形へ正規化する。"""
        generate_audio = not arguments.midi_only
        generate_midi = not arguments.audio_only

        if generate_audio and arguments.audio_dir is None:
            raise ValueError("--audio_dir は音声処理時に必須です。")
        if arguments.midi_dir is None:
            raise ValueError(
                "--midi_dir は必須です。beat grid の取得と MIDI 生成に使います。"
            )

        audio_dir = (
            arguments.audio_dir.resolve()
            if arguments.audio_dir is not None
            else Path(".").resolve()
        )
        midi_dir = arguments.midi_dir.resolve()

        runtime_config = cls(
            generate_audio=generate_audio,
            generate_midi=generate_midi,
            audio_dir=audio_dir,
            midi_dir=midi_dir,
            output_audio_dir=(
                arguments.output_audio_dir.resolve()
                if arguments.output_audio_dir is not None
                else audio_dir
            ),
            output_midi_dir=(
                arguments.output_midi_dir.resolve()
                if arguments.output_midi_dir is not None
                else midi_dir
            ),
            audio_extensions=cls.normalize_extensions(
                arguments.audio_ext,
                option_name="--audio-ext",
            ),
            midi_extensions=cls.normalize_extensions(
                arguments.midi_ext,
                option_name="--midi-ext",
            ),
            exclude_filename_markers=DEFAULT_EXCLUDE_FILENAME_MARKERS,
            swing_ratio=float(arguments.swing_ratio),
            min_beat_duration_seconds=float(arguments.min_beat_duration_ms) / 1000.0,
            workers=arguments.workers,
            overwrite=arguments.overwrite,
            max_midi_tick=arguments.max_midi_tick,
        )
        runtime_config.validate()
        return runtime_config

    @staticmethod
    def normalize_extensions(
        extensions: list[str] | tuple[str, ...],
        *,
        option_name: str,
    ) -> tuple[str, ...]:
        """拡張子指定を `.wav` 形式へ正規化し、重複を除く。"""
        normalized_extensions: list[str] = []
        for extension in extensions:
            normalized = extension.strip().lower()
            if not normalized:
                continue
            if not normalized.startswith("."):
                normalized = f".{normalized}"
            if normalized not in normalized_extensions:
                normalized_extensions.append(normalized)

        if not normalized_extensions:
            raise ValueError(f"{option_name} には1つ以上の拡張子を指定してください。")
        return tuple(normalized_extensions)

    def validate(self) -> None:
        """実行前に最低限の前提を検証する。"""
        if self.workers < 1:
            raise ValueError("--workers は 1 以上にしてください。")
        if self.max_midi_tick < 1:
            raise ValueError("--max_midi_tick は 1 以上にしてください。")
        if not 0.5 < self.swing_ratio < 1.0:
            raise ValueError("--swing-ratio は 0.5 より大きく 1.0 未満にしてください。")
        if self.min_beat_duration_seconds <= 0.0:
            raise ValueError("--min-beat-duration-ms は 0 より大きくしてください。")
        if self.generate_audio and not self.audio_dir.exists():
            raise FileNotFoundError(
                f"入力音声ディレクトリが見つかりません: {self.audio_dir}"
            )
        if not self.midi_dir.exists():
            raise FileNotFoundError(
                f"入力MIDIディレクトリが見つかりません: {self.midi_dir}"
            )


@dataclass(frozen=True)
class AudioTask:
    """音声swing化用の1タスクを表す。"""

    input_path: Path
    beat_midi_path: Path
    output_dir: Path
    swing_ratio: float
    min_beat_duration_seconds: float


@dataclass(frozen=True)
class MidiTask:
    """MIDI swing化用の1タスクを表す。"""

    input_path: Path
    output_dir: Path
    swing_ratio: float
    min_beat_duration_seconds: float
    max_midi_tick: int


@dataclass
class TaskResult:
    """1ファイル分の処理結果を集約する。"""

    success_count: int = 0
    skipped_count: int = 0
    passthrough_count: int = 0
    error_messages: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class TempoSegments:
    """絶対tickから絶対秒へ変換するためのテンポ区間情報。"""

    start_ticks: tuple[int, ...]
    start_seconds: tuple[float, ...]
    tempos: tuple[int, ...]

    def seconds_at_tick(self, absolute_tick: int, *, ticks_per_beat: int) -> float:
        """指定した絶対tick位置の絶対秒を返す。"""
        segment_index = max(0, bisect_right(self.start_ticks, int(absolute_tick)) - 1)
        segment_start_tick = self.start_ticks[segment_index]
        segment_start_second = self.start_seconds[segment_index]
        segment_tempo = self.tempos[segment_index]
        delta_tick = int(absolute_tick) - segment_start_tick
        return float(segment_start_second) + mido.tick2second(
            delta_tick,
            ticks_per_beat,
            segment_tempo,
        )


@dataclass(frozen=True)
class SwingBeatSegment:
    """1拍の中だけを straight から swing へ写像する区間情報。"""

    start_second: float
    straight_mid_second: float
    swung_mid_second: float
    end_second: float


class SwingTimeMapper:
    """beat grid から局所的な swing 時間写像を構築する。"""

    def __init__(self, segments: tuple[SwingBeatSegment, ...]) -> None:
        self.segments = segments
        self.segment_starts = tuple(segment.start_second for segment in segments)

    @classmethod
    def from_beat_times(
        cls,
        beat_times: np.ndarray,
        *,
        swing_ratio: float,
        min_beat_duration_seconds: float,
    ) -> SwingTimeMapper:
        """beat 配列から有効な swing 区間だけを抽出する。"""
        if beat_times.size < 2:
            return cls(())

        cleaned_beat_times = np.asarray(beat_times, dtype=np.float64)
        cleaned_beat_times = cleaned_beat_times[np.isfinite(cleaned_beat_times)]
        if cleaned_beat_times.size < 2:
            return cls(())

        cleaned_beat_times = np.unique(np.maximum(cleaned_beat_times, 0.0))
        if cleaned_beat_times.size < 2:
            return cls(())

        segments: list[SwingBeatSegment] = []
        for start_second, end_second in zip(
            cleaned_beat_times[:-1].tolist(),
            cleaned_beat_times[1:].tolist(),
        ):
            beat_duration_seconds = float(end_second) - float(start_second)
            if beat_duration_seconds < min_beat_duration_seconds:
                continue

            straight_mid_second = float(start_second) + beat_duration_seconds * 0.5
            swung_mid_second = float(start_second) + beat_duration_seconds * swing_ratio
            if not float(start_second) < swung_mid_second < float(end_second):
                continue

            segments.append(
                SwingBeatSegment(
                    start_second=float(start_second),
                    straight_mid_second=float(straight_mid_second),
                    swung_mid_second=float(swung_mid_second),
                    end_second=float(end_second),
                )
            )

        return cls(tuple(segments))

    @property
    def has_active_segments(self) -> bool:
        """swing化できる拍区間が1つ以上あるかを返す。"""
        return bool(self.segments)

    def map_second(self, second: float) -> float:
        """ある絶対秒位置を swing 後の秒位置へ写像する。"""
        if not self.segments:
            return float(second)

        segment_index = bisect_right(self.segment_starts, float(second)) - 1
        if segment_index < 0:
            return float(second)

        segment = self.segments[segment_index]
        if not segment.start_second <= float(second) < segment.end_second:
            return float(second)

        if float(second) <= segment.straight_mid_second:
            source_length = segment.straight_mid_second - segment.start_second
            target_length = segment.swung_mid_second - segment.start_second
            if source_length <= 0.0:
                return float(second)
            return segment.start_second + (
                (float(second) - segment.start_second) * target_length / source_length
            )

        source_length = segment.end_second - segment.straight_mid_second
        target_length = segment.end_second - segment.swung_mid_second
        if source_length <= 0.0:
            return float(second)
        return segment.swung_mid_second + (
            (float(second) - segment.straight_mid_second)
            * target_length
            / source_length
        )


def format_ratio_tag(ratio: float) -> str:
    """ファイル名に埋め込む swing 比率タグを返す。"""
    return f"{ratio:.3f}".rstrip("0").rstrip(".").replace(".", "p")


def build_example_output_path(example_path: str, swing_ratio: float) -> str:
    """ヘルプ表示用の出力パス例を組み立てる。"""
    path = Path(example_path)
    output_path = path.with_name(
        f"{path.stem}_swing_{format_ratio_tag(swing_ratio)}{path.suffix}"
    )
    return output_path.as_posix()


def parse_arguments() -> argparse.Namespace:
    """コマンドライン引数を読み取る。"""
    parser = argparse.ArgumentParser(
        description="音声とMIDIを拍内だけ swing 化する",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "入力例:\n"
            f"  {INPUT_AUDIO_EXAMPLE}\n"
            f"  {INPUT_MIDI_EXAMPLE}\n\n"
            "出力例:\n"
            f"  {build_example_output_path(INPUT_AUDIO_EXAMPLE, DEFAULT_SWING_RATIO)}\n"
            f"  {build_example_output_path(INPUT_MIDI_EXAMPLE, DEFAULT_SWING_RATIO)}\n\n"
            "使い方:\n"
            f"  python {SCRIPT_PATH_EXAMPLE} --audio_dir ./audio --midi_dir ./midi\n"
            f"  python {SCRIPT_PATH_EXAMPLE} --midi_dir ./midi --midi-only\n"
            f"  python {SCRIPT_PATH_EXAMPLE} --audio_dir ./audio --midi_dir ./midi --audio-only --workers 4\n\n"
            "swing-ratio の目安:\n"
            "  0.50 = ストレート\n"
            "  0.625 = 中くらいの swing\n"
            "  0.6667 = 強めの shuffle"
        ),
    )
    parser.add_argument(
        "--audio_dir", type=Path, default=None, help="入力音声ディレクトリ"
    )
    parser.add_argument(
        "--midi_dir", type=Path, default=None, help="入力MIDIディレクトリ"
    )
    parser.add_argument(
        "--audio-ext",
        nargs="+",
        default=list(DEFAULT_AUDIO_EXTENSIONS),
        metavar="EXTENSIONS",
        help="処理対象に含める音声拡張子。例: .wav .flac",
    )
    parser.add_argument(
        "--midi-ext",
        nargs="+",
        default=list(DEFAULT_MIDI_EXTENSIONS),
        metavar="EXTENSIONS",
        help="処理対象に含めるMIDI拡張子。例: .mid .midi",
    )
    parser.add_argument(
        "--output_audio_dir",
        type=Path,
        default=None,
        help="出力音声ディレクトリ。未指定なら audio_dir に保存",
    )
    parser.add_argument(
        "--output_midi_dir",
        type=Path,
        default=None,
        help="出力MIDIディレクトリ。未指定なら midi_dir に保存",
    )
    parser.add_argument(
        "--swing-ratio",
        type=float,
        default=DEFAULT_SWING_RATIO,
        help="裏拍位置の比率。0.50=ストレート, 0.625=中くらい, 0.6667=強め",
    )
    parser.add_argument(
        "--min-beat-duration-ms",
        type=float,
        default=DEFAULT_MIN_BEAT_DURATION_MS,
        help="この長さ未満の beat は swing 化しない",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=max(1, os.cpu_count() or 1),
        help="並列処理のワーカー数",
    )
    parser.add_argument(
        "--overwrite", action="store_true", help="既存の生成ファイルを上書きする"
    )
    parser.add_argument(
        "--max_midi_tick",
        type=int,
        default=DEFAULT_MAX_MIDI_TICK,
        help="生成するMIDIの最大tick目安。大きすぎるMIDIはこの値以下になるよう解像度を下げる",
    )
    parser.add_argument("--audio-only", action="store_true", help="音声だけを生成する")
    parser.add_argument("--midi-only", action="store_true", help="MIDIだけを生成する")
    arguments = parser.parse_args()

    if arguments.audio_only and arguments.midi_only:
        raise ValueError("--audio-only と --midi-only は同時に指定できません。")
    return arguments


@lru_cache(maxsize=1)
def get_rubberband_binary() -> str:
    """利用可能な Rubber Band CLI の実行ファイル名を返す。"""
    for candidate in ("rubberband-r3", "rubberband"):
        resolved = shutil.which(candidate)
        if resolved:
            return resolved

    raise RuntimeError(
        "Rubber Band CLI が見つかりませんでした。"
        " `rubberband` または `rubberband-r3` をインストールしてください。"
    )


def initialize_audio_worker() -> None:
    """各音声ワーカープロセスで Rubber Band CLI の存在確認を行う。"""
    get_rubberband_binary()


def build_output_path(output_dir: Path, input_path: Path, swing_ratio: float) -> Path:
    """出力ファイルパスを命名規則どおりに組み立てる。"""
    return (
        output_dir
        / f"{input_path.stem}_swing_{format_ratio_tag(swing_ratio)}{input_path.suffix}"
    )


def get_temporary_output_path(output_path: Path) -> Path:
    """拡張子を保った一時ファイルパスを返す。"""
    return output_path.with_name(f"{output_path.stem}.tmp{output_path.suffix}")


def write_output_midi(output_path: Path, midi_data: mido.MidiFile) -> None:
    """一時ファイル経由でMIDIを書き込む。"""
    temp_output_path = get_temporary_output_path(output_path)
    try:
        midi_data.save(str(temp_output_path))
        temp_output_path.replace(output_path)
    except Exception:
        if temp_output_path.exists():
            temp_output_path.unlink()
        raise


def compute_largest_tick(midi_file: mido.MidiFile) -> int:
    """MIDI全体で最も大きい絶対tick位置を返す。"""
    largest_tick = 0
    for track in midi_file.tracks:
        absolute_tick = 0
        for message in track:
            absolute_tick += int(message.time)
        largest_tick = max(largest_tick, absolute_tick)
    return largest_tick


def choose_output_ticks_per_beat(
    original_ticks_per_beat: int,
    duration_seconds: float,
    max_midi_tick: int,
) -> int:
    """固定テンポで再配置したときに最大tickを超えない解像度を選ぶ。"""
    if duration_seconds <= 0.0:
        return max(1, int(original_ticks_per_beat))

    max_allowed_ticks_per_beat = int(
        max_midi_tick * DEFAULT_TEMPO / (duration_seconds * 1_000_000.0)
    )
    if max_allowed_ticks_per_beat < 1:
        max_allowed_ticks_per_beat = 1
    return max(1, min(int(original_ticks_per_beat), max_allowed_ticks_per_beat))


def seconds_to_output_tick(
    absolute_second: float,
    *,
    ticks_per_beat: int,
) -> int:
    """固定テンポの出力MIDI上で絶対秒を絶対tickへ変換する。"""
    if absolute_second <= 0.0:
        return 0
    return max(
        0,
        int(round(mido.second2tick(absolute_second, ticks_per_beat, DEFAULT_TEMPO))),
    )


def build_tempo_segments(midi_file: mido.MidiFile) -> TempoSegments:
    """MIDI全体のテンポイベントから絶対秒変換用の区間情報を構築する。"""
    raw_tempo_changes: list[tuple[int, int, int, int]] = []
    for track_index, track in enumerate(midi_file.tracks):
        absolute_tick = 0
        for message_index, message in enumerate(track):
            absolute_tick += int(message.time)
            if message.type == "set_tempo":
                raw_tempo_changes.append(
                    (
                        absolute_tick,
                        track_index,
                        message_index,
                        int(message.tempo),
                    )
                )

    if not raw_tempo_changes:
        raw_tempo_changes.append((0, 0, 0, DEFAULT_TEMPO))

    raw_tempo_changes.sort(key=lambda item: (item[0], item[1], item[2]))

    collapsed_tempo_changes: list[tuple[int, int]] = []
    for absolute_tick, _, _, tempo in raw_tempo_changes:
        if collapsed_tempo_changes and collapsed_tempo_changes[-1][0] == absolute_tick:
            collapsed_tempo_changes[-1] = (absolute_tick, tempo)
        else:
            collapsed_tempo_changes.append((absolute_tick, tempo))

    if collapsed_tempo_changes[0][0] != 0:
        collapsed_tempo_changes.insert(0, (0, DEFAULT_TEMPO))

    start_ticks: list[int] = []
    start_seconds: list[float] = []
    tempos: list[int] = []

    elapsed_seconds = 0.0
    previous_tick = int(collapsed_tempo_changes[0][0])
    previous_tempo = int(collapsed_tempo_changes[0][1])
    start_ticks.append(previous_tick)
    start_seconds.append(0.0)
    tempos.append(previous_tempo)

    for absolute_tick, tempo in collapsed_tempo_changes[1:]:
        elapsed_seconds += mido.tick2second(
            int(absolute_tick) - previous_tick,
            midi_file.ticks_per_beat,
            previous_tempo,
        )
        start_ticks.append(int(absolute_tick))
        start_seconds.append(float(elapsed_seconds))
        tempos.append(int(tempo))
        previous_tick = int(absolute_tick)
        previous_tempo = int(tempo)

    return TempoSegments(
        start_ticks=tuple(start_ticks),
        start_seconds=tuple(start_seconds),
        tempos=tuple(tempos),
    )


def load_swing_time_mapper(
    midi_path: Path,
    *,
    swing_ratio: float,
    min_beat_duration_seconds: float,
) -> SwingTimeMapper:
    """MIDIの beat grid から swing 用の時間写像を構築する。"""
    try:
        midi_for_beats = pretty_midi.PrettyMIDI(str(midi_path))
    except Exception as exception:
        raise ValueError(
            f"beat grid を取得できませんでした: {midi_path} ({exception})"
        ) from exception

    beat_times = np.asarray(midi_for_beats.get_beats(start_time=0.0), dtype=np.float64)
    return SwingTimeMapper.from_beat_times(
        beat_times,
        swing_ratio=swing_ratio,
        min_beat_duration_seconds=min_beat_duration_seconds,
    )


def clamp_frame_index(frame_index: int, total_frames: int) -> int:
    """フレーム位置を有効範囲へ丸める。"""
    return max(0, min(int(frame_index), int(total_frames)))


def seconds_to_frame(
    second: float,
    *,
    sample_rate: int,
    total_frames: int,
) -> int:
    """秒位置をフレーム位置へ変換して有効範囲へ収める。"""
    return clamp_frame_index(
        int(round(float(second) * float(sample_rate))), total_frames
    )


def normalize_timemap_entries(
    entries: list[tuple[int, int]],
    *,
    total_frames: int,
) -> list[tuple[int, int]]:
    """Rubber Band に渡しやすい単調増加の key-frame map へ整える。"""
    if total_frames <= 0:
        return [(0, 0)]

    normalized_pairs: dict[int, int] = {}
    for source_frame, target_frame in entries:
        clamped_source = clamp_frame_index(source_frame, total_frames)
        clamped_target = clamp_frame_index(target_frame, total_frames)
        normalized_pairs[clamped_source] = clamped_target

    normalized_pairs[0] = 0
    normalized_pairs[total_frames] = total_frames

    previous_target = 0
    normalized_entries: list[tuple[int, int]] = []
    for source_frame in sorted(normalized_pairs):
        target_frame = max(previous_target, normalized_pairs[source_frame])
        normalized_entries.append((source_frame, target_frame))
        previous_target = target_frame

    return normalized_entries


def build_rubberband_timemap_entries(
    *,
    sample_rate: int,
    total_frames: int,
    time_mapper: SwingTimeMapper,
) -> tuple[list[tuple[int, int]], bool]:
    """beat 写像から Rubber Band 用の key-frame map を作る。"""
    if total_frames <= 0 or not time_mapper.has_active_segments:
        return [(0, 0), (max(total_frames, 0), max(total_frames, 0))], True

    raw_entries: list[tuple[int, int]] = [(0, 0), (total_frames, total_frames)]

    # 1. beat の頭は固定する。
    # 2. beat 中央だけ straight -> swing へ移す。
    # 3. beat の終点も固定し、Rubber Band に連続変形させる。
    for segment in time_mapper.segments:
        start_frame = seconds_to_frame(
            segment.start_second,
            sample_rate=sample_rate,
            total_frames=total_frames,
        )
        end_frame = seconds_to_frame(
            segment.end_second,
            sample_rate=sample_rate,
            total_frames=total_frames,
        )
        if end_frame <= start_frame:
            continue
        straight_mid_frame = seconds_to_frame(
            segment.straight_mid_second,
            sample_rate=sample_rate,
            total_frames=total_frames,
        )
        swung_mid_frame = seconds_to_frame(
            segment.swung_mid_second,
            sample_rate=sample_rate,
            total_frames=total_frames,
        )
        raw_entries.extend(
            [
                (start_frame, start_frame),
                (straight_mid_frame, swung_mid_frame),
                (end_frame, end_frame),
            ]
        )

    normalized_entries = normalize_timemap_entries(
        raw_entries,
        total_frames=total_frames,
    )
    is_passthrough = all(
        source_frame == target_frame
        for source_frame, target_frame in normalized_entries
    )
    return normalized_entries, is_passthrough


def write_rubberband_timemap_file(
    timemap_path: Path,
    timemap_entries: list[tuple[int, int]],
) -> None:
    """Rubber Band CLI 用の key-frame map ファイルを書き出す。"""
    with open(timemap_path, "w", encoding="utf-8") as file:
        for source_frame, target_frame in timemap_entries:
            file.write(f"{source_frame} {target_frame}\n")


def build_rubberband_command(
    *,
    rubberband_binary: str,
    timemap_path: Path,
    input_path: Path,
    output_path: Path,
) -> list[str]:
    """連続 time map 付きの Rubber Band CLI コマンドを組み立てる。"""
    command = [
        rubberband_binary,
        "-q",
        "-t",
        "1.0",
        "-M",
        str(timemap_path),
    ]
    if Path(rubberband_binary).name == "rubberband":
        command.append("-3")

    command.extend([str(input_path), str(output_path)])
    return command


def copy_audio_file(input_path: Path, output_path: Path) -> None:
    """no-op の場合は音声ファイルをそのまま複製する。"""
    temp_output_path = get_temporary_output_path(output_path)
    try:
        shutil.copy2(input_path, temp_output_path)
        temp_output_path.replace(output_path)
    except Exception:
        if temp_output_path.exists():
            temp_output_path.unlink()
        raise


def run_rubberband_timemap(
    *,
    input_path: Path,
    output_path: Path,
    timemap_entries: list[tuple[int, int]],
) -> None:
    """Rubber Band CLI に連続 key-frame map を渡して音声を変形する。"""
    rubberband_binary = get_rubberband_binary()
    temp_output_path = get_temporary_output_path(output_path)

    with tempfile.TemporaryDirectory(prefix="swing_timemap_", dir="/tmp") as temp_dir:
        timemap_path = Path(temp_dir) / "timemap.txt"
        write_rubberband_timemap_file(timemap_path, timemap_entries)
        command = build_rubberband_command(
            rubberband_binary=rubberband_binary,
            timemap_path=timemap_path,
            input_path=input_path,
            output_path=temp_output_path,
        )
        completed = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=False,
        )

    if completed.returncode != 0:
        if temp_output_path.exists():
            temp_output_path.unlink()
        error_text = (completed.stderr or completed.stdout or "").strip()
        if not error_text:
            error_text = "Rubber Band CLI がエラーを返しました。"
        raise RuntimeError(error_text)

    temp_output_path.replace(output_path)


def build_swung_midi(
    midi_file: mido.MidiFile,
    time_mapper: SwingTimeMapper,
    *,
    max_midi_tick: int,
) -> tuple[mido.MidiFile, bool]:
    """beat 内のイベント時刻だけを swing 化した新しいMIDIを返す。"""
    if not time_mapper.has_active_segments:
        return midi_file, True

    largest_tick = compute_largest_tick(midi_file)
    tempo_segments = build_tempo_segments(midi_file)
    duration_seconds = tempo_segments.seconds_at_tick(
        largest_tick,
        ticks_per_beat=midi_file.ticks_per_beat,
    )
    new_ticks_per_beat = choose_output_ticks_per_beat(
        midi_file.ticks_per_beat,
        duration_seconds,
        max_midi_tick,
    )

    swung_midi = mido.MidiFile(
        type=midi_file.type,
        ticks_per_beat=new_ticks_per_beat,
    )

    # 1. 元MIDIの各イベントを絶対秒へ直す。
    # 2. beat 内だけ swing 写像で変形する。
    # 3. 出力側は固定テンポMIDIへ再配置する。
    for track in midi_file.tracks:
        new_track = mido.MidiTrack()
        absolute_tick = 0
        previous_output_tick = 0
        for message in track:
            absolute_tick += int(message.time)
            if message.type == "set_tempo":
                continue

            absolute_second = tempo_segments.seconds_at_tick(
                absolute_tick,
                ticks_per_beat=midi_file.ticks_per_beat,
            )
            swung_second = time_mapper.map_second(absolute_second)
            output_tick = seconds_to_output_tick(
                swung_second,
                ticks_per_beat=new_ticks_per_beat,
            )
            output_tick = max(previous_output_tick, output_tick)
            delta_tick = output_tick - previous_output_tick
            previous_output_tick = output_tick
            new_track.append(message.copy(time=delta_tick))

        swung_midi.tracks.append(new_track)

    if not swung_midi.tracks:
        swung_midi.tracks.append(mido.MidiTrack())

    swung_midi.tracks[0].insert(
        0,
        mido.MetaMessage(
            "set_tempo",
            tempo=min(MAX_TEMPO_VALUE, max(1, DEFAULT_TEMPO)),
            time=0,
        ),
    )
    return swung_midi, False


def process_audio_task(task: AudioTask, overwrite: bool) -> TaskResult:
    """1つの音声ファイルから swing 化した音声を作る。"""
    result = TaskResult()
    output_path = build_output_path(task.output_dir, task.input_path, task.swing_ratio)
    if not overwrite and output_path.exists():
        result.skipped_count = 1
        return result

    try:
        audio_info = sf.info(str(task.input_path))
        time_mapper = load_swing_time_mapper(
            task.beat_midi_path,
            swing_ratio=task.swing_ratio,
            min_beat_duration_seconds=task.min_beat_duration_seconds,
        )
        timemap_entries, is_passthrough = build_rubberband_timemap_entries(
            sample_rate=int(audio_info.samplerate),
            total_frames=int(audio_info.frames),
            time_mapper=time_mapper,
        )

        task.output_dir.mkdir(parents=True, exist_ok=True)
        if is_passthrough:
            copy_audio_file(task.input_path, output_path)
        else:
            run_rubberband_timemap(
                input_path=task.input_path,
                output_path=output_path,
                timemap_entries=timemap_entries,
            )
        result.success_count = 1
        result.passthrough_count = int(is_passthrough)
    except (OSError, RuntimeError, ValueError, sf.LibsndfileError) as exception:
        result.error_messages.append(f"{task.input_path.name}: {exception}")

    return result


def process_midi_task(task: MidiTask, overwrite: bool) -> TaskResult:
    """1つのMIDIファイルから swing 化したMIDIを作る。"""
    result = TaskResult()
    output_path = build_output_path(task.output_dir, task.input_path, task.swing_ratio)
    if not overwrite and output_path.exists():
        result.skipped_count = 1
        return result

    try:
        midi_data = mido.MidiFile(str(task.input_path))
        time_mapper = load_swing_time_mapper(
            task.input_path,
            swing_ratio=task.swing_ratio,
            min_beat_duration_seconds=task.min_beat_duration_seconds,
        )
        swung_midi, is_passthrough = build_swung_midi(
            midi_data,
            time_mapper,
            max_midi_tick=task.max_midi_tick,
        )

        task.output_dir.mkdir(parents=True, exist_ok=True)
        write_output_midi(output_path, swung_midi)
        result.success_count = 1
        result.passthrough_count = int(is_passthrough)
    except (OSError, RuntimeError, ValueError) as exception:
        result.error_messages.append(f"{task.input_path.name}: {exception}")

    return result


class SwingDatasetRunner:
    """入出力収集と並列実行をまとめて担当する。"""

    def __init__(self, runtime_config: RuntimeSwingConfig) -> None:
        self.runtime_config = runtime_config

    def run(self) -> None:
        """CLIの本体処理を順番に実行する。"""
        self.log_runtime_summary()

        audio_files, midi_files = self.collect_input_files()
        paired_audio_files, paired_midis = self.build_audio_pairs(
            audio_files, midi_files
        )

        if self.runtime_config.generate_audio:
            self.run_audio(paired_audio_files)
        if self.runtime_config.generate_midi:
            midi_inputs = (
                paired_midis if self.runtime_config.generate_audio else midi_files
            )
            self.run_midi(midi_inputs)

    def log_runtime_summary(self) -> None:
        """実行範囲と対象拡張子をログに出す。"""
        logger.info("swing_ratio: %.4f", self.runtime_config.swing_ratio)
        logger.info(
            "最小beat長: %.1f ms",
            self.runtime_config.min_beat_duration_seconds * 1000.0,
        )
        logger.info(
            "対象拡張子: audio=%s / midi=%s",
            ", ".join(self.runtime_config.audio_extensions),
            ", ".join(self.runtime_config.midi_extensions),
        )

    def collect_input_files(self) -> tuple[list[Path], list[Path]]:
        """音声とMIDIの入力ファイル一覧をまとめて返す。"""
        audio_files: list[Path] = []
        midi_files = self.collect_source_files(
            self.runtime_config.midi_dir,
            extensions=self.runtime_config.midi_extensions,
            source_label="MIDI",
        )

        if self.runtime_config.generate_audio:
            audio_files = self.collect_source_files(
                self.runtime_config.audio_dir,
                extensions=self.runtime_config.audio_extensions,
                source_label="音声",
            )

        return audio_files, midi_files

    def collect_source_files(
        self,
        root_dir: Path,
        *,
        extensions: tuple[str, ...],
        source_label: str,
    ) -> list[Path]:
        """
        入力ディレクトリから元データだけを再帰収集する。
        生成済みファイルを除外することで、既存拡張データの再入力を防ぐ。
        """
        source_files = sorted(
            path
            for path in root_dir.rglob("*")
            if path.is_file()
            and path.suffix.lower() in extensions
            and not self.is_derived_file(path)
        )
        if source_files:
            return source_files

        extension_text = ", ".join(extensions)
        raise FileNotFoundError(
            f"入力{source_label}が見つかりません: {root_dir} (extensions: {extension_text})"
        )

    def is_derived_file(self, path: Path) -> bool:
        """生成済み派生ファイルかどうかをファイル名から判定する。"""
        return any(
            marker in path.stem
            for marker in self.runtime_config.exclude_filename_markers
        )

    def build_audio_pairs(
        self,
        audio_files: list[Path],
        midi_files: list[Path],
    ) -> tuple[list[AudioTask], list[Path]]:
        """音声処理用のペア対応を作り、同時にMIDI側の対象も揃える。"""
        if not self.runtime_config.generate_audio:
            return [], []

        audio_map = {
            path.relative_to(self.runtime_config.audio_dir).with_suffix(""): path
            for path in audio_files
        }
        midi_map = {
            path.relative_to(self.runtime_config.midi_dir).with_suffix(""): path
            for path in midi_files
        }

        paired_keys = sorted(audio_map.keys() & midi_map.keys())
        missing_midis = sorted(audio_map.keys() - midi_map.keys())
        missing_audios = sorted(midi_map.keys() - audio_map.keys())
        self.log_pairing_summary(
            paired_count=len(paired_keys),
            missing_midis=missing_midis,
            missing_audios=missing_audios,
        )

        if not paired_keys:
            raise ValueError("一致する audio/MIDI ペアが見つかりませんでした。")

        audio_tasks = [
            AudioTask(
                input_path=audio_map[key],
                beat_midi_path=midi_map[key],
                output_dir=self.build_task_output_dir(
                    self.runtime_config.audio_dir,
                    self.runtime_config.output_audio_dir,
                    audio_map[key],
                ),
                swing_ratio=self.runtime_config.swing_ratio,
                min_beat_duration_seconds=self.runtime_config.min_beat_duration_seconds,
            )
            for key in paired_keys
        ]
        paired_midis = [midi_map[key] for key in paired_keys]
        return audio_tasks, paired_midis

    def run_audio(self, audio_tasks: list[AudioTask]) -> None:
        """音声タスク群を構築して並列実行する。"""
        get_rubberband_binary()
        logger.info("音声処理対象: %d ファイル", len(audio_tasks))
        (
            audio_success,
            audio_skipped,
            audio_passthrough,
            audio_errors,
        ) = self.execute_audio_tasks(audio_tasks)
        logger.info(
            "音声処理完了: success=%d, skipped=%d, passthrough=%d, errors=%d",
            audio_success,
            audio_skipped,
            audio_passthrough,
            len(audio_errors),
        )
        self.log_error_messages(audio_errors)

    def run_midi(self, midi_files: list[Path]) -> None:
        """MIDIタスク群を構築して並列実行する。"""
        midi_tasks = [
            MidiTask(
                input_path=path,
                output_dir=self.build_task_output_dir(
                    self.runtime_config.midi_dir,
                    self.runtime_config.output_midi_dir,
                    path,
                ),
                swing_ratio=self.runtime_config.swing_ratio,
                min_beat_duration_seconds=self.runtime_config.min_beat_duration_seconds,
                max_midi_tick=self.runtime_config.max_midi_tick,
            )
            for path in midi_files
        ]
        logger.info("MIDI処理対象: %d ファイル", len(midi_tasks))
        (
            midi_success,
            midi_skipped,
            midi_passthrough,
            midi_errors,
        ) = self.execute_midi_tasks(midi_tasks)
        logger.info(
            "MIDI処理完了: success=%d, skipped=%d, passthrough=%d, errors=%d",
            midi_success,
            midi_skipped,
            midi_passthrough,
            len(midi_errors),
        )
        self.log_error_messages(midi_errors)

    def build_task_output_dir(
        self,
        input_root_dir: Path,
        output_root_dir: Path,
        input_path: Path,
    ) -> Path:
        """入力の相対ディレクトリ構造を保ったまま出力先を決める。"""
        return output_root_dir / input_path.relative_to(input_root_dir).parent

    def execute_audio_tasks(
        self,
        tasks: list[AudioTask],
    ) -> tuple[int, int, int, list[str]]:
        """音声タスク群を並列実行して結果を集計する。"""
        total_success = 0
        total_skipped = 0
        total_passthrough = 0
        all_errors: list[str] = []

        with ProcessPoolExecutor(
            max_workers=self.runtime_config.workers,
            initializer=initialize_audio_worker,
        ) as executor:
            futures = {
                executor.submit(
                    process_audio_task,
                    task,
                    self.runtime_config.overwrite,
                ): task.input_path.name
                for task in tasks
            }
            for future in as_completed(futures):
                result = future.result()
                total_success += result.success_count
                total_skipped += result.skipped_count
                total_passthrough += result.passthrough_count
                all_errors.extend(result.error_messages)

        return total_success, total_skipped, total_passthrough, all_errors

    def execute_midi_tasks(
        self,
        tasks: list[MidiTask],
    ) -> tuple[int, int, int, list[str]]:
        """MIDIタスク群を並列実行して結果を集計する。"""
        total_success = 0
        total_skipped = 0
        total_passthrough = 0
        all_errors: list[str] = []

        with ProcessPoolExecutor(max_workers=self.runtime_config.workers) as executor:
            futures = {
                executor.submit(
                    process_midi_task,
                    task,
                    self.runtime_config.overwrite,
                ): task.input_path.name
                for task in tasks
            }
            for future in as_completed(futures):
                result = future.result()
                total_success += result.success_count
                total_skipped += result.skipped_count
                total_passthrough += result.passthrough_count
                all_errors.extend(result.error_messages)

        return total_success, total_skipped, total_passthrough, all_errors

    def log_pairing_summary(
        self,
        *,
        paired_count: int,
        missing_midis: list[Path],
        missing_audios: list[Path],
    ) -> None:
        """音声とMIDIの対応状況をログに出す。"""
        logger.info("ペア対応確認: paired=%d", paired_count)
        if not missing_midis and not missing_audios:
            return

        logger.warning(
            "ペア対応に不一致があります: audio_only=%d, midi_only=%d",
            len(missing_midis),
            len(missing_audios),
        )
        if missing_midis:
            logger.warning(
                "MIDIが見つからない音声例: %s",
                self.format_path_preview(missing_midis),
            )
        if missing_audios:
            logger.warning(
                "音声が見つからないMIDI例: %s",
                self.format_path_preview(missing_audios),
            )

    @staticmethod
    def format_path_preview(relative_paths: list[Path], *, limit: int = 5) -> str:
        """ログ用に相対パスの先頭数件だけを整形する。"""
        preview = ", ".join(path.as_posix() for path in relative_paths[:limit])
        if len(relative_paths) > limit:
            preview += ", ..."
        return preview

    @staticmethod
    def log_error_messages(error_messages: list[str]) -> None:
        """集約したエラーメッセージを順に出力する。"""
        for error_message in error_messages:
            logger.error(error_message)


def run_cli() -> None:
    """CLIエントリポイントとして共通処理を実行する。"""
    runtime_config = RuntimeSwingConfig.from_arguments(parse_arguments())
    SwingDatasetRunner(runtime_config).run()


def main() -> None:
    """単体実行用のメイン関数。"""
    run_cli()


if __name__ == "__main__":
    main()
