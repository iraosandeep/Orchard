package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

//go:embed defaults.yaml
var defaultTasksYAML []byte

type Option struct {
	Label   string   `yaml:"label" json:"label"`
	Default string   `yaml:"default" json:"default"`
	Choices []string `yaml:"choices" json:"choices,omitempty"`
}

type Task struct {
	Name          string  `yaml:"name" json:"name"`
	Label         string  `yaml:"label" json:"label"`
	System        string  `yaml:"system" json:"system"`
	Option        *Option `yaml:"option" json:"option,omitempty"`
	JSON          bool    `yaml:"json" json:"json"`
	MaxInputChars int     `yaml:"max_input_chars" json:"max_input_chars,omitempty"`
}

// LoadTasks reads tasks.yaml from dir, writing the defaults on first run.
func LoadTasks(dir string) ([]Task, error) {
	path := filepath.Join(dir, "tasks.yaml")
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		if err := os.WriteFile(path, defaultTasksYAML, 0o644); err != nil {
			return nil, err
		}
		b = defaultTasksYAML
	} else if err != nil {
		return nil, err
	}
	var tasks []Task
	if err := yaml.Unmarshal(b, &tasks); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	for i, t := range tasks {
		if t.Name == "" || t.System == "" {
			return nil, fmt.Errorf("%s: task %d needs name and system", path, i+1)
		}
		if t.Label == "" {
			tasks[i].Label = t.Name
		}
	}
	return tasks, nil
}

func FindTask(tasks []Task, name string) (Task, bool) {
	for _, t := range tasks {
		if t.Name == name {
			return t, true
		}
	}
	return Task{}, false
}

type Prepared struct {
	Messages  []Message
	Truncated bool
	InputLen  int // runes in the original input
	SentLen   int // runes actually sent
	Tokens    int
}

// Prepare builds the request for a task, trimming input to fit the budget.
func (t Task) Prepare(input, option string) Prepared {
	if t.Option != nil && strings.TrimSpace(option) == "" {
		option = t.Option.Default
	}
	system := strings.ReplaceAll(t.System, "{option}", option)

	maxChars := (BudgetTokens - EstTokens(system) - 8) * 4
	if t.MaxInputChars > 0 && t.MaxInputChars < maxChars {
		maxChars = t.MaxInputChars
	}
	sent, truncated := TrimText(input, maxChars)
	msgs := []Message{{Role: "system", Content: system}, {Role: "user", Content: sent}}
	return Prepared{
		Messages:  msgs,
		Truncated: truncated,
		InputLen:  len([]rune(input)),
		SentLen:   len([]rune(sent)),
		Tokens:    MsgTokens(msgs),
	}
}

// RunTask streams a task's output. JSON tasks are validated; on invalid
// output, onRetry is called and the task runs once more. If the retry is also
// invalid the raw text stands.
func (g *Guard) RunTask(ctx context.Context, t Task, p Prepared, onDelta func(string) error, onRetry func() error) (string, error) {
	var sb strings.Builder
	collect := func(s string) error { sb.WriteString(s); return onDelta(s) }
	if err := g.Stream(ctx, p.Messages, collect); err != nil {
		return sb.String(), err
	}
	if !t.JSON {
		return sb.String(), nil
	}
	if out, ok := CleanJSON(sb.String()); ok {
		return out, nil
	}
	if err := onRetry(); err != nil {
		return sb.String(), err
	}
	sb.Reset()
	retry := append([]Message{}, p.Messages...)
	retry[0].Content += "\nRespond with valid JSON only."
	if err := g.Stream(ctx, retry, collect); err != nil {
		return sb.String(), err
	}
	if out, ok := CleanJSON(sb.String()); ok {
		return out, nil
	}
	return sb.String(), nil
}

// CleanJSON strips code fences and surrounding prose, returning compact-ish
// indented JSON if what remains is valid.
func CleanJSON(s string) (string, bool) {
	s = strings.TrimSpace(s)
	s = strings.TrimPrefix(s, "```json")
	s = strings.TrimPrefix(s, "```")
	s = strings.TrimSuffix(s, "```")
	if i, j := strings.Index(s, "{"), strings.LastIndex(s, "}"); i >= 0 && j > i {
		s = s[i : j+1]
	}
	var v any
	if json.Unmarshal([]byte(s), &v) != nil {
		return "", false
	}
	b, _ := json.MarshalIndent(v, "", "  ")
	return string(b), true
}
