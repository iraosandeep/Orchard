package main

import (
	"database/sql"
	"strings"
	"time"

	_ "modernc.org/sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS chats (
	id INTEGER PRIMARY KEY,
	title TEXT NOT NULL DEFAULT '',
	system_prompt TEXT NOT NULL DEFAULT '',
	created_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS messages (
	id INTEGER PRIMARY KEY,
	chat_id INTEGER NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
	role TEXT NOT NULL,
	content TEXT NOT NULL,
	created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_chat ON messages(chat_id, id);
`

const DefaultSystemPrompt = "You are a helpful assistant. Be concise."

type Store struct{ db *sql.DB }

type Chat struct {
	ID           int64  `json:"id"`
	Title        string `json:"title"`
	SystemPrompt string `json:"system_prompt"`
	CreatedAt    string `json:"created_at"`
}

type StoredMessage struct {
	ID        int64  `json:"id"`
	Role      string `json:"role"`
	Content   string `json:"content"`
	CreatedAt string `json:"created_at"`
}

func OpenStore(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)&_pragma=journal_mode(WAL)&_pragma=busy_timeout(5000)")
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(schema); err != nil {
		return nil, err
	}
	return &Store{db}, nil
}

func now() string { return time.Now().UTC().Format(time.RFC3339) }

func (s *Store) ListChats() ([]Chat, error) {
	rows, err := s.db.Query(`SELECT id, title, system_prompt, created_at FROM chats ORDER BY id DESC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	chats := []Chat{}
	for rows.Next() {
		var c Chat
		if err := rows.Scan(&c.ID, &c.Title, &c.SystemPrompt, &c.CreatedAt); err != nil {
			return nil, err
		}
		chats = append(chats, c)
	}
	return chats, rows.Err()
}

func (s *Store) CreateChat(systemPrompt string) (Chat, error) {
	if strings.TrimSpace(systemPrompt) == "" {
		systemPrompt = DefaultSystemPrompt
	}
	c := Chat{Title: "New chat", SystemPrompt: systemPrompt, CreatedAt: now()}
	res, err := s.db.Exec(`INSERT INTO chats (title, system_prompt, created_at) VALUES (?, ?, ?)`, c.Title, c.SystemPrompt, c.CreatedAt)
	if err != nil {
		return c, err
	}
	c.ID, _ = res.LastInsertId()
	return c, nil
}

func (s *Store) GetChat(id int64) (Chat, error) {
	var c Chat
	err := s.db.QueryRow(`SELECT id, title, system_prompt, created_at FROM chats WHERE id = ?`, id).
		Scan(&c.ID, &c.Title, &c.SystemPrompt, &c.CreatedAt)
	return c, err
}

func (s *Store) UpdateChat(c Chat) error {
	_, err := s.db.Exec(`UPDATE chats SET title = ?, system_prompt = ? WHERE id = ?`, c.Title, c.SystemPrompt, c.ID)
	return err
}

func (s *Store) DeleteChat(id int64) error {
	_, err := s.db.Exec(`DELETE FROM chats WHERE id = ?`, id)
	return err
}

func (s *Store) Messages(chatID int64) ([]StoredMessage, error) {
	rows, err := s.db.Query(`SELECT id, role, content, created_at FROM messages WHERE chat_id = ? ORDER BY id`, chatID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	msgs := []StoredMessage{}
	for rows.Next() {
		var m StoredMessage
		if err := rows.Scan(&m.ID, &m.Role, &m.Content, &m.CreatedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	return msgs, rows.Err()
}

func (s *Store) AddMessage(chatID int64, role, content string) error {
	_, err := s.db.Exec(`INSERT INTO messages (chat_id, role, content, created_at) VALUES (?, ?, ?, ?)`, chatID, role, content, now())
	return err
}
