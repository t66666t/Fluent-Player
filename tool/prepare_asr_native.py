"""Patch only a generated copy of fixed sherpa-onnx 1.12.12, never Pub cache."""
import argparse
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("source", type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
file = args.source / "sherpa-onnx/csrc/session.cc"
text = file.read_text(encoding="utf-8")
start = text.find("Ort::SessionOptions GetSessionOptionsImpl(")
end = text.find("Ort::SessionOptions GetSessionOptions(const OnlineModelConfig", start)
if start < 0 or end < 0:
    if '// FLUENT_ASR_SESSION_PATCH_V1' not in text:
        raise SystemExit("Unexpected sherpa session source; review the pinned version")
# Provider registration lives in our private component; no platform factory
# headers or second ONNX Runtime are pulled into the application.
prefix = '''// FLUENT_ASR_SESSION_PATCH_V1
#include "sherpa-onnx/csrc/session.h"
#include <algorithm>
#include <unordered_map>
#include "session_options.inc"
namespace sherpa_onnx {
'''
if start >= 0 and end >= 0:
    file.write_text(prefix + text[end:], encoding="utf-8")

# A transducer reuses one SessionOptions for three sessions. ORT's profile
# filenames have second resolution, so sharing the prefix corrupts the JSON.
# Give every session independent options/profile names in the private build.
for name in ['offline-transducer-nemo-model.cc', 'online-zipformer-transducer-model.cc', 'offline-whisper-model.cc']:
    file = args.source / 'sherpa-onnx/csrc' / name
    if not file.exists(): continue
    original = file.read_text(encoding='utf-8')
    content = original.replace('sess_opts_);', 'GetSessionOptions(config_));')
    if content != original:
        file.write_text(content, encoding='utf-8')

# Retain sherpa's frontend, decoder and streaming state implementation. Only
# the session wrapper for explicitly supported model families is extended.
# Ort::Session remains the metadata/API owner and the existing provider path.
for name, model in [
    ('offline-sense-voice-model.cc', 'sense_voice'),
    ('offline-dolphin-model.cc', 'dolphin'),
    ('online-zipformer-transducer-model.cc', 'transducer'),
    ('online-zipformer-transducer-model.h', 'transducer'),
]:
    file = args.source / 'sherpa-onnx/csrc' / name
    original = file.read_text(encoding='utf-8')
    def session(match):
        variable, arguments = match.groups()
        component = variable.split('_')[0] if variable != 'sess_' else ''
        path = f'config_.{model}.{component}' if component else f'config_.{model}.model'
        return f'{variable} = std::make_unique<fluent_asr::Session>({path}, {arguments});'
    content = re.sub(r'(\w*sess_)\s*=\s*std::make_unique<Ort::Session>\((.*?)\);',
                     session, original, flags=re.S)
    content = content.replace('std::unique_ptr<Ort::Session>', 'std::unique_ptr<fluent_asr::Session>')
    if content != original:
        content = '#include "mnn_session.h"\n' + content
        file.write_text(content, encoding='utf-8')

# Upstream selects the sed patch by target OS; an Android cross-build on
# Windows must use the Windows host path, which needs no external sed tool.
file = args.source / 'cmake/openfst.cmake'
original = file.read_text(encoding='utf-8')
content = original.replace('if(NOT WIN32)\n    FetchContent_Declare(openfst',
                           'if(NOT CMAKE_HOST_WIN32)\n    FetchContent_Declare(openfst')
if content != original:
    file.write_text(content, encoding='utf-8')

# The private Windows process must accept Unicode model/cache directories too.
# Stream paths use filesystem's UTF-8 conversion, including tokens/hotwords.
for name, replacements in {
    'file-utils.cc': [('std::ifstream(filename)', 'std::ifstream(std::filesystem::u8path(filename))'),
                      ('std::ifstream input(filename,', 'std::ifstream input(std::filesystem::u8path(filename),')],
    'symbol-table.cc': [('std::ifstream is(filename);', 'std::ifstream is(std::filesystem::u8path(filename));')],
    'online-recognizer-transducer-impl.h': [
        ('std::ifstream is(config_.hotwords_file);', 'std::ifstream is(std::filesystem::u8path(config_.hotwords_file));'),
        ('bpe_encoder_ = std::make_unique<ssentencepiece::Ssentencepiece>(\n            config_.model_config.bpe_vocab);',
         'auto bpe_buf = ReadFile(config_.model_config.bpe_vocab);\n'
         '        std::istringstream bpe_stream(std::string(bpe_buf.begin(), bpe_buf.end()));\n'
         '        bpe_encoder_ = std::make_unique<ssentencepiece::Ssentencepiece>(bpe_stream);'),
    ],
}.items():
    file = args.source / 'sherpa-onnx/csrc' / name
    original = file.read_text(encoding='utf-8')
    content = original
    for old, new in replacements: content = content.replace(old, new)
    if content != original:
        file.write_text('#include <filesystem>\n' + content, encoding='utf-8')
