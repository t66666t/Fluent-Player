"""Narrow, reproducible patches to the separately pinned Qwen runtime.

Only generated build-cache sources are changed; existing ASR/GGUF runtimes and
the Pub cache are never edited. Source matches are checked before replacement.
"""
from pathlib import Path
import re


def replace(path, old, new):
    source = path.read_text(encoding='utf-8')
    if source.count(old) != 1:
        raise ValueError(f'Pinned Qwen source changed: {path.name}: {old[:70]}')
    path.write_text(source.replace(old, new), encoding='utf-8')


def prepare(source: Path, ggml: Path, prefix_header: Path):
    """Apply exactly once while holding the builder's source-cache lock."""
    # Our entry point has already selected/loaded the CPU module. The upstream
    # CPU shim's load_all would otherwise re-enter a failed GPU driver on retry.
    replace(source / 'src/core/ggml_cpu_backend.h',
            '        ggml_backend_load_all();',
            '        // CPU module initialization is owned by the application entry point.')
    with (ggml/'src/ggml-backend-reg.cpp').open('a',encoding='utf-8') as output:
        output.write('''
#ifdef GGML_BACKEND_DL
extern "C" GGML_API ggml_backend_reg_t fluent_qwen_load_cpu(const char* path) {
    return ggml_backend_load_best("cpu", true, path);
}
#endif
''')
    header = source / 'src/qwen3_asr.h'
    replace(header, '    bool use_gpu;', '    int backend_kind; // app: 0=auto, 2=Vulkan, 3=CUDA, 4=Metal\n    bool use_gpu;')
    code = source / 'src/qwen3_asr.cpp'
    replace(code, '    core_qwen3_forced_aligner::fix_timestamps(ts_classes);',
            '    // Application contract: reject invalid acoustic order; never interpolate it.\n'
            '    if (!std::is_sorted(ts_classes.begin(), ts_classes.end())) return -8;')
    replace(code, '    int n_threads = 4;', '    int n_threads = 4;\n    uint64_t app_gpu_ops = 0;\n    bool (*app_abort)(void*) = nullptr;\n    void* app_abort_data = nullptr;')
    replace(code, '    p.use_gpu = ctx->params.use_gpu;', '    p.use_gpu = ctx->params.use_gpu;\n    p.backend_kind = ctx->params.backend_kind;')
    replace(code, '    return ctx->audio_ca;\n}', '    if (ctx->audio_ca) fluent_audio_set_abort(ctx->audio_ca, ctx->app_abort, ctx->app_abort_data);\n    return ctx->audio_ca;\n}')
    replace(code, '#include "../crisp_audio/include/crisp_audio.h"', '#include "../crisp_audio/include/crisp_audio.h"\n#include "core/fluent_trace.h"\nextern "C" void fluent_audio_set_abort(crisp_audio_context*, bool(*)(void*), void*);\nextern "C" uint64_t fluent_audio_gpu_ops(crisp_audio_context*);')
    value=code.read_text(encoding='utf-8').replace('ggml_backend_sched_graph_compute(ctx->sched, gf)',
        'fluent_qwen_graph_compute(ctx->sched, gf, &ctx->app_gpu_ops)')
    code.write_text(value,encoding='utf-8')
    replace(code,
            'ctx->backend = params.use_gpu ? crispasr_init_gpu_backend() : core_cpu_backend::init();',
            '''ctx->backend = nullptr;
    if (params.use_gpu && params.backend_kind) {
        const char* wanted = params.backend_kind == 2 ? "Vulkan" : params.backend_kind == 3 ? "CUDA" : "Metal";
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            auto device = ggml_backend_dev_get(i);
            auto registry = ggml_backend_dev_backend_reg(device);
            if (std::strcmp(ggml_backend_reg_name(registry), wanted) == 0) {
                ctx->backend = ggml_backend_dev_init(device, nullptr); break;
            }
        }
        if (!ctx->backend) { delete ctx; return nullptr; }
    } else { ctx->backend = params.use_gpu ? crispasr_init_gpu_backend() : core_cpu_backend::init(); }''')
    with code.open('a', encoding='utf-8') as out:
        out.write('''
extern "C" const char* fluent_qwen_backend_name(qwen3_asr_context* ctx) {
    return ctx && ctx->backend ? ggml_backend_name(ctx->backend) : "";
}
extern "C" uint64_t fluent_qwen_gpu_ops(qwen3_asr_context* ctx) {
    return ctx ? ctx->app_gpu_ops + fluent_audio_gpu_ops(ctx->audio_ca) : 0;
}
extern "C" void fluent_qwen_set_abort(qwen3_asr_context* ctx, bool (*callback)(void*), void* data) {
    if (!ctx) return;
    ctx->app_abort = callback; ctx->app_abort_data = data;
    for (auto backend : {ctx->backend, ctx->backend_cpu}) {
        if (!backend || !core_cpu_backend::is_cpu(backend)) continue;
#ifdef GGML_BACKEND_DL
        auto registry = ggml_backend_dev_backend_reg(ggml_backend_get_device(backend));
        auto fn = reinterpret_cast<void(*)(ggml_backend_t, bool(*)(void*), void*)>(
            ggml_backend_reg_get_proc_address(registry, "ggml_backend_set_abort_callback"));
        if (fn) fn(backend, callback, data);
#else
        ggml_backend_cpu_set_abort_callback(backend, callback, data);
#endif
    }
}
''')
    audio_header = source / 'crisp_audio/include/crisp_audio.h'
    replace(audio_header, '    bool use_gpu;', '    int backend_kind;\n    bool use_gpu;')
    audio_code = source / 'crisp_audio/src/audio_tower.cpp'
    value=audio_code.read_text(encoding='utf-8')
    marker='struct crisp_audio_context {'
    if value.count(marker)!=1: raise ValueError('Pinned audio context changed')
    value=value.replace(marker,marker+'\n    uint64_t app_gpu_ops = 0;')
    value=value.replace('#include "core/mel.h"','#include "core/mel.h"\n#include "core/fluent_trace.h"')
    value=value.replace('ggml_backend_sched_graph_compute(ctx->sched, gf)',
        'fluent_qwen_graph_compute(ctx->sched, gf, &ctx->app_gpu_ops)')
    audio_code.write_text(value,encoding='utf-8')
    replace(audio_code, 'ggml_backend_dev_t gdev = ggml_backend_dev_by_type(GGML_BACKEND_DEVICE_TYPE_GPU);', '''ggml_backend_dev_t gdev = nullptr;
        const char* wanted = eff.backend_kind == 2 ? "Vulkan" : eff.backend_kind == 3 ? "CUDA" : eff.backend_kind == 4 ? "Metal" : "";
        for (size_t i = 0; i < ggml_backend_dev_count(); ++i) {
            auto dev = ggml_backend_dev_get(i);
            if (ggml_backend_dev_type(dev) == GGML_BACKEND_DEVICE_TYPE_GPU &&
                (!*wanted || std::strcmp(ggml_backend_reg_name(ggml_backend_dev_backend_reg(dev)), wanted) == 0)) { gdev = dev; break; }
        }''')
    with audio_code.open('a', encoding='utf-8') as out:
        out.write('''
extern "C" uint64_t fluent_audio_gpu_ops(crisp_audio_context* ctx) { return ctx ? ctx->app_gpu_ops : 0; }
extern "C" void fluent_audio_set_abort(crisp_audio_context* ctx, bool (*callback)(void*), void* data) {
    if (!ctx) return;
    for (auto backend : {ctx->backend, ctx->backend_cpu}) {
        if (!backend || !core_cpu_backend::is_cpu(backend)) continue;
#ifdef GGML_BACKEND_DL
        auto registry = ggml_backend_dev_backend_reg(ggml_backend_get_device(backend));
        auto fn = reinterpret_cast<void(*)(ggml_backend_t, bool(*)(void*), void*)>(
            ggml_backend_reg_get_proc_address(registry, "ggml_backend_set_abort_callback"));
        if (fn) fn(backend, callback, data);
#else
        ggml_backend_cpu_set_abort_callback(backend, callback, data);
#endif
    }
}
''')
    (source/'src/core/fluent_trace.h').write_text('''#pragma once
#include "ggml.h"
#include "ggml-backend.h"
#include <cstdint>
inline ggml_status fluent_qwen_graph_compute(ggml_backend_sched_t scheduler, ggml_cgraph* graph, uint64_t* count) {
    uint64_t gpu=0;
    for(int i=0;i<ggml_graph_n_nodes(graph);++i) {
        auto node=ggml_graph_node(graph,i);
        auto backend=ggml_backend_sched_get_tensor_backend(scheduler,node);
        if(node->op!=GGML_OP_NONE && backend &&
            ggml_backend_dev_type(ggml_backend_get_device(backend))!=GGML_BACKEND_DEVICE_TYPE_CPU) ++gpu;
    }
    auto status=ggml_backend_sched_graph_compute(scheduler,graph);
    if(status==GGML_STATUS_SUCCESS) *count+=gpu;
    return status;
}
''',encoding='utf-8')
    # UTF-8 -> wide paths on Windows for both metadata reads and weight mmap.
    # ggml already uses its Windows-aware fopen helper. core_gguf's mmap path
    # is separately patched where it opens the same file by Win32 API.
    loader = source / 'src/core/gguf_loader.cpp'
    value = loader.read_text(encoding='utf-8')
    value = value.replace('CreateFileA(path,', 'CreateFileW(std::filesystem::u8path(path).c_str(),')
    value = value.replace('#include <limits>', '#include <limits>\n#include <filesystem>')
    loader.write_text(value, encoding='utf-8')
    # Prefix all ggml/gguf C identifiers for mobile static linking. Desktop
    # dynamic-backend builds instead live in their own helper process/directory.
    identifiers = set()
    # Keep the nested host shader compiler below Windows' MSBuild path limit.
    replace(ggml / 'src/ggml-vulkan/CMakeLists.txt',
            '        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vulkan-shaders',
            '        SOURCE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/vulkan-shaders\n'
            '        BINARY_DIR ${CMAKE_BINARY_DIR}/vkgen')
    # Android API 24's loader does not export this Vulkan 1.1 symbol. Resolve
    # it through the selected instance; old drivers fail safely back to CPU.
    replace(ggml / 'src/ggml-vulkan/ggml-vulkan.cpp',
            '        vkGetPhysicalDeviceFeatures2(device->physical_device, &device_features2);',
            '''        auto app_get_features2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
            vkGetInstanceProcAddr(vk_instance.instance, "vkGetPhysicalDeviceFeatures2"));
        if (!app_get_features2) throw std::runtime_error("Vulkan 1.1 device features unavailable");
        app_get_features2(device->physical_device, &device_features2);''')
    for device in ['physical_device', 'vkdev']:
        replace(ggml / 'src/ggml-vulkan/ggml-vulkan.cpp',
                f'    vkGetPhysicalDeviceFeatures2({device}, &device_features2);',
                '    auto app_get_features2 = reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(\n'
                '        vkGetInstanceProcAddr(vk_instance.instance, "vkGetPhysicalDeviceFeatures2"));\n'
                '    if (!app_get_features2) throw std::runtime_error("Vulkan 1.1 device features unavailable");\n'
                f'    app_get_features2({device}, &device_features2);')
    for path in ggml.rglob('*'):
        if path.suffix in ('.h', '.hpp', '.c', '.cpp', '.cu', '.cuh', '.m', '.mm'):
            identifiers.update(re.findall(r'\b(?:ggml|gguf)_[A-Za-z0-9_]+\b', path.read_text(encoding='utf-8', errors='ignore')))
    prefix_header.write_text('#pragma once\n' + ''.join(f'#define {name} fluent_qwen_{name}\n' for name in sorted(identifiers)), encoding='utf-8')
