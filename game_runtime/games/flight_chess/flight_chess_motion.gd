extends RefCounted

const Board = preload("res://games/flight_chess/flight_chess_board.gd")

static func progress(color: String, piece: Dictionary) -> int:
	match piece.zone:
		"hangar": return -1
		"launch": return 0
		"main": return posmod(int(piece.index)-int(Board.PATH_STARTS[color]),52)+1
		"home": return 51+int(piece.index)
	return 57

static func point(color: String, value: int, index: int) -> Vector2:
	if value == -1:
		return Board.HANGAR_SLOTS[color][index]
	if value == 0:
		return Board.LAUNCH_POINTS[color]
	if value <= 50:
		return Board.MAIN_PATH[(Board.PATH_STARTS[color]+value-1)%52]
	if value <= 56:
		return Board.HOME_STRETCHES[color][value-51]
	return Board.FINISH_POINTS[color]

static func segments(color: String, index: int, from: Dictionary, roll: int, effect: String) -> Array:
	var start := progress(color,from)
	var result: Array = []
	var previous := point(color,start,index)
	if start == -1:
		return [{"from":previous,"to":point(color,0,index),"duration":0.42,"lift":25.0}]
	for step in range(1,roll+1):
		var value := start+step
		if value > 57:
			value = 114-value
		var target := point(color,value,index)
		result.append({"from":previous,"to":target,"duration":0.14,"lift":5.0})
		previous = target
	var landing := start+roll
	if effect in ["jump","jump_shortcut"]:
		landing += 4
		var target := point(color,landing,index)
		result.append({"from":previous,"to":target,"duration":0.32,"lift":25.0})
		previous = target
	if effect in ["shortcut","jump_shortcut"]:
		var corners: Array = Board.SHORTCUT_LINES[color]
		for target in [corners[0],corners[1],point(color,30,index)]:
			result.append({"from":previous,"to":target,"duration":0.64/3.0,"lift":0.0})
			previous = target
	return result
