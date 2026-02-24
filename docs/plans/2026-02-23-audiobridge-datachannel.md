# AudioBridge Data Channel Relay Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `incoming_data` callback to the AudioBridge plugin that broadcasts binary data channel messages to all other participants in the same room.

**Architecture:** Three small edits to `src/plugins/janus_audiobridge.c`: a forward declaration, a plugin struct registration, and the callback implementation. The implementation locks the room mutex, iterates `room->participants`, and calls `gateway->relay_data()` for every participant except the sender.

**Tech Stack:** C, Janus plugin API (`janus_plugin_data`, `gateway->relay_data()`), GLib (`GHashTable`, `janus_mutex`)

---

### Task 1: Add the forward declaration

**Files:**
- Modify: `src/plugins/janus_audiobridge.c:1273`

**Step 1: Add the forward declaration after line 1273**

In `src/plugins/janus_audiobridge.c`, the forward declarations for the incoming callbacks are at lines 1272–1273:

```c
void janus_audiobridge_incoming_rtp(janus_plugin_session *handle, janus_plugin_rtp *packet);
void janus_audiobridge_incoming_rtcp(janus_plugin_session *handle, janus_plugin_rtcp *packet);
```

Add this line immediately after line 1273:

```c
void janus_audiobridge_incoming_data(janus_plugin_session *handle, janus_plugin_data *packet);
```

**Step 2: Verify it compiles**

```bash
make 2>&1 | grep -E "error:|warning:.*incoming_data"
```

Expected: no errors mentioning `incoming_data`.

---

### Task 2: Register the callback in the plugin struct

**Files:**
- Modify: `src/plugins/janus_audiobridge.c:1297`

**Step 1: Add the registration after line 1297**

The plugin struct entries for the incoming callbacks are at lines 1296–1297:

```c
		.incoming_rtp = janus_audiobridge_incoming_rtp,
		.incoming_rtcp = janus_audiobridge_incoming_rtcp,
```

Add this line immediately after line 1297:

```c
		.incoming_data = janus_audiobridge_incoming_data,
```

**Step 2: Verify it compiles**

```bash
make 2>&1 | grep "error:"
```

Expected: no errors. (There will be a linker or compiler error about `janus_audiobridge_incoming_data` being declared but not defined — that is expected and will be resolved in Task 3.)

---

### Task 3: Implement the callback

**Files:**
- Modify: `src/plugins/janus_audiobridge.c:6383` (after the closing `}` of `janus_audiobridge_incoming_rtcp`)

**Step 1: Add the implementation after line 6383**

Insert the following function immediately after the closing brace of `janus_audiobridge_incoming_rtcp` (currently line 6383):

```c
void janus_audiobridge_incoming_data(janus_plugin_session *handle, janus_plugin_data *packet) {
	if(handle == NULL || packet == NULL || packet->buffer == NULL || packet->length == 0)
		return;
	if(g_atomic_int_get(&handle->stopped) || g_atomic_int_get(&stopping) || !g_atomic_int_get(&initialized))
		return;
	janus_audiobridge_session *session = (janus_audiobridge_session *)handle->plugin_handle;
	if(!session || g_atomic_int_get(&session->destroyed) || !session->participant)
		return;
	janus_audiobridge_participant *participant = (janus_audiobridge_participant *)session->participant;
	janus_audiobridge_room *audiobridge = participant->room;
	if(!audiobridge)
		return;
	/* Broadcast to all other participants in the room */
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

**Step 2: Build**

```bash
make 2>&1 | tail -20
```

Expected: build succeeds with no errors. Warnings about unrelated missing search paths (`/usr/local/opt/openssl/lib`, etc.) are harmless and pre-existing.

**Step 3: Commit**

```bash
git add src/plugins/janus_audiobridge.c
git commit -m "Add data channel broadcast support to AudioBridge plugin

Implements incoming_data callback to relay binary data channel
messages to all other participants in the same room.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>"
```

---

### Task 4: Manual integration test

There is no unit test framework for Janus plugins. Verify the feature manually:

**Step 1: Install**

```bash
sudo make install
```

**Step 2: Run Janus**

```bash
/usr/local/janus/bin/janus --configs-folder /usr/local/janus/etc/janus
```

**Step 3: Open two browser tabs to the AudioBridge demo**

Navigate to the Janus demos page (typically `http://localhost/janus/demos/audiobridgetest.html`) and join the same room from two tabs.

**Step 4: Send a binary data channel message from one tab**

In the browser console of the first tab:

```javascript
// Assuming `janus` is the Janus handle and `audiobridgetest` is the plugin handle
audiobridgetest.data({
  text: null,
  data: new Uint8Array([0x01, 0x02, 0x03]).buffer,
  success: function() { console.log("sent"); },
  error: function(err) { console.error(err); }
});
```

**Step 5: Confirm receipt in the second tab**

Add a `ondata` handler before joining in the second tab:

```javascript
audiobridgetest.ondata = function(data) {
  console.log("Received data channel message:", new Uint8Array(data));
};
```

Expected: the second tab's console logs `Received data channel message: Uint8Array [1, 2, 3]`.

**Step 6: Confirm the sender does NOT receive its own message**

The first tab's `ondata` handler should not fire.
