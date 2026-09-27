"""
stems フォルダ内のオーディオに IRs フォルダのインパルス応答をランダムに適用し、
stems_augments フォルダに保存する事前処理スクリプト。

使い方:
  python preprocess/apply_ir_augmentation.py
  python preprocess/apply_ir_augmentation.py --stems_dir ./stems --ir_dir ./IRs --output_dir ./stems_augments --workers 8
"""

import argparse
import logging
import random
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import fftconvolve

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

# 出力のピーク上限（クリッピング防止）
PEAK_LIMIT = 0.95


def collect_ir_files(ir_dir: Path) -> list[Path]:
    """IRフォルダ内の全 .wav ファイルを再帰的に収集"""
    ir_files = sorted(ir_dir.rglob("*.wav"))
    if not ir_files:
        raise FileNotFoundError(f"IRファイルが見つかりません: {ir_dir}")
    return ir_files


def load_ir_mono(ir_path: Path, target_sample_rate: int) -> np.ndarray:
    """IRファイルをモノラル1次元配列として読み込む"""
    ir_data, ir_sample_rate = sf.read(str(ir_path), dtype="float32", always_2d=True)

    # ステレオの場合はモノラルに変換
    if ir_data.shape[1] > 1:
        ir_data = ir_data.mean(axis=1)
    else:
        ir_data = ir_data[:, 0]

    # サンプリングレートが異なる場合はリサンプリング
    if ir_sample_rate != target_sample_rate:
        import librosa

        ir_data = librosa.resample(
            ir_data, orig_sr=ir_sample_rate, target_sr=target_sample_rate
        )

    return ir_data


def apply_ir_to_audio(
    audio: np.ndarray,
    ir_mono: np.ndarray,
    wet_mix: float = 1.0,
) -> np.ndarray:
    """
    ステレオオーディオにIRを畳み込み、dry/wetをブレンドしてRMS正規化する。
    audio: [channels, frames]
    ir_mono: [ir_frames]
    wet_mix: 0.0ならdryのみ、1.0ならwetのみ
    """
    original_length = audio.shape[1]
    wet_mix = float(np.clip(wet_mix, 0.0, 1.0))

    # 元のRMSを記録（正規化の基準）
    original_rms = np.sqrt(np.mean(audio**2))
    if original_rms < 1e-8:
        return audio

    # 各チャンネルに同じIRを畳み込む
    convolved = np.stack(
        [
            fftconvolve(audio[channel], ir_mono, mode="full")
            for channel in range(audio.shape[0])
        ],
        axis=0,
    )

    # 元のオーディオと同じ長さに切り出す
    convolved = convolved[:, :original_length]

    # RMS正規化: wet単体のRMSを元のRMSに合わせる
    convolved_rms = np.sqrt(np.mean(convolved**2))
    if convolved_rms > 1e-8:
        convolved *= original_rms / convolved_rms

    result = (1.0 - wet_mix) * audio + wet_mix * convolved

    # ピーク制限
    peak = np.abs(result).max()
    if peak > PEAK_LIMIT:
        result *= PEAK_LIMIT / peak

    return result.astype(np.float32)


def process_single_stem(
    stem_path: Path,
    output_path: Path,
    ir_files: list[Path],
    target_sample_rate: int,
    wet_mix_range: tuple[float, float],
    seed: int,
) -> str | None:
    """1つのステムにランダムなIRを適用して保存する"""
    try:
        rng = random.Random(seed)
        ir_path = rng.choice(ir_files)

        audio, sample_rate = sf.read(str(stem_path), dtype="float32", always_2d=True)
        audio = audio.T  # [channels, frames]

        if sample_rate != target_sample_rate:
            logger.warning(
                f"サンプリングレートが想定と異なります: {stem_path.name} "
                f"(期待: {target_sample_rate}, 実際: {sample_rate})"
            )
            return f"SKIP(sr): {stem_path.name}"

        ir_mono = load_ir_mono(ir_path, target_sample_rate)
        wet_mix = rng.uniform(wet_mix_range[0], wet_mix_range[1])
        result = apply_ir_to_audio(audio, ir_mono, wet_mix=wet_mix)

        # channels-lastに戻して保存
        sf.write(str(output_path), result.T, target_sample_rate, subtype="PCM_16")
        return None

    except Exception as e:
        return f"ERROR: {stem_path.name}: {e}"


