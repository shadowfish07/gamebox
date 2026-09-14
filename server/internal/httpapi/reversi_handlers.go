package httpapi

import "net/http"

func (router *router) reversiStatus(w http.ResponseWriter, r *http.Request) {
	router.gameStatus(w, r, "reversi", "reversi_status")
}
func (router *router) reversiOpponents(w http.ResponseWriter, r *http.Request) {
	router.gameOpponents(w, r, "reversi")
}
func (router *router) createReversiMatch(w http.ResponseWriter, r *http.Request) {
	router.createUnconfiguredMatch(w, r, "reversi")
}
func (router *router) reversiHistory(writer http.ResponseWriter, request *http.Request) {
	router.gameHistory(writer, request, "reversi")
}
