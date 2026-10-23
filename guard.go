package main

// The guard is the only code that talks to fm serve. Every request goes
// through it so that nothing the model can't handle is ever sent: plain
// string content, no tools, input trimmed to the token budget, and SSE parsed
// whether or not streaming was asked for.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

const (
	ContextTokens = 4096
	BudgetTokens  = 3000 // input budget; the rest is left for the reply
)

type Message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

// EstTokens estimates tokens as characters ÷ 4.
func EstTokens(s string) int { return (utf8.RuneCountInString(s) + 3) / 4 }

func MsgTokens(msgs []Message) int {
	n := 0
	for _, m := range msgs {
		n += EstTokens(m.Content) + 4 // small per-message overhead
	}
	return n
}

// TrimText cuts s to at most maxChars runes, on a rune boundary.
func TrimText(s string, maxChars int) (string, bool) {
	if maxChars <= 0 || utf8.RuneCountInString(s) <= maxChars {
		return s, false
	}
	r := []rune(s)
	return string(r[:maxChars]), true
}

// FitHistory drops the oldest turns until system + history fits the budget.
// The last message is always kept, truncated if it alone is too big.
// Returns the messages to send (including system) and how many were dropped.
func FitHistory(system string, history []Message, budget int) ([]Message, int) {
	var head []Message
	if strings.TrimSpace(system) != "" {
		head = []Message{{Role: "system", Content: system}}
	}
	dropped := 0
	for len(history) > 1 && MsgTokens(head)+MsgTokens(history) > budget {
		history = history[1:]
		dropped++
	}
	// Don't start on an assistant turn after dropping.
	for len(history) > 1 && history[0].Role == "assistant" {
		history = history[1:]
		dropped++
	}
	if len(history) == 1 {
		room := budget - MsgTokens(head) - 4
		if room < 64 {
			room = 64
		}
		last := history[0]
		last.Content, _ = TrimText(last.Content, room*4)
		history = []Message{last}
	}
	return append(head, history...), dropped
}

type Guard struct {
	BaseURL string
	HTTP    *http.Client
}

func NewGuard(baseURL string) *Guard {
	return &Guard{BaseURL: strings.TrimRight(baseURL, "/"), HTTP: &http.Client{}}
}

func (g *Guard) Health(ctx context.Context) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, _ := http.NewRequestWithContext(ctx, "GET", g.BaseURL+"/health", nil)
	resp, err := g.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("fm serve health: %s", resp.Status)
	}
	return b, nil
}

// Stream sends msgs and calls onDelta for each chunk of reply text.
func (g *Guard) Stream(ctx context.Context, msgs []Message, onDelta func(string) error) error {
	clean := make([]Message, 0, len(msgs))
	for _, m := range msgs {
		clean = append(clean, Message{Role: m.Role, Content: m.Content})
	}
	body, _ := json.Marshal(map[string]any{
		"model":    "system",
		"messages": clean,
		"stream":   true,
	})
	req, err := http.NewRequestWithContext(ctx, "POST", g.BaseURL+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "text/event-stream")
	resp, err := g.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("fm serve unreachable at %s (is `fm serve` running?): %w", g.BaseURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
		return fmt.Errorf("fm serve: %s: %s", resp.Status, strings.TrimSpace(string(b)))
	}

	// Plain JSON fallback, in case a future fm serve honours stream:false.
	if strings.HasPrefix(resp.Header.Get("Content-Type"), "application/json") {
		var r struct {
			Choices []struct {
				Message Message `json:"message"`
			} `json:"choices"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&r); err != nil {
			return err
		}
		if len(r.Choices) > 0 {
			return onDelta(r.Choices[0].Message.Content)
		}
		return nil
	}

	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 64*1024), 1024*1024)
	for sc.Scan() {
		line := sc.Text()
		if !strings.HasPrefix(line, "data:") {
			continue
		}
		data := strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if data == "[DONE]" {
			return nil
		}
		var chunk struct {
			Choices []struct {
				Delta struct {
					Content string `json:"content"`
				} `json:"delta"`
			} `json:"choices"`
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			continue
		}
		if chunk.Error != nil {
			return errors.New("fm serve: " + chunk.Error.Message)
		}
		for _, c := range chunk.Choices {
			if c.Delta.Content != "" {
				if err := onDelta(c.Delta.Content); err != nil {
					return err
				}
			}
		}
	}
	return sc.Err()
}

// Complete is Stream collected into one string.
func (g *Guard) Complete(ctx context.Context, msgs []Message) (string, error) {
	var sb strings.Builder
	err := g.Stream(ctx, msgs, func(s string) error { sb.WriteString(s); return nil })
	return sb.String(), err
}
