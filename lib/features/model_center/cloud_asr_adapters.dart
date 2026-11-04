import 'dart:io';
import 'package:dio/dio.dart';
import 'cloud_asr_types.dart';
import 'cloud_asr_parser.dart';
import 'cloud_asr_transport.dart';

typedef SaveCloudAsrState = Future<void> Function();

class _RemoteAsrTaskInvalid extends CloudAsrException {
  const _RemoteAsrTaskInvalid() : super('远端任务或音频已失败或失效，点重试将重新提交此片段');
}

abstract class CloudAsrAdapter {
  CloudAsrAdapter(this.connection, {Dio? dio})
    : transport = CloudAsrTransport(connection, dio: dio);
  final CloudAsrConnection connection;
  final CloudAsrTransport transport;
  static CloudAsrAdapter create(
    CloudAsrConnection connection, {
    Dio? dio,
  }) => switch (connection.provider) {
    CloudAsrProvider.elevenlabs => ElevenLabsAsrAdapter(connection, dio: dio),
    CloudAsrProvider.soniox => SonioxAsrAdapter(connection, dio: dio),
    CloudAsrProvider.assemblyai => AssemblyAiAsrAdapter(connection, dio: dio),
    CloudAsrProvider.deepgram => DeepgramAsrAdapter(connection, dio: dio),
    CloudAsrProvider.gemini => GeminiAsrAdapter(connection, dio: dio),
  };
  bool needsAudio(Map<String, dynamic> state) =>
      state['response'] == null &&
      state['taskId'] == null &&
      state['fileId'] == null &&
      state['uploadUrl'] == null &&
      state['fileUri'] == null &&
      state['submitting'] != true;

  Future<CloudAsrResult> transcribe({
    required String? filePath,
    required Duration duration,
    required Map<String, dynamic> state,
    required SaveCloudAsrState save,
    required CancelToken token,
    required CloudAsrProgress progress,
  }) async {
    connection.options.validate(connection.provider, connection.capabilities);
    if (connection.language != 'auto' &&
        connection.capabilities.languages.isNotEmpty &&
        !connection.capabilities.languages.contains(connection.language)) {
      throw const CloudAsrException('所选模型不支持当前识别语言，请重新选择语言');
    }
    if (connection.apiKey.trim().isEmpty) {
      throw const CloudAsrException('请填写此服务的 API Key');
    }
    if (state['response'] != null) return _parse(state['response']);
    if (state['submitting'] == true && state['taskId'] == null) {
      throw const CloudAsrException('上次提交结果未知，已停止重复提交；请在厂商控制台确认后重新创建任务，避免重复计费');
    }
    if (needsAudio(state)) {
      if (duration.inMicroseconds <
          connection.capabilities.minMilliseconds * 1000) {
        throw const CloudAsrException('音频短于此接口允许的最小时长');
      }
      if (filePath == null) throw const CloudAsrException('待上传音频尚未准备');
      final size = await File(filePath).length();
      if (size <= 0) throw const CloudAsrException('音频文件为空');
      if (size > connection.capabilities.maxBytes ||
          size > 20000000 ||
          duration.inMicroseconds >
              connection.capabilities.maxSeconds * 1000000) {
        throw const CloudAsrException('音频超过当前模型的上传限制', tooLarge: true);
      }
      audioMime(filePath);
    }
    for (var attempt = 0; ; attempt++) {
      await transport.budget.wait(token);
      final release = await transport.budget.segments.acquire(token);
      try {
        final data = await run(filePath, state, save, token, progress);
        state['response'] = data;
        state['submitting'] = false;
        await save(); // Preserve a received response even if a future schema needs an update.
        final result = _parse(data);
        state['actualModel'] = result.model;
        state['languages'] = result.languages;
        return result;
      } on CloudAsrException catch (error) {
        if (error is _RemoteAsrTaskInvalid) {
          // Invalidate only this slice; keep preparation/splitting decisions.
          for (final key in const [
            'taskId',
            'submittedAt',
            'submitting',
            'response',
            'cleaned',
            'fileId',
            'uploadUrl',
            'fileUri',
            'fileName',
            'fileReady',
            'mime',
          ]) {
            state.remove(key);
          }
          // A legacy backup must not resurrect the rejected remote reference.
          state['remoteReset'] = true;
          await save();
          rethrow;
        }
        if (error.statusCode != 429 ||
            state['submitting'] == true ||
            attempt >= 3) {
          rethrow;
        }
        // An explicit 429 rejects this operation. Rebuild the body only after
        // the account cooldown; never replay an uncertain paid submission.
        progress('waiting', '服务限流，已降为单段并按厂家要求等待', null);
      } finally {
        release();
      }
    }
  }

  CloudAsrResult _parse(dynamic data) => parseCloudAsrResult(
    connection.provider,
    data,
    requestedModel: connection.model,
  );