def main():
    parser = argparse.ArgumentParser(
        description="ステムオーディオにIRをオフラインで適用する事前処理スクリプト"
    )
    parser.add_argument(
        "--stems_dir",
        type=Path,
        default=Path("./stems"),
        help="入力ステムのディレクトリ",
    )
    parser.add_argument(
        "--ir_dir",
        type=Path,
        default=Path("./IRs"),
        help="IRファイルのディレクトリ",
    )
    parser.add_argument(
        "--output_dir",
        type=Path,
        default=Path("./stems_augments"),
        help="出力先ディレクトリ",
    )
    parser.add_argument(
        "--workers",
        type=int,
        default=4,
        help="並列処理のワーカー数",
    )
    parser.add_argument(
        "--sample_rate",
        type=int,
        default=22050,
        help="ターゲットサンプリングレート",
    )
    parser.add_argument(
        "--seed",
        type=int,
        default=42,
        help="乱数シード（再現性のため）",
    )
    parser.add_argument(
        "--min_wet_mix",
        type=float,
        default=0.0,
        help="IR wet成分の最小ブレンド量。0.0=dryのみ, 1.0=wetのみ",
    )
    parser.add_argument(
        "--max_wet_mix",
        type=float,
        default=1.0,
        help="IR wet成分の最大ブレンド量。0.0=dryのみ, 1.0=wetのみ",
    )
    args = parser.parse_args()

    min_wet_mix = float(np.clip(args.min_wet_mix, 0.0, 1.0))
    max_wet_mix = float(np.clip(args.max_wet_mix, 0.0, 1.0))
    if min_wet_mix > max_wet_mix:
        logger.error("--min_wet_mix は --max_wet_mix 以下にしてください。")
        return
    wet_mix_range = (min_wet_mix, max_wet_mix)

    stems_dir = args.stems_dir.resolve()
    ir_dir = args.ir_dir.resolve()
    output_dir = args.output_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    if not stems_dir.exists():
        logger.error(f"ステムディレクトリが見つかりません: {stems_dir}")
        return
    if not ir_dir.exists():
        logger.error(f"IRディレクトリが見つかりません: {ir_dir}")
        return

    ir_files = collect_ir_files(ir_dir)
    logger.info(f"IRファイル数: {len(ir_files)}")

    # 処理対象のステムファイルを収集
    stem_files = sorted(
        p for p in stems_dir.iterdir() if p.suffix.lower() in (".wav", ".flac")
    )
    logger.info(f"ステムファイル数: {len(stem_files)}")

    # 既に処理済みのファイルをスキップ
    pending_tasks = []
    for i, stem_path in enumerate(stem_files):
        output_path = output_dir / f"{stem_path.stem}.wav"
        if output_path.exists():
            continue
        # ファイルごとに決定的なシードを割り当て
        file_seed = args.seed + i
        pending_tasks.append((stem_path, output_path, file_seed))

    skipped_count = len(stem_files) - len(pending_tasks)
    if skipped_count > 0:
        logger.info(f"処理済みスキップ: {skipped_count} ファイル")

    if not pending_tasks:
        logger.info("すべてのファイルが処理済みです。")
        return

    logger.info(
        f"処理対象: {len(pending_tasks)} ファイル "
        f"(ワーカー数: {args.workers}, wet_mix={wet_mix_range[0]:.2f}-{wet_mix_range[1]:.2f})"
    )

    # tqdm はオプショナル
    try:
        from tqdm import tqdm

        progress_bar = tqdm(total=len(pending_tasks), desc="IR適用中")
    except ImportError:
        progress_bar = None

    error_count = 0
    with ProcessPoolExecutor(max_workers=args.workers) as executor:
        futures = {
            executor.submit(
                process_single_stem,
                stem_path,
                output_path,
                ir_files,
                args.sample_rate,
                wet_mix_range,
                file_seed,
            ): stem_path
            for stem_path, output_path, file_seed in pending_tasks
        }

        for future in as_completed(futures):
            error_message = future.result()
            if error_message:
                logger.warning(error_message)
                error_count += 1
            if progress_bar is not None:
                progress_bar.update(1)

    if progress_bar is not None:
        progress_bar.close()

    logger.info(f"完了: {len(pending_tasks) - error_count} 成功, {error_count} エラー")


if __name__ == "__main__":
    main()
