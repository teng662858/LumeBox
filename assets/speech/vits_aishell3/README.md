# VITS AISHELL3 offline speech resource

Source archive: https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-aishell3.tar.bz2
Model card: https://huggingface.co/csukuangfj/vits-zh-aishell3
Upstream training weights: https://huggingface.co/jackyqs/vits-aishell3-175-chinese
ONNX conversion and lexicon generation: https://github.com/csukuangfj/vits_chinese
Runtime: sherpa-onnx 1.13.8, https://github.com/k2-fsa/sherpa-onnx (Apache-2.0).

The archive is downloaded on demand and is not bundled with the app.
manifest.json records the archive and runtime file SHA-256 values. Preparation
validates the archive, extracts only the seven whitelisted runtime files, and
validates them before loading. Existing installed models remain compatible.

Measured runtime format: 8,000 Hz mono, 174 speaker IDs (0–173).
Role assignment is a reader preference; a numeric speaker ID is not a verified
gender label. Unknown dialogue names use stable alternating role assignment.
This is a speech synthesis model, not a local text-generation language model.