  Future<dynamic> run(
    String? filePath,
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
    CloudAsrProgress progress,
  );

  Future<Map<String, dynamic>> paid(
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    Future<dynamic> Function() action, {
    bool task = false,
  }) async {
    if (state['submitting'] == true) {
      throw const CloudAsrException('上次提交结果未知，不能自动重复计费请求');
    }
    state['submitting'] = true;
    await save();
    try {
      final data = cloudObject(await action());
      if (task) {
        final id = data['id'];
        if (id is! String || id.isEmpty) {
          throw const CloudAsrException('服务未返回任务 ID；请先核对厂商任务，避免重复计费');
        }
        state['taskId'] = id;
        state['submittedAt'] = DateTime.now().toUtc().toIso8601String();
      } else {
        state['response'] = data;
      }
      state['submitting'] = false;
      await save();
      return data;
    } on CloudAsrException catch (error) {
      if (error.statusCode != null &&
          error.statusCode! >= 400 &&
          error.statusCode! < 500 &&
          error.statusCode != 408) {
        state['submitting'] =
            false; // Explicit rejection, not an uncertain write.
        await save();
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> poll(
    String path,
    Map<String, dynamic> state,
    CancelToken token,
    CloudAsrProgress progress, {
    bool interaction = false,
  }) async {
    final started =
        DateTime.tryParse(state['submittedAt']?.toString() ?? '') ??
        DateTime.now();
    final waiting = Stopwatch()..start();
    var count = 0;
    String? previous;
    while (true) {
      final response = await readRemote(path, token);
      final data = cloudObject(response.data);
      final original = data['status']?.toString();
      final status = interaction && original == 'in_progress'
          ? 'processing'
          : original;
      if (status == 'completed') return data;
      if (['error', 'failed', 'cancelled', 'incomplete'].contains(status)) {
        throw const _RemoteAsrTaskInvalid();
      }
      if (!['queued', 'processing'].contains(status)) {
        throw const CloudAsrException('服务返回了未适配的任务状态，原任务已保留');
      }
      if (waiting.elapsed > const Duration(hours: 3)) {
        throw const CloudAsrException('等待远端结果超时；继续时会查询原任务，不会重新提交');
      }
      if (status != previous) count = 0;
      previous = status;
      progress(
        'waiting',
        status == 'queued' ? '服务正在排队，任务已保存' : '服务正在识别，任务已保存',
        null,
      );
      await cloudDelay(
        cloudPollingDelay(
          status: status!,
          unchangedQueries: ++count,
          age: DateTime.now().difference(started),
          retryAfter: response.headers.value('retry-after'),
        ),
        token,
      );
    }
  }

  Future<Response<dynamic>> readRemote(String path, CancelToken token) async {
    try {
      return await transport.request('GET', path, token);
    } on CloudAsrException catch (error) {
      if (error.statusCode == 404 || error.statusCode == 410) {
        throw const _RemoteAsrTaskInvalid();
      }
      rethrow;
    }
  }

  /// Called only AFTER normalized cues have been persisted. Cleanup failure
  /// never changes successful recognition into a new billable submission.
  Future<void> cleanup(
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
  ) async {
    if (state['cleaned'] == true) return;
    try {
      await cleanRemote(state, token);
      state.remove('response');
      state['cleaned'] = true;
      state.remove('cleanupPending');
    } catch (_) {
      state['cleanupPending'] = true;
    }
    await save();
  }

  Future<void> cleanRemote(
    Map<String, dynamic> state,
    CancelToken token,
  ) async {}
  Future<void> delete(String path, CancelToken token) async {
    try {
      await transport.request('DELETE', path, token);
    } on CloudAsrException catch (e) {
      if (e.statusCode != 404) rethrow;
    }
  }

  String idPath(Object? value) {
    if (value is! String || !RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(value)) {
      throw const CloudAsrException('服务返回了无效的资源 ID');
    }
    return Uri.encodeComponent(value);
  }

  void close() => transport.close();
}

class ElevenLabsAsrAdapter extends CloudAsrAdapter {
  ElevenLabsAsrAdapter(super.connection, {super.dio});
  @override
  Future<void> cleanRemote(
    Map<String, dynamic> state,
    CancelToken token,
  ) async {
    final response = state['response'];
    final id = response is Map ? response['transcription_id'] : null;
    if (id != null) {
      await delete('/v1/speech-to-text/transcripts/${idPath(id)}', token);
    }
  }

  @override
  Future<dynamic> run(
    String? filePath,
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
    CloudAsrProgress progress,
  ) => paid(
    state,
    save,
    () async => (await transport.upload(
      '/v1/speech-to-text',
      filePath!,
      token,
      slow: true,
      progress: progress,
      fields: {
        'model_id': connection.model,
        'timestamps_granularity': connection.options.characterTiming
            ? 'character'
            : 'word',
        'tag_audio_events': 'false',
        'diarize': '${connection.options.diarize}',
        'use_multi_channel': 'false',
        if (connection.language != 'auto') 'language_code': connection.language,
        if (connection.options.hotwords.isNotEmpty)
          'keyterms': connection.options.hotwords,
      },
    )).data,
  );
}

class SonioxAsrAdapter extends CloudAsrAdapter {
  SonioxAsrAdapter(super.connection, {super.dio});
  @override
  Future<dynamic> run(
    String? filePath,
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
    CloudAsrProgress progress,
  ) async {
    if (state['taskId'] == null) {
      if (state['fileId'] == null) {
        final data = cloudObject(
          (await transport.upload(
            '/v1/files',
            filePath!,
            token,
            progress: progress,
          )).data,
        );
        state['fileId'] = data['id'];
        idPath(state['fileId']);
        await save();
      }
      await paid(
        state,
        save,
        () async => (await transport.request(
          'POST',
          '/v1/transcriptions',
          token,
          data: {
            'model': connection.model,
            'file_id': state['fileId'],
            'enable_language_identification': true,
            'enable_speaker_diarization': connection.options.diarize,
            if (connection.language != 'auto')
              'language_hints': [connection.language],
            if (connection.options.hotwords.isNotEmpty)
              'context': {'terms': connection.options.hotwords},
          },
        )).data,
        task: true,
      );
    }
    final path = '/v1/transcriptions/${idPath(state['taskId'])}';
    await poll(path, state, token, progress);
    return (await readRemote('$path/transcript', token)).data;
  }

  @override
  Future<void> cleanRemote(
    Map<String, dynamic> state,
    CancelToken token,
  ) async {
    if (state['taskId'] != null) {
      await delete('/v1/transcriptions/${idPath(state['taskId'])}', token);
    }
    if (state['fileId'] != null) {
      await delete('/v1/files/${idPath(state['fileId'])}', token);
    }
  }
}

class AssemblyAiAsrAdapter extends CloudAsrAdapter {
  AssemblyAiAsrAdapter(super.connection, {super.dio});
  @override
  Future<dynamic> run(
    String? filePath,
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
    CloudAsrProgress progress,
  ) async {
    if (state['taskId'] == null) {
      if (state['uploadUrl'] == null) {
        final data = cloudObject(
          (await transport.upload(
            '/v2/upload',
            filePath!,
            token,
            binary: true,
            headers: {'Content-Type': 'application/octet-stream'},
            progress: progress,
          )).data,
        );
        final url = Uri.tryParse(data['upload_url']?.toString() ?? '');
        if (url == null || url.scheme != 'https' || !url.hasAuthority) {
          throw const CloudAsrException('服务没有返回有效的上传文件引用');
        }
        state['uploadUrl'] = url.toString();
        await save();
      }
      await paid(
        state,
        save,
        () async => (await transport.request(
          'POST',
          '/v2/transcript',
          token,
          data: {
            'audio_url': state['uploadUrl'],
            'speech_models': [connection.model],
            if (connection.language == 'auto')
              'language_detection': true
            else
              'language_code': connection.language,
            'speaker_labels': connection.options.diarize,
            'punctuate': true,
            'format_text': true,
            'filter_profanity': false,
            if (connection.options.hotwords.isNotEmpty)
              'keyterms_prompt': connection.options.hotwords,
          },
        )).data,
        task: true,
      );
    }
    return poll(
      '/v2/transcript/${idPath(state['taskId'])}',
      state,
      token,
      progress,
    );
  }

  @override
  Future<void> cleanRemote(
    Map<String, dynamic> state,
    CancelToken token,
  ) async {
    if (state['taskId'] != null) {
      await delete('/v2/transcript/${idPath(state['taskId'])}', token);
    }
  }
}

class DeepgramAsrAdapter extends CloudAsrAdapter {
  DeepgramAsrAdapter(super.connection, {super.dio});
  @override
  Future<dynamic> run(
    String? filePath,
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
    CloudAsrProgress progress,
  ) => paid(
    state,
    save,
    () async => (await transport.upload(
      '/v1/listen',
      filePath!,
      token,
      binary: true,
      slow: true,
      progress: progress,
      query: {
        'model': connection.model,
        if (connection.language != 'auto')
          'language': connection.language
        else if (connection.capabilities.automaticLanguage)
          'language': 'multi'
        else if (connection.capabilities.languages.length == 1)
          'language': connection.capabilities.languages.single,
        'smart_format': false,
        'punctuate': true,
        'diarize': connection.options.diarize,
        if (connection.options.hotwords.isNotEmpty)
          'keyterm': connection.options.hotwords,
      },
    )).data,
  );
}

class GeminiAsrAdapter extends CloudAsrAdapter {
  GeminiAsrAdapter(super.connection, {super.dio});
  String interactionPath(Object? id) =>
      '/v1beta/interactions/${idPath(id is String ? id.replaceFirst(RegExp(r'^interactions/'), '') : id)}';
  @override
  Future<dynamic> run(
    String? filePath,
    Map<String, dynamic> state,
    SaveCloudAsrState save,
    CancelToken token,
    CloudAsrProgress progress,
  ) async {
    if (state['taskId'] != null) {
      return poll(
        interactionPath(state['taskId']),
        state,
        token,
        progress,
        interaction: true,
      );
    }
    if (state['fileUri'] == null) {
      final file = File(filePath!);
      final mime = audioMime(filePath);
      final started = await transport.request(
        'POST',
        '/upload/v1beta/files',
        token,
        headers: {
          'X-Goog-Upload-Protocol': 'resumable',
          'X-Goog-Upload-Command': 'start',
          'X-Goog-Upload-Header-Content-Length': '${await file.length()}',
          'X-Goog-Upload-Header-Content-Type': mime,
        },
        data: {
          'file': {'display_name': 'Fluent audio segment'},
        },
      );
      final upload = started.headers.value('x-goog-upload-url');
      if (upload == null) throw const CloudAsrException('Google 未返回音频上传会话');
      final uploaded = cloudObject(
        (await transport.upload(
          upload,
          filePath,
          token,
          binary: true,
          absolute: true,
          progress: progress,
          headers: {
            'X-Goog-Upload-Offset': '0',
            'X-Goog-Upload-Command': 'upload, finalize',
          },
        )).data,
      );
      var info = cloudObject(uploaded['file']);
      final name = info['name'];
      if (name is! String ||
          !RegExp(r'^files/[A-Za-z0-9_.-]+$').hasMatch(name)) {
        throw const CloudAsrException('Google 文件引用无效');
      }
      state['fileName'] = name;
      state['fileUri'] = info['uri'];
      state['mime'] = mime;
      await save();
      for (var i = 0; info['state'] == 'PROCESSING'; i++) {
        if (i >= 180) throw const CloudAsrException('Google 文件准备尚未完成，可稍后继续');
        await cloudDelay(Duration(seconds: (i + 1).clamp(1, 3)), token);
        info = cloudObject((await readRemote('/v1beta/$name', token)).data);
      }
      if (info['state'] == 'FAILED') {
        throw const _RemoteAsrTaskInvalid();
      }
      if (info['state'] != 'ACTIVE' ||
          info['uri'] is! String ||
          (info['uri'] as String).isEmpty) {
        throw const CloudAsrException('Google 未返回就绪的文件引用，可稍后继续查询原文件');
      }
      state['fileUri'] = info['uri'];
      state['fileReady'] = true;
      await save();
    } else if (state['fileReady'] != true) {
      final name = state['fileName'];
      if (name is! String ||
          !RegExp(r'^files/[A-Za-z0-9_.-]+$').hasMatch(name)) {
        throw const CloudAsrException('Google 文件引用无效');
      }
      final info = cloudObject((await readRemote('/v1beta/$name', token)).data);
      if (info['state'] == 'FAILED') {
        throw const _RemoteAsrTaskInvalid();
      }
      if (info['state'] != 'ACTIVE') {
        throw const CloudAsrException('Google 文件尚未就绪，请稍后继续');
      }
      state['fileReady'] = true;
      await save();
    }
    final data = await paid(
      state,
      save,
      () async => (await transport.request(
        'POST',
        '/v1beta/interactions',
        token,
        slow: true,
        data: {
          'model': connection.model,
          'input': [
            {
              'type': 'audio',
              'uri': state['fileUri'],
              'mime_type': state['mime'],
            },
          ],
          'generation_config': {
            'transcription_config': {
              if (connection.language != 'auto')
                'language_codes': [connection.language],
              'mode': {
                'type': 'verbatim',
                'timestamp_granularities': ['word'],
                if (connection.options.diarize) 'diarization_mode': 'speaker',
              },
            },
          },
        },
      )).data,
      task: true,
    );
    if (data['status'] == 'completed') return data;
    return poll(
      interactionPath(state['taskId']),
      state,
      token,
      progress,
      interaction: true,
    );
  }

  @override
  Future<void> cleanRemote(
    Map<String, dynamic> state,
    CancelToken token,
  ) async {
    if (state['taskId'] != null) {
      await delete(interactionPath(state['taskId']), token);
    }
    final name = state['fileName'];
    if (name is String && RegExp(r'^files/[A-Za-z0-9_.-]+$').hasMatch(name)) {
      await delete('/v1beta/$name', token);
    }
  }
}
