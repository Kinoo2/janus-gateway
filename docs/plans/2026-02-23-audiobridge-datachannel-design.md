# AudioBridge Data Channel Relay — Design

**Date:** 2026-02-23
**Status:** Approved

## Summary

Add binary data channel broadcast support to the AudioBridge plugin. When a participant sends a binary data channel message, it is relayed to all other participants in the same room. No sender attribution is included in the relayed message.

## Requirements

- Binary data only
- Broadcast to all room participants except the sender
- No sender identity exposed to receivers
- No new threads, structs, or files

## Approach

Synchronous broadcast while holding the room lock (Option A). The `gateway->relay_data()` call only enqueues data on each ICE handle's outgoing queue — it does not block on network I/O — so holding the room mutex during iteration is acceptable.

## Components

All changes are confined to `src/plugins/janus_audiobridge.c`:

1. **Forward declaration** — add `janus_audiobridge_incoming_data` alongside existing `incoming_rtp`/`incoming_rtcp` declarations.

2. **Plugin struct registration** — add `.incoming_data = janus_audiobridge_incoming_data` next to the existing `.incoming_rtp` and `.incoming_rtcp` entries.

3. **Implementation** — new function `janus_audiobridge_incoming_data()` placed near the other `incoming_*` implementations.

## Data Flow

```
ICE layer
  → janus_ice_incoming_data()          [src/ice.c]
  → janus_audiobridge_incoming_data()  [src/plugins/janus_audiobridge.c]
  → lock room->mutex
  → iterate room->participants
  → gateway->relay_data() per recipient
  → unlock room->mutex
  → ICE outgoing queue per recipient
```

## Implementation Detail

```c
void janus_audiobridge_incoming_data(janus_plugin_session *handle, janus_plugin_data *packet) {
    if(handle == NULL || packet == NULL || packet->buffer == NULL)
        return;

    janus_audiobridge_session *session = (janus_audiobridge_session *)handle->plugin_handle;
    if(!session || g_atomic_int_get(&session->destroyed) || !session->participant)
        return;

    janus_audiobridge_participant *participant = session->participant;
    janus_audiobridge_room *audiobridge = participant->room;
    if(!audiobridge)
        return;

    janus_mutex_lock(&audiobridge->mutex);
    GHashTableIter iter;
    gpointer value;
    g_hash_table_iter_init(&iter, audiobridge->participants);
    while(g_hash_table_iter_next(&iter, NULL, &value)) {
        janus_audiobridge_participant *p = (janus_audiobridge_participant *)value;
        if(p == participant || !p->session || g_atomic_int_get(&p->session->destroyed))
            continue;
        janus_plugin_data data = {
            .label = NULL,
            .protocol = NULL,
            .binary = TRUE,
            .buffer = packet->buffer,
            .length = packet->length
        };
        gateway->relay_data(p->session->handle, &data);
    }
    janus_mutex_unlock(&audiobridge->mutex);
}
```

## Edge Cases

| Condition | Handling |
|---|---|
| NULL handle or packet | Early return before any room access |
| Session destroyed | Skip via `g_atomic_int_get(&session->destroyed)` |
| Participant has no room | Early return before lock |
| Recipient session NULL | Skip in iteration |
| Recipient session destroyed | Skip via `g_atomic_int_get(&p->session->destroyed)` |
| Recipient has no data channel | `relay_data()` drops silently in core |

## Reference

- Plugin API: `src/plugins/plugin.h` — `janus_plugin_data` struct, `relay_data` callback
- Reference implementation: `src/plugins/janus_textroom.c` (broadcast pattern), `src/plugins/janus_videoroom.c` (full relay with helper threads)
- Core dispatch: `src/ice.c` — `janus_ice_incoming_data()`
