package main

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

// RewriteMaxChars matches the native Rewrite window: longer selections are
// refused rather than truncated, because the result replaces the selection.
const RewriteMaxChars = 6000

// RewriteMessages builds the request for rewriting text with a free-form
// instruction, using the same prompt as the native Rewrite window.
func RewriteMessages(text, instruction string) ([]Message, error) {
	instruction = strings.TrimSpace(instruction)
	if instruction == "" || strings.TrimSpace(text) == "" {
		return nil, fmt.Errorf("text and instruction required")
	}
	system := "Rewrite the user's text. Instruction: " + instruction + "\n" +
		"Output only the rewritten text: no preamble, no quotes, no explanation."
	limit := (BudgetTokens - EstTokens(system) - 8) * 4
	if limit > RewriteMaxChars {
		limit = RewriteMaxChars
	}
	if n := utf8.RuneCountInString(text); n > limit {
		return nil, fmt.Errorf("text is too long (%d characters); rewrite handles up to %d so nothing gets cut off", n, limit)
	}
	return []Message{{Role: "system", Content: system}, {Role: "user", Content: text}}, nil
}
