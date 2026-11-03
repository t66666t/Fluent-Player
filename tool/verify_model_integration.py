"""Verify model additions without downloading weights or changing app settings.

Run from any directory. The default suite checks shipped identities, task
compatibility, downloads, OCR and transcription/translation workflows. --native
also runs actual Windows ASR/GGUF inference using already prepared local files.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent
TESTS = [
    'cloud_asr_contract_test', 'cloud_asr_catalog_test', 'cloud_asr_pipeline_test',
    'cloud_asr_network_test', 'cloud_asr_editor_test', 'cloud_asr_runner_test',
    'cloud_asr_retry_test',
    'asr_language_options_test', 'transcription_language_selector_test',
    'batch_subtitle_configuration_layout_test', 'batch_subtitle_live_settings_test',
    'settings_export_test', 'default_settings_trial_test',
    'cohere_asr_integration_test',
    'qwen_asr_integration_test',
    'transcription_hotword_store_test', 'ai_transcription_configuration_test',
    'ai_transcription_button_width_test',
    'model_integration_test', 'new_asr_models_test', 'model_center_test', 'model_center_navigation_test',
    'model_download_sources_test', 'model_file_transfer_test',
    'model_download_concurrency_test', 'model_download_network_test',
    'model_retirement_test', 'asr_enhancement_test',
    'network_settings_service_test', 'network_dio_stream_test',
    'gongyi_network_connection_test', 'translation_network_pool_test',
    'gongyi_resume_test', 'gongyi_result_polling_test',
    'bing_subtitle_translator_test',
    'asr_enhancement_pipeline_test', 'asr_acceleration_test',
    'asr_window_ownership_test', 'local_asr_boundary_test',
    'bounded_model_pipeline_test', 'local_translation_batch_test',
    'local_translation_acceleration_test', 'local_translation_handoff_test',
    'local_translation_pipeline_recovery_test', 'cloud_local_translation_stream_test',
    'translation_compute_policy_test', 'translation_android_inference_test',
    'translation_worker_protocol_test',
    'transcription_resume_restart_test', 'transcription_reliability_test',
    'transcription_queue_logic_test', 'transcription_subtitle_lifecycle_test',
    'transcription_queue_scheduling_test', 'ai_transcription_queued_start_test',
    'transcription_online_source_test', 'task_queue_reorder_test',
    'subtitle_transcription_stop_test', 'subtitle_output_preparer_test',
    'subtitle_translation_service_test', 'smart_subtitle_translation_test',
    'ocr_upgrade_test', 'ocr_subtitle_geometry_test',
    'ocr_model_flow_test', 'ocr_models_pane_test',
    'ocr_subtitle_models_test', 'ocr_frame_pipeline_test',
    'ocr_execution_policy_test', 'ocr_runtime_cache_test',
    'ocr_progress_tracker_test',
    'ocr_estimate_panel_test', 'inference_resource_governor_test',
    'device_resource_monitor_test',
    'ocr_compute_policy_test', 'ocr_compute_settings_test',
    'ocr_android_worker_test', 'ocr_accelerator_contract_test',
    'ocr_subtitle_stream_test', 'ocr_stream_playback_test',
    'streaming_playback_test', 'streaming_subtitle_test',
    'streaming_subtitle_widgets_test',
    'subtitle_sidebar_stream_alignment_test',
    'subtitle_generation_footer_test', 'ocr_generation_footer_test',
    'video_compose_resource_safety_test',
]
ANALYSIS = [
    'lib/features/model_center/cloud_asr_types.dart',
    'lib/features/model_center/cloud_asr_transport.dart',
    'lib/features/model_center/cloud_asr_parser.dart',
    'lib/features/model_center/cloud_asr_adapters.dart',
    'lib/features/model_center/cloud_asr_catalog.dart',
    'lib/features/model_center/cloud_asr_pipeline.dart',
    'lib/features/model_center/cloud_asr_editor.dart',
    'lib/services/network/network_http.dart',
    'lib/services/network/network_models.dart',
    'lib/services/network/network_settings_service.dart',
    'test/cloud_asr_test_support.dart', 'test/cloud_asr_contract_test.dart',
    'test/cloud_asr_catalog_test.dart', 'test/cloud_asr_pipeline_test.dart',
    'test/cloud_asr_network_test.dart', 'test/cloud_asr_editor_test.dart',
    'test/cloud_asr_runner_test.dart', 'test/cloud_asr_retry_test.dart',
    'lib/features/model_center/asr_language_options.dart',
    'lib/widgets/transcription_language_selector.dart',
    'lib/widgets/batch_subtitle_configuration_bar.dart',
    'lib/widgets/transcription_restart_dialog.dart',
    'test/asr_language_options_test.dart', 'test/transcription_language_selector_test.dart',
    'lib/features/model_center/cohere_asr_runtime.dart',
    'test/cohere_asr_integration_test.dart',
    'test/cohere_asr_pipeline_native_test.dart',
    'test/japanese_asr_ablation_native_test.dart',
    'lib/services/transcription_hotword_store.dart',
    'lib/widgets/ai_transcription_configuration.dart',
    'lib/widgets/transcription_hotword_editor.dart',
    'lib/widgets/ai_transcription_panel.dart',
    'lib/widgets/model_center_button.dart',
    'lib/widgets/translation_language_controls.dart',
    'lib/services/settings_export_service.dart',
    'test/transcription_hotword_store_test.dart',
    'test/ai_transcription_configuration_test.dart',
    'lib/features/model_center/model_file_transfer.dart',
    'lib/services/network/network_http.dart',
    'lib/features/model_center/model_download_sources.dart',
    'lib/features/model_center/ios_model_download.dart',
    'test/model_file_transfer_test.dart',
    'test/model_download_concurrency_test.dart',
    'test/model_download_network_test.dart',
    'test/model_retirement_test.dart',
    'lib/features/model_center/model_center_screen.dart',
    'test/model_center_test.dart',
    'lib/features/model_center/asr_benchmark.dart',
    'lib/features/model_center/model_transcription.dart',
    'lib/features/model_center/asr_enhancement_screen.dart',
    'lib/services/app_licenses.dart',
    'test/qwen_asr_native_test.dart',
    'test/qwen_asr_cpu_pipeline_native_test.dart',
    'test/qwen_asr_readiness_native_test.dart',
    'test/qwen_asr_cpu_fallback_native_test.dart',
    'lib/features/model_center/qwen_asr_runtime.dart',
    'lib/features/model_center/asr_text_processing.dart',
    'lib/features/model_center/asr_native_enhancer.dart',
    'lib/features/model_center/asr_enhancement_processing.dart',
    'lib/features/model_center/asr_enhancement_options.dart',
    'lib/features/model_center/asr_accelerator_transport.dart',
    'lib/features/model_center/subtitle_segmentation.dart',
    'lib/models/subtitle_asr_info.dart',
    'lib/models/subtitle_model.dart',
    'test/qwen_asr_integration_test.dart',
    'lib/features/model_center/model_adapters.dart',
    'lib/features/model_center/local_asr_model_adapter.dart',
    'lib/features/model_center/local_asr_worker.dart',
    'lib/features/model_center/native_asr_cpu_decoder.dart',
    'lib/features/model_center/model_catalog.dart',
    'lib/features/model_center/model_center_service.dart',
    'lib/features/model_center/local_translation_batch.dart',
    'lib/features/model_center/translation_compute_policy.dart',
    'lib/features/model_center/translation_android_inference.dart',
    'lib/features/model_center/translation_inference.dart',
    'lib/features/model_center/asr_accelerated_decoder.dart',
    'lib/features/model_center/local_subtitle_translator.dart',
    'tool/model_integration_contract.dart',
    'test/model_integration_test.dart',
    'test/model_integration_native_test.dart',
    'test/new_asr_models_test.dart',
    'test/new_asr_models_native_test.dart',
    'test/asr_enhancement_pipeline_test.dart',
    'lib/models/ocr_accelerator_contract.dart',
    'lib/services/ocr_native_accelerator.dart',
    'lib/services/ocr_device_probe.dart',
    'lib/services/ocr_inference_engine.dart',
    'lib/services/ocr_subtitle_geometry.dart',
    'lib/services/ocr_processing_worker.dart',
    'test/ocr_subtitle_geometry_test.dart',
    'test/ocr_subtitle_geometry_native_test.dart',
    'lib/services/ocr_onnx.dart',
    'lib/services/ocr_worker_server.dart',
    'lib/services/ocr_android_worker.dart',
    'lib/services/ocr_process_worker.dart',
    'lib/services/ocr_subtitle_stream.dart',
    'lib/services/ocr_subtitle_manager.dart',
    'lib/services/streaming_subtitle_store.dart',
    'lib/services/subtitle_stream_source.dart',
    'lib/widgets/subtitle_stream_provider.dart',
    'lib/main.dart',
    'lib/services/transcription_manager.dart',
    'lib/models/batch_subtitle_task_view.dart',
    'lib/widgets/task_queue_table.dart',
    'test/transcription_queue_scheduling_test.dart',
    'test/ai_transcription_queued_start_test.dart',
    'test/transcription_online_source_test.dart',
    'test/task_queue_reorder_test.dart',
    'lib/services/bing_subtitle_translator.dart',
    'test/bing_subtitle_translator_test.dart',
    'lib/services/media_playback_service.dart',
    'lib/services/app_storage_audit.dart',
    'lib/services/ocr_frame_pipeline.dart',
    'lib/widgets/subtitle_management_sheet.dart',
    'lib/widgets/ocr_subtitle_panel.dart',
    'test/ocr_subtitle_stream_test.dart',
    'test/ocr_stream_playback_test.dart',
    'test/ocr_stream_native_test.dart',
    'lib/widgets/subtitle_generation_footer.dart',
    'test/subtitle_generation_footer_test.dart',
    'test/ocr_generation_footer_test.dart',
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native', action='store_true')
    parser.add_argument('--model-root', type=Path,
                        default=ROOT / '.artifacts/model-center/native')
    parser.add_argument('--native-lib-dir', type=Path,
                        default=ROOT / 'build/native_assets/windows')
    parser.add_argument('--output', type=Path,
                        default=ROOT / '.artifacts/model-integration')
    args = parser.parse_args()
    flutter = shutil.which('flutter') or shutil.which('flutter.bat')
    if not flutter:
        parser.error('Flutter must be on PATH.')
    args.output.mkdir(parents=True, exist_ok=True)

    def run(name, command, environment=None):
        log = args.output / (name + '.log')
        print(f'Running {name}; log: {log}', flush=True)
        with log.open('w', encoding='utf-8') as output:
            result = subprocess.run([flutter, *command], cwd=ROOT,
                                    stdin=subprocess.DEVNULL,
                                    stdout=output, stderr=subprocess.STDOUT,
                                    env=environment)
        if result.returncode:
            print(log.read_text(encoding='utf-8', errors='replace')[-10000:])
            raise SystemExit(result.returncode)
        print(f'{name}: passed', flush=True)

    native_command = None
    if args.native:
        if os.name != 'nt':
            parser.error('--native currently verifies the packaged Windows runtime; validate other platforms separately.')
        for name in ('llama.dll', 'llamadart.dll', 'ggml.dll', 'ggml-base.dll', 'ggml-cpu.dll'):
            if not (args.native_lib_dir / name).is_file():
                parser.error(f'Missing prepared native library: {args.native_lib_dir / name}')
        catalog = json.loads((ROOT / 'assets/models/catalog.json').read_text(encoding='utf-8'))
        for model in catalog['models']:
            if model.get('retired') or model['purpose'] not in ('transcription', 'translation'):
                continue
            for file in model['files']:
                path = args.model_root / model['id'] / file['name']
                if not path.is_file() or path.stat().st_size != file['bytes']:
                    parser.error(f'Missing/incomplete local model file: {path}. No weights were downloaded.')
        native_command = [
            'test', '--no-pub', '--reporter', 'expanded', '--concurrency=1',
            f'--dart-define=MODEL_INTEGRATION_MODEL_ROOT={args.model_root.resolve().as_posix()}',
            f'--dart-define=MODEL_INTEGRATION_REPORT={(args.output.resolve() / "native-results.json").as_posix()}',
            f'--dart-define=QWEN_NATIVE_MODEL_ROOT={args.model_root.resolve().as_posix()}',
            'test/model_integration_native_test.dart',
            'test/qwen_asr_native_test.dart',
            'test/qwen_asr_readiness_native_test.dart',
        ]

    run('analysis', ['analyze', '--no-pub', '--no-fatal-infos', *ANALYSIS])
    # These suites include real file/process workflows with bounded timeouts.
    # Avoid making their completion depend on competing Flutter test hosts.
    run('regression', ['test', '--no-pub', '--reporter', 'expanded', '--concurrency=1',
                       *[f'test/{name}.dart' for name in TESTS]])
    if native_command:
        # Match the project's existing Flutter-native test recipe. Keep the
        # override scoped to this child; never change the app's DLLs or settings.
        native_environment = dict(os.environ)
        native_environment['LLAMADART_NATIVE_LIB_DIR'] = str(args.native_lib_dir.resolve())
        run('native', native_command, native_environment)
    print('Model integration checks completed. Native inference: ' +
          ('passed on this Windows host.' if args.native else 'not requested.'), flush=True)


if __name__ == '__main__':
    main()
