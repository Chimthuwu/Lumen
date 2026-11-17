extends RefCounted
class_name WorldSave

# Chunk-keyed sparse save format (v3). Terrain is a deterministic function of
# the seed, so the save only journals the cells the player actually edited,
# captured live from the world's block_edited signal. Each chunk section lists
# (local x, y, z, block id) records of 3+1+2 bytes. On load the sparse records
# are re-expanded into the dense per-chunk override arrays the world engine
# consumes, by regenerating the base chunk and applying the edits.
#
# Old formats are rejected outright: prototype policy is "world format changed
# — starting fresh", no conversion scripts.

const SAVE_VERSION := 3
const BLOCK_DEFS_VERSION := 2
const EDITS_FILE := "edits.bin"
const METADATA_FILE := "metadata.json"
const FORMAT_CHANGED_MESSAGE := "World format changed — starting fresh"


static func save_world(world: Node, journal: BlockEditJournal, player_position: Vector3, extra_metadata: Dictionary = {}) -> bool:
	var save_dir := "user://worlds/%d" % world.world_seed
	var dir_error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(save_dir))
	if dir_error != OK:
		push_error("SAVE: could not create %s (%s)" % [save_dir, error_string(dir_error)])
		return false
	var by_chunk: Dictionary = {}
	var chunk_size: float = float(world.CHUNK_SIZE)
	for cell_variant in journal.edits.keys():
		var cell: Vector3i = cell_variant
		var coords := Vector3i(floori(float(cell.x) / chunk_size), floori(float(cell.y) / chunk_size), floori(float(cell.z) / chunk_size))
		if not by_chunk.has(coords):
			by_chunk[coords] = {}
		(by_chunk[coords] as Dictionary)[cell - coords * world.CHUNK_SIZE] = int(journal.edits[cell])
	var buffer := StreamPeerBuffer.new()
	buffer.put_32(by_chunk.size())
	for coords: Vector3i in by_chunk.keys():
		var entries: Dictionary = by_chunk[coords]
		buffer.put_32(coords.x)
		buffer.put_32(coords.y)
		buffer.put_32(coords.z)
		buffer.put_32(entries.size())
		for local: Vector3i in entries.keys():
			buffer.put_u8(local.x)
			buffer.put_u8(local.y)
			buffer.put_u8(local.z)
			buffer.put_u16(int(entries[local]))
	var edits_file := FileAccess.open_compressed(save_dir.path_join(EDITS_FILE), FileAccess.WRITE, FileAccess.COMPRESSION_DEFLATE)
	if edits_file == null:
		push_error("SAVE: could not open edits file (%s)" % error_string(FileAccess.get_open_error()))
		return false
	edits_file.store_buffer(buffer.data_array)
	edits_file.close()
	var metadata := {
		"save_version": SAVE_VERSION,
		"seed": world.world_seed,
		"block_defs_version": BLOCK_DEFS_VERSION,
		"edited_cells": journal.edits.size(),
		"edited_chunks": by_chunk.size(),
		"player_position": [player_position.x, player_position.y, player_position.z],
		"cradle_state": {},
		"inventory": {},
		"player_stats": {},
		"m4": extra_metadata
	}
	var metadata_file := FileAccess.open(save_dir.path_join(METADATA_FILE), FileAccess.WRITE)
	if metadata_file == null:
		push_error("SAVE: could not open metadata file (%s)" % error_string(FileAccess.get_open_error()))
		return false
	metadata_file.store_string(JSON.stringify(metadata))
	metadata_file.close()
	print("SAVE PASS: %s (%d cells in %d chunks)" % [save_dir, journal.edits.size(), by_chunk.size()])
	return true


