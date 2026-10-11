# /// script
# requires-python = "==3.12.*"
# dependencies = [
#   "coremltools==9.0",
#   "huggingface_hub>=0.30",
#   "numpy==2.5.4",
#   "onnx==1.23.2",
#   "onnx2torch==1.5.15",
#   "onnxruntime==1.31.0",
#   "protobuf==7.36.2",
#   "sentencepiece==0.2.2",
#   "torch==2.7.0",
#   "torchvision==0.22.0",
# ]
# ///
"""Builds the punctuation model the app bundles: punct_cap_seg_en, ONNX -> Core ML.

    uv run Scripts/punctuation_model.py <output directory>

Writes Punctuation.mlpackage, vocabulary.tsv (the tokenizer's pieces, for PieceTokenizer) and
LICENSE. Run by Scripts/make-punctuation-model.sh, which is what the build scripts call.

The model is punct_cap_seg_en, from 1-800-BAD-CODE/punctuation_fullstop_truecase_english
(Apache-2.0), pinned to one revision. It goes ONNX -> PyTorch (onnx2torch) -> Core ML, fixed at one
window of 256 tokens:

- Activations stay float32. The graph's attention-mask constant overflows in float16.
- Weights are int8, which is weight-only and quarters the size (199 MB -> 50 MB). On the fixtures
  and DiPCo windows int8 differs from the original on about 30 near-tie labels in 70,000, and
  scores the same as the original on every fixture.
- torch is pinned to 2.7, the newest coremltools 9 was tested against; newer versions fail to
  convert.

Before saving, every window of a built-in test text is run through both the original ONNX model
and the converted one, and the build fails if they disagree on more than a handful of labels.
"""
import sys
from pathlib import Path

import coremltools as ct
import coremltools.optimize.coreml as cto
import numpy as np
import onnx
import onnx2torch
import onnxruntime as ort
import sentencepiece as spm
import torch
from coremltools.converters.mil.frontend.torch.torch_op_registry import _TORCH_OPS_REGISTRY
from huggingface_hub import hf_hub_download
from sentencepiece import sentencepiece_model_pb2

# Renamed from 1-800-BAD-CODE/punct_cap_seg_en; the old name redirects. Same revision.
REPO = "1-800-BAD-CODE/punctuation_fullstop_truecase_english"
REVISION = "b26fd1c40e88678859048898218ea4edcc24c84a"
LENGTH = 256
BOS, EOS, PAD = 1, 2, 3

# onnx2torch emits the long spellings of the comparison ops; coremltools knows the short ones.
_ops = _TORCH_OPS_REGISTRY.name_to_func_mapping
for alias, name in (("greater", "gt"), ("less", "lt"), ("greater_equal", "ge"),
                    ("less_equal", "le"), ("not_equal", "ne")):
    _ops.setdefault(alias, _ops[name])

CHECK_TEXT = (
    "morning margaret i'm doctor feldman your blood pressure is one hundred and forty eight over "
    "ninety two today i'd like you to start lisinopril ten milligrams once a day okay should i "
    "still take the metformin yes keep taking the metformin that hasn't changed do not take it with "
    "grapefruit juice and don't skip a dose even if you feel fine if you don't feel better in three "
    "days call the office the number is five five five zero one four two "
    "um i love basketball i wish i was more well rounded and sports fans though but it's really "
    "only all basketball i like to play it i like to watch it i'm a la lakers fan yeah um lifelong "
    "so huge kobe bryant fan me too so danielle and i are on the same team here really"
)


class Wrapped(torch.nn.Module):
    """The three outputs the app reads, as int32. Pre-punctuation (Spanish ¿) is dropped."""

    def __init__(self, inner):
        super().__init__()
        self.inner = inner

    def forward(self, input_ids):
        _, post, cap, seg = self.inner(input_ids.long())
        return post.int(), cap.int(), seg.int()


def download(name):
    return hf_hub_download(REPO, name, revision=REVISION)


def vocabulary(path, out):
    proto = sentencepiece_model_pb2.ModelProto()
    proto.ParseFromString(Path(path).read_bytes())
    assert proto.trainer_spec.model_type == 1, "PieceTokenizer implements unigram only"
    assert proto.normalizer_spec.add_dummy_prefix and not proto.normalizer_spec.precompiled_charsmap
    lines = []
    for piece in proto.pieces:
        assert "\t" not in piece.piece and "\n" not in piece.piece
        lines.append(f"{piece.piece}\t{piece.score!r}\t{piece.type}")
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")


def check(ml, onnx_path, sp_path):
    sp = spm.SentencePieceProcessor(model_file=sp_path)
    session = ort.InferenceSession(onnx_path)
    ids = sp.encode(CHECK_TEXT)
    differing = total = 0
    for start in range(0, len(ids), LENGTH - 2):
        window = [BOS] + ids[start:start + LENGTH - 2] + [EOS]
        n = len(window)
        _, post, cap, seg = session.run(None, {"input_ids": np.array([window], dtype=np.int64)})
        padded = np.full((1, LENGTH), PAD, dtype=np.int32)
        padded[0, :n] = window
        out = ml.predict({"input_ids": padded})
        differing += int((out["post_preds"][0, :n] != post[0, :n]).sum()
                         + (out["cap_preds"][0, :n].astype(bool) != cap[0, :n]).sum()
                         + (out["seg_preds"][0, :n].astype(bool) != seg[0, :n]).sum())
        total += n * 18
    print(f"check: {differing} of {total} labels differ from the original")
    if differing > total // 1000:
        sys.exit("the converted model does not match the original")


def main(out_dir):
    out = Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    onnx_path, sp_path = download("punct_cap_seg_en.onnx"), download("spe_32k_lc_en.model")

    model = Wrapped(onnx2torch.convert(onnx.load(onnx_path))).eval()
    example = torch.full((1, LENGTH), PAD, dtype=torch.int32)
    example[0, :6] = torch.tensor([BOS, 100, 200, 300, 400, EOS])
    with torch.no_grad():
        traced = torch.jit.trace(model, example)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=(1, LENGTH), dtype=np.int32)],
        outputs=[ct.TensorType(name="post_preds"), ct.TensorType(name="cap_preds"),
                 ct.TensorType(name="seg_preds")],
        compute_precision=ct.precision.FLOAT32,
        minimum_deployment_target=ct.target.iOS18,
        convert_to="mlprogram",
    )
    config = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric"))
    ml = cto.linear_quantize_weights(ml, config)
    ml.short_description = (f"{REPO}@{REVISION[:7]} (Apache-2.0): punctuation, casing and "
                            "sentence ends, one window of 256 tokens")
    check(ml, onnx_path, sp_path)

    ml.save(str(out / "Punctuation.mlpackage"))
    vocabulary(sp_path, out / "vocabulary.tsv")
    (out / "SOURCE.txt").write_text(
        f"https://huggingface.co/{REPO} revision {REVISION}\nApache-2.0. Built by "
        "Scripts/punctuation_model.py.\n", encoding="utf-8")
    print("saved", out)


if __name__ == "__main__":
    main(sys.argv[1])
