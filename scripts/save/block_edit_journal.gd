extends RefCounted
class_name BlockEditJournal

# Signal-driven sparse journal of player block edits: cell -> last block id.
# The world emits block_edited() for every successful set_block(); this keeps
# the minimal change set so the save file stays kilobytes even on an infinite
# map. Last write wins, so re-editing a cell never duplicates storage.

var edits: Dictionary = {}


func on_block_edited(cell: Vector3i, block_id: int) -> void:
	edits[cell] = block_id


func seed_from_edits(edited_cells: Dictionary) -> void:
	edits = edited_cells.duplicate()


func clear() -> void:
	edits.clear()


func count() -> int:
	return edits.size()
