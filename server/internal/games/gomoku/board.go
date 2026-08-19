package gomoku

const (
	BoardSize  = 15
	boardCells = BoardSize * BoardSize
)

type Color uint8

const (
	Empty Color = iota
	Black
	White
)

type Point struct {
	X int
	Y int
}

type Stone struct {
	X     int
	Y     int
	Color Color
}

type board struct {
	cells [boardCells]uint8
	count int
}

func (b board) index(point Point) int {
	if !point.valid() {
		return -1
	}
	return point.Y*BoardSize + point.X
}

func (b board) occupied(point Point) bool {
	index := b.index(point)
	return index >= 0 && b.cells[index] != uint8(Empty)
}

func (b *board) place(point Point, color Color) bool {
	index := b.index(point)
	if index < 0 || b.cells[index] != uint8(Empty) || (color != Black && color != White) {
		return false
	}
	b.cells[index] = uint8(color)
	b.count++
	return true
}

func (b board) color(point Point) Color {
	index := b.index(point)
	if index < 0 {
		return Empty
	}
	return Color(b.cells[index])
}

func (point Point) valid() bool {
	return point.X >= 0 && point.X < BoardSize && point.Y >= 0 && point.Y < BoardSize
}

func (b board) wins(point Point, color Color) bool {
	for _, direction := range [...]Point{{X: 1}, {Y: 1}, {X: 1, Y: 1}, {X: 1, Y: -1}} {
		connected := 1 + b.run(point, direction, color) + b.run(point, Point{X: -direction.X, Y: -direction.Y}, color)
		if connected >= 5 {
			return true
		}
	}
	return false
}

func (b board) run(origin, direction Point, color Color) int {
	length := 0
	for point := (Point{X: origin.X + direction.X, Y: origin.Y + direction.Y}); point.valid() && b.color(point) == color; point = (Point{X: point.X + direction.X, Y: point.Y + direction.Y}) {
		length++
	}
	return length
}

// hasFive is used only when validating an opaque input snapshot at the trust
// boundary. A newly placed stone is evaluated by wins(lastPoint, color), so
// the move path never rescans the board to decide its result.
func (b board) hasFive(color Color) bool {
	for index, cell := range b.cells {
		if Color(cell) != color {
			continue
		}
		if b.wins(Point{X: index % BoardSize, Y: index / BoardSize}, color) {
			return true
		}
	}
	return false
}
