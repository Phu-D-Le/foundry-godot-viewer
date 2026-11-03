extends Node
## WebSocket server the Foundry module connects to. Emits each JSON message as a Dictionary.

signal message_received(msg: Dictionary)
signal clients_changed(count: int)

var port := 8765
var bind_address := "127.0.0.1"

## Which kind of client feeds the viewer: "play" (the player's own Foundry client inside the viewer, play mode),
## "gm" (a GM browser, dev mode), or "" for any. A client says which it is in its "hello".
var active_role := ""

var _server := TCPServer.new()
var _peers: Array[WebSocketPeer] = []
var _roles := {}  # WebSocketPeer -> "play" | "gm"
var _open_count := 0


func start() -> Error:
	var err := _server.listen(port, bind_address)
	if err != OK:
		push_error("Bridge: could not listen on %s:%d (%s)" % [bind_address, port, error_string(err)])
	else:
		print("Bridge: listening on ws://%s:%d" % [bind_address, port])
	return err


func _process(_delta: float) -> void:
	while _server.is_listening() and _server.is_connection_available():
		var ws := WebSocketPeer.new()
		# Scene snapshots with many walls can be large; the default 64 KiB buffer is too small.
		ws.inbound_buffer_size = 64 * 1024 * 1024
		ws.outbound_buffer_size = 64 * 1024 * 1024  # published levels (.glb) go back to Foundry
		ws.max_queued_packets = 4096
		ws.accept_stream(_server.take_connection())
		_peers.append(ws)

	var open := 0
	for ws in _peers.duplicate():
		ws.poll()
		match ws.get_ready_state():
			WebSocketPeer.STATE_OPEN:
				open += 1
				while ws.get_available_packet_count() > 0:
					_handle_packet(ws, ws.get_packet())
			WebSocketPeer.STATE_CLOSED:
				_peers.erase(ws)
				_roles.erase(ws)
	if open != _open_count:
		_open_count = open
		clients_changed.emit(open)


## Send a message to every connected Foundry client of the active kind. Returns false if none is connected.
func send(msg: Dictionary) -> bool:
	var sent := false
	for ws in _peers:
		if not _is_active(ws):
			continue
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN and ws.send_text(JSON.stringify(msg)) == OK:
			sent = true
	return sent


## Number of open clients of a kind ("play" / "gm").
func count(role: String) -> int:
	var n := 0
	for ws in _peers:
		if ws.get_ready_state() == WebSocketPeer.STATE_OPEN and _roles.get(ws, "gm") == role:
			n += 1
	return n


func _is_active(ws: WebSocketPeer) -> bool:
	return active_role == "" or _roles.get(ws, "gm") == active_role


func _handle_packet(ws: WebSocketPeer, packet: PackedByteArray) -> void:
	var msg = JSON.parse_string(packet.get_string_from_utf8())
	if not (msg is Dictionary and msg.has("type")):
		push_warning("Bridge: ignoring malformed message")
		return
	if msg.type == "hello":
		_roles[ws] = "play" if str(msg.get("client", "gm")) == "play" else "gm"
	if _is_active(ws):  # the other kind of client is ignored until the mode switches
		message_received.emit(msg)
