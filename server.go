package main

import (
	"embed"
	"encoding/json"
	"io/fs"
	"log"
	"net/http"
	"strconv"
	"strings"
)

//go:embed web
var webFS embed.FS

type Server struct {
	guard *Guard
	store *Store
	dir   string // ~/.orchard
}

func (s *Server) Routes() http.Handler {
	mux := http.NewServeMux()
	static, _ := fs.Sub(webFS, "web")
	mux.Handle("GET /", http.FileServerFS(static))

	mux.HandleFunc("GET /api/health", s.health)
	mux.HandleFunc("GET /api/chats", s.listChats)
	mux.HandleFunc("POST /api/chats", s.createChat)
	mux.HandleFunc("GET /api/chats/{id}", s.getChat)
	mux.HandleFunc("PATCH /api/chats/{id}", s.updateChat)
	mux.HandleFunc("DELETE /api/chats/{id}", s.deleteChat)
	mux.HandleFunc("POST /api/chats/{id}/messages", s.sendMessage)
	mux.HandleFunc("GET /api/tasks", s.listTasks)
	mux.HandleFunc("POST /api/tasks/{name}", s.runTask)
	return mux
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(v)
}

func writeErr(w http.ResponseWriter, code int, msg string) {
	writeJSON(w, code, map[string]string{"error": msg})
}

// sse writes named server-sent events to the browser.
type sse struct {
	w http.ResponseWriter
	f http.Flusher
}

func newSSE(w http.ResponseWriter) *sse {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	f, _ := w.(http.Flusher)
	return &sse{w, f}
}

func (e *sse) send(event string, v any) error {
	b, _ := json.Marshal(v)
	if _, err := e.w.Write([]byte("event: " + event + "\ndata: " + string(b) + "\n\n")); err != nil {
		return err
	}
	if e.f != nil {
		e.f.Flush()
	}
	return nil
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	b, err := s.guard.Health(r.Context())
	if err != nil {
		writeJSON(w, 503, map[string]any{"ok": false, "error": err.Error()})
		return
	}
	writeJSON(w, 200, map[string]any{"ok": true, "upstream": json.RawMessage(b)})
}

func chatID(r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	return id, err == nil
}

func (s *Server) listChats(w http.ResponseWriter, r *http.Request) {
	chats, err := s.store.ListChats()
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, chats)
}

func (s *Server) createChat(w http.ResponseWriter, r *http.Request) {
	var req struct {
		SystemPrompt string `json:"system_prompt"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	c, err := s.store.CreateChat(req.SystemPrompt)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 201, c)
}

func (s *Server) getChat(w http.ResponseWriter, r *http.Request) {
	id, ok := chatID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	c, err := s.store.GetChat(id)
	if err != nil {
		writeErr(w, 404, "chat not found")
		return
	}
	msgs, err := s.store.Messages(id)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, map[string]any{"chat": c, "messages": msgs, "budget": BudgetTokens, "tokens": chatTokens(c, msgs)})
}

func (s *Server) updateChat(w http.ResponseWriter, r *http.Request) {
	id, ok := chatID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	c, err := s.store.GetChat(id)
	if err != nil {
		writeErr(w, 404, "chat not found")
		return
	}
	var req struct {
		Title        *string `json:"title"`
		SystemPrompt *string `json:"system_prompt"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeErr(w, 400, err.Error())
		return
	}
	if req.Title != nil {
		c.Title = *req.Title
	}
	if req.SystemPrompt != nil {
		c.SystemPrompt = *req.SystemPrompt
	}
	if err := s.store.UpdateChat(c); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, c)
}

func (s *Server) deleteChat(w http.ResponseWriter, r *http.Request) {
	id, ok := chatID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	if err := s.store.DeleteChat(id); err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	w.WriteHeader(204)
}

func toHistory(msgs []StoredMessage) []Message {
	h := make([]Message, 0, len(msgs))
	for _, m := range msgs {
		h = append(h, Message{Role: m.Role, Content: m.Content})
	}
	return h
}

// chatTokens is what the next request would cost before the new message.
func chatTokens(c Chat, msgs []StoredMessage) int {
	sent, _ := FitHistory(c.SystemPrompt, toHistory(msgs), BudgetTokens)
	return MsgTokens(sent)
}

func titleFrom(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > 48 {
		s = string(r[:48]) + "…"
	}
	return s
}

func (s *Server) sendMessage(w http.ResponseWriter, r *http.Request) {
	id, ok := chatID(r)
	if !ok {
		writeErr(w, 400, "bad id")
		return
	}
	var req struct {
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Content) == "" {
		writeErr(w, 400, "content required")
		return
	}
	c, err := s.store.GetChat(id)
	if err != nil {
		writeErr(w, 404, "chat not found")
		return
	}
	prev, err := s.store.Messages(id)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	if len(prev) == 0 {
		c.Title = titleFrom(req.Content)
		s.store.UpdateChat(c)
	}
	if err := s.store.AddMessage(id, "user", req.Content); err != nil {
		writeErr(w, 500, err.Error())
		return
	}

	history := append(toHistory(prev), Message{Role: "user", Content: req.Content})
	msgs, dropped := FitHistory(c.SystemPrompt, history, BudgetTokens)

	ev := newSSE(w)
	truncated := msgs[len(msgs)-1].Content != req.Content
	ev.send("meta", map[string]any{"tokens": MsgTokens(msgs), "budget": BudgetTokens, "dropped": dropped, "truncated": truncated, "title": c.Title})

	var reply strings.Builder
	err = s.guard.Stream(r.Context(), msgs, func(d string) error {
		reply.WriteString(d)
		return ev.send("delta", map[string]string{"text": d})
	})
	if reply.Len() > 0 {
		if err := s.store.AddMessage(id, "assistant", reply.String()); err != nil {
			log.Printf("save reply: %v", err)
		}
	}
	if err != nil {
		ev.send("error", map[string]string{"error": err.Error()})
		return
	}
	ev.send("done", map[string]any{})
}

func (s *Server) listTasks(w http.ResponseWriter, r *http.Request) {
	tasks, err := LoadTasks(s.dir)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	writeJSON(w, 200, tasks)
}

func (s *Server) runTask(w http.ResponseWriter, r *http.Request) {
	tasks, err := LoadTasks(s.dir)
	if err != nil {
		writeErr(w, 500, err.Error())
		return
	}
	t, ok := FindTask(tasks, r.PathValue("name"))
	if !ok {
		writeErr(w, 404, "no such task")
		return
	}
	var req struct {
		Input  string `json:"input"`
		Option string `json:"option"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || strings.TrimSpace(req.Input) == "" {
		writeErr(w, 400, "input required")
		return
	}
	p := t.Prepare(req.Input, req.Option)

	ev := newSSE(w)
	ev.send("meta", map[string]any{"tokens": p.Tokens, "budget": BudgetTokens, "truncated": p.Truncated, "input_chars": p.InputLen, "sent_chars": p.SentLen})
	out, err := s.guard.RunTask(r.Context(), t, p,
		func(d string) error { return ev.send("delta", map[string]string{"text": d}) },
		func() error { return ev.send("retry", map[string]any{}) },
	)
	if err != nil {
		ev.send("error", map[string]string{"error": err.Error()})
		return
	}
	ev.send("done", map[string]string{"text": out})
}
