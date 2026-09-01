package chinesecheckers

const BoardCells = 121

type Color uint8

const (
	Empty Color = iota
	Black
	White
)

type point struct {
	X2 int
	Y  int
}

var (
	rowLengths                = [...]int{1, 2, 3, 4, 13, 12, 11, 10, 9, 10, 11, 12, 13, 4, 3, 2, 1}
	rowStarts                 = [...]int{12, 11, 10, 9, 0, 1, 2, 3, 4, 3, 2, 1, 0, 9, 10, 11, 12}
	boardPoints, pointIndices = buildGeometry()
)

func buildGeometry() ([BoardCells]point, map[point]int) {
	var points [BoardCells]point
	indices := make(map[point]int, BoardCells)
	index := 0
	for row, length := range rowLengths {
		for column := 0; column < length; column++ {
			value := point{X2: rowStarts[row] + 2*column, Y: row}
			points[index] = value
			indices[value] = index
			index++
		}
	}
	if index != BoardCells {
		panic("chinesecheckers: invalid board geometry")
	}
	return points, indices
}

func campIndices(color Color) []int {
	if color == White {
		return []int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}
	}
	if color == Black {
		return []int{111, 112, 113, 114, 115, 116, 117, 118, 119, 120}
	}
	return nil
}

func isTargetCamp(index int, color Color) bool {
	if color == Black {
		return index >= 111 && index < BoardCells
	}
	if color == White {
		return index >= 0 && index <= 9
	}
	return false
}

func isNeutralCamp(index int) bool {
	if index < 0 || index >= BoardCells {
		return false
	}
	row := boardPoints[index].Y
	if row < 4 || row > 12 || row == 8 {
		return false
	}
	rowOffset := 0
	for current := 0; current < row; current++ {
		rowOffset += rowLengths[current]
	}
	column := index - rowOffset
	wingDepth := 0
	if row >= 4 && row <= 7 {
		wingDepth = 8 - row
	} else if row >= 9 && row <= 12 {
		wingDepth = row - 8
	}
	return wingDepth > 0 && (column < wingDepth || column >= rowLengths[row]-wingDepth)
}

func validMovePath(cells [BoardCells]uint8, color Color, path []int) bool {
	if (color != Black && color != White) || len(path) < 2 || len(path) > BoardCells {
		return false
	}
	seen := make(map[int]struct{}, len(path))
	for _, index := range path {
		if index < 0 || index >= BoardCells {
			return false
		}
		if _, exists := seen[index]; exists {
			return false
		}
		seen[index] = struct{}{}
	}
	source := path[0]
	destination := path[len(path)-1]
	if Color(cells[source]) != color || cells[destination] != uint8(Empty) || isNeutralCamp(destination) {
		return false
	}
	if isTargetCamp(source, color) && !isTargetCamp(destination, color) {
		return false
	}

	current := source
	cells[current] = uint8(Empty)
	for pathIndex := 1; pathIndex < len(path); pathIndex++ {
		next := path[pathIndex]
		if cells[next] != uint8(Empty) {
			return false
		}
		fromPoint := boardPoints[current]
		toPoint := boardPoints[next]
		deltaX2 := toPoint.X2 - fromPoint.X2
		deltaY := toPoint.Y - fromPoint.Y
		if adjacentDelta(deltaX2, deltaY) {
			if len(path) != 2 {
				return false
			}
		} else if jumpDelta(deltaX2, deltaY) {
			middle := point{X2: fromPoint.X2 + deltaX2/2, Y: fromPoint.Y + deltaY/2}
			middleIndex, exists := pointIndices[middle]
			if !exists || cells[middleIndex] == uint8(Empty) {
				return false
			}
		} else {
			return false
		}
		cells[current] = uint8(Empty)
		cells[next] = uint8(color)
		current = next
	}
	return true
}

func adjacentDelta(x2, y int) bool {
	return y == 0 && (x2 == -2 || x2 == 2) ||
		(y == -1 || y == 1) && (x2 == -1 || x2 == 1)
}

func jumpDelta(x2, y int) bool {
	return y == 0 && (x2 == -4 || x2 == 4) ||
		(y == -2 || y == 2) && (x2 == -2 || x2 == 2)
}

func hasCompletedCamp(cells [BoardCells]uint8, color Color) bool {
	for _, index := range campIndices(color) {
		if Color(cells[index]) != color {
			return false
		}
	}
	return color == Black || color == White
}

func initialBoard() [BoardCells]uint8 {
	var cells [BoardCells]uint8
	for index := 0; index <= 9; index++ {
		cells[index] = uint8(Black)
	}
	for index := 111; index < BoardCells; index++ {
		cells[index] = uint8(White)
	}
	return cells
}