static func load_world(seed: int, world: Node) -> Dictionary:
	var save_dir := "user://worlds/%d" % seed
	var metadata_path := save_dir.path_join(METADATA_FILE)
	var metadata_file := FileAccess.open(metadata_path, FileAccess.READ)
	if metadata_file == null:
		push_error("LOAD: missing metadata at %s" % metadata_path)
		return {}
	var parser := JSON.new()
	var parse_error := parser.parse(metadata_file.get_as_text())
	metadata_file.close()
	if parse_error != OK or not parser.data is Dictionary:
		push_error("LOAD: invalid metadata JSON")
		return {}
	var metadata: Dictionary = parser.data
	if int(metadata.get("save_version", -1)) != SAVE_VERSION:
		push_error("LOAD: %s (found save v%s, this build writes v%d)" % [FORMAT_CHANGED_MESSAGE, str(metadata.get("save_version")), SAVE_VERSION])
		return {}
	if int(metadata.get("block_defs_version", -1)) != BLOCK_DEFS_VERSION:
		push_error("LOAD: %s (block definitions changed)" % FORMAT_CHANGED_MESSAGE)
		return {}
	if int(metadata.get("seed", -1)) != seed:
		push_error("LOAD: seed mismatch")
		return {}
	var edits_file := FileAccess.open_compressed(save_dir.path_join(EDITS_FILE), FileAccess.READ, FileAccess.COMPRESSION_DEFLATE)
	if edits_file == null:
		push_error("LOAD: missing edits file")
		return {}
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = edits_file.get_buffer(edits_file.get_length())
	edits_file.close()
	if buffer.get_size() < 4:
		push_error("LOAD: truncated edits file")
		return {}
	var sparse: Dictionary = {}
	var chunk_size: int = world.CHUNK_SIZE
	var chunk_count := _to_signed(buffer.get_32())
	for index in range(chunk_count):
		if buffer.get_available_bytes() < 16:
			push_error("LOAD: truncated chunk header %d of %d" % [index, chunk_count])
			return {}
		var coords := Vector3i(_to_signed(buffer.get_32()), _to_signed(buffer.get_32()), _to_signed(buffer.get_32()))
		var entry_count := _to_signed(buffer.get_32())
		if entry_count < 0 or buffer.get_available_bytes() < entry_count * 5:
			push_error("LOAD: truncated chunk records for %s" % str(coords))
			return {}
		for entry in range(entry_count):
			var local := Vector3i(int(buffer.get_u8()), int(buffer.get_u8()), int(buffer.get_u8()))
			var block_id := int(buffer.get_u16())
			if local.x < 0 or local.x >= world.CHUNK_SIZE or local.y < 0 or local.y >= world.CHUNK_SIZE or local.z < 0 or local.z >= world.CHUNK_SIZE:
				push_error("LOAD: local coord %s outside chunk" % str(local))
				return {}
			var cell: Vector3i = coords * chunk_size + local
			if block_id < 0 or block_id >= world.block_defs.size():
				push_error("LOAD: block id %d outside the palette" % block_id)
				return {}
			sparse[cell] = block_id
	# Expand to the dense per-chunk overrides the world engine consumes: base
	# terrain comes from the deterministic generator, then journal cells win.
	var edited_cells: Dictionary = sparse.duplicate()
	# PackedByteArray values copy on read, so each mutated array is written
	# back into the dictionary.
	var dense: Dictionary = {}
	for cell: Vector3i in sparse.keys():
		var coords := Vector3i(floori(float(cell.x) / float(chunk_size)), floori(float(cell.y) / float(chunk_size)), floori(float(cell.z) / float(chunk_size)))
		if not dense.has(coords):
			dense[coords] = WorldGenerator.generate_chunk(coords, seed, world.block_ids)
		var blocks: PackedByteArray = dense[coords]
		var local: Vector3i = cell - coords * chunk_size
		blocks[local.x + local.y * chunk_size + local.z * chunk_size * chunk_size] = int(sparse[cell])
		dense[coords] = blocks
	print("LOAD PASS: %s (%d edited cells, %d override chunks)" % [save_dir, sparse.size(), dense.size()])
	return {"metadata": metadata, "edits": dense, "edited_cells": edited_cells}


static func _to_signed(value: int) -> int:
	return value - 0x100000000 if value >= 0x80000000 else value
