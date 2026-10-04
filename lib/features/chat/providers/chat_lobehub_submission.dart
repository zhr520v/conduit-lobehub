part of 'chat_providers.dart';

Map<String, dynamic> _decodeMessagePayload(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
  } catch (_) {}
  return const <String, dynamic>{};
}

Map<String, dynamic> _asJsonMap(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return value.map((key, value) => MapEntry(key.toString(), value));
  }
  return const <String, dynamic>{};
}

/// Resolves the configured Agent ID bound to the conversation, if any.
///
/// In LobeHub REST v2.2.17, an Agent conversation binds to `metadata.agentId`.
/// The agent ID must never be derived from `selectedModel.id`.
String? resolveLobeAgentId(Conversation? conversation) {
  if (conversation == null) return null;
  final meta = conversation.metadata;
  final agentId = meta['agentId']?.toString() ?? meta['agent_id']?.toString();
  if (agentId != null && agentId.isNotEmpty) {
    return agentId;
  }
  return null;
}

/// Resolves the raw provider name from a model instance or map.
String? resolveModelProvider(dynamic model) {
  if (model == null) return null;
  try {
    final dynamic prov = (model as dynamic).provider;
    if (prov != null && prov.toString().isNotEmpty) {
      return prov.toString();
    }
  } catch (_) {}
  if (model is Model) {
    final meta = model.metadata;
    final p = meta?['provider'] ??
        meta?['providerId'] ??
        meta?['owned_by'] ??
        (meta?['meta'] is Map ? (meta?['meta'] as Map)['provider'] : null);
    if (p != null && p.toString().isNotEmpty) {
      return p.toString();
    }
  } else if (model is Map) {
    final p = model['provider'] ??
        model['providerId'] ??
        model['owned_by'] ??
        (model['metadata'] is Map
            ? (model['metadata'] as Map)['provider']
            : null);
    if (p != null && p.toString().isNotEmpty) {
      return p.toString();
    }
  }
  return null;
}

/// Ensures the model item retains the exact provider metadata for both Agent
/// turns and ordinary model routes in LobeHub.
Map<String, dynamic> ensureModelItemProvider({
  required Map<String, dynamic> modelItem,
  required dynamic selectedModel,
}) {
  final provider = resolveModelProvider(selectedModel);
  if (provider == null || provider.isEmpty) {
    return modelItem;
  }
  final existingMeta = modelItem['metadata'] is Map
      ? Map<String, dynamic>.from(modelItem['metadata'] as Map)
      : <String, dynamic>{};
  return <String, dynamic>{
    ...modelItem,
    'provider': provider,
    'metadata': <String, dynamic>{
      ...existingMeta,
      'provider': provider,
    },
  };
}

/// Stores the durable [LobeAgentCorrelation] barrier and marks
/// `completionSubmitted = true` in the Drift database placeholder row
/// preserving all existing row fields.
Future<void> storeLobeAgentCorrelationBarrier({
  required AppDatabase db,
  required String chatId,
  required String assistantMessageId,
  required LobeAgentCorrelation correlation,
}) async {
  final existing = await db.messagesDao.getMessage(chatId, assistantMessageId);

  final Map<String, dynamic> existingPayload = existing != null
      ? _decodeMessagePayload(existing.payload)
      : <String, dynamic>{};
  final Map<String, dynamic> existingMeta =
      _asJsonMap(existingPayload['metadata']);

  final updatedMeta = <String, dynamic>{
    ...existingMeta,
    'lobeAgentCorrelation': correlation.toJson(),
    'completionSubmitted': true,
  }..remove('responseDone');

  final updatedPayload = <String, dynamic>{
    ...existingPayload,
    'id': assistantMessageId,
    'role': 'assistant',
    'isStreaming': true,
    'metadata': updatedMeta,
  }..remove('error')
   ..remove('done');

  final updatedRow = MessageRowData(
    id: assistantMessageId,
    chatId: chatId,
    parentId: existing?.parentId ?? correlation.userLocalId,
    role: 'assistant',
    content: existing?.content ?? '',
    model: existing?.model ?? correlation.agentId,
    createdAt: existing?.createdAt ??
        (correlation.createdAt.millisecondsSinceEpoch ~/ 1000),
    orderIndex: existing?.orderIndex ?? 0,
    payload: updatedPayload,
  );

  await db.messagesDao.upsertLocalEcho(updatedRow);
}

/// Builds the pre-dispatch callback for LobeHub Agent turns.
///
/// This callback executes AFTER preflight checks and snapshot collection,
/// but BEFORE the POST request to `/api/v1/responses` is dispatched.
/// It verifies auth/account/epoch ownership before persisting the barrier.
Future<void> Function(LobeAgentCorrelation correlation)
    buildLobeHubAgentPreDispatchCallback(
  dynamic ref, {
  required OpenWebUiCompletionOwner owner,
  required String assistantMessageId,
}) {
  return (LobeAgentCorrelation correlation) async {
    // Fence auth/account/epoch and abort on ownership change
    if (!openWebUiCompletionContextIsCurrent(ref, owner)) {
      throw StateError(
        'LobeHub submission barrier aborted: completion owner context is no longer current.',
      );
    }
    final db = owner.database;
    if (db == null) {
      throw StateError(
        'LobeHub submission barrier aborted: database is null.',
      );
    }

    await storeLobeAgentCorrelationBarrier(
      db: db,
      chatId: owner.chatId,
      assistantMessageId: assistantMessageId,
      correlation: correlation,
    );
  };
}
