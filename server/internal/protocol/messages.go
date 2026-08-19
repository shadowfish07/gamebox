package protocol

const (
	TypePlatformConnect           = "platform.connect"
	TypePlatformConnected         = "platform.connected"
	TypePlatformPing              = "platform.ping"
	TypePlatformPong              = "platform.pong"
	TypePlatformSnapshot          = "platform.snapshot"
	TypePlatformSnapshotRequested = "platform.snapshot.requested"
	TypePlatformError             = "platform.error"
	TypePlatformMatchCancelled    = "platform.match.cancelled"
	TypePlatformMatchAbandoned    = "platform.match.abandoned"
	TypeGomokuMoveRequested       = "gomoku.move.requested"
	TypeGomokuMoveAccepted        = "gomoku.move.accepted"
	TypeGomokuResignRequested     = "gomoku.resign.requested"
	TypeGomokuResigned            = "gomoku.resigned"
)

var knownTypes = map[string]struct{}{
	TypePlatformConnect:           {},
	TypePlatformConnected:         {},
	TypePlatformPing:              {},
	TypePlatformPong:              {},
	TypePlatformSnapshot:          {},
	TypePlatformSnapshotRequested: {},
	TypePlatformError:             {},
	TypePlatformMatchCancelled:    {},
	TypePlatformMatchAbandoned:    {},
	TypeGomokuMoveRequested:       {},
	TypeGomokuMoveAccepted:        {},
	TypeGomokuResignRequested:     {},
	TypeGomokuResigned:            {},
}

func isClientAction(messageType string) bool {
	return messageType == TypeGomokuMoveRequested || messageType == TypeGomokuResignRequested
}

func isRevisionlessControl(messageType string) bool {
	switch messageType {
	case TypePlatformConnect, TypePlatformPong, TypePlatformSnapshotRequested:
		return true
	default:
		return false
	}
}
