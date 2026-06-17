package pls

import (
	"encoding/json"
	"strings"
)

type shellMode int

const (
	shellUnknown shellMode = iota
	shellFalse
	shellTrue
)

type fieldStreamer struct {
	raw       strings.Builder
	emitted   int
	onDelta   func(field, content string)
	mode      shellMode
	fieldDone bool
	completed bool
}

func newFieldStreamer(onDelta func(field, content string)) *fieldStreamer {
	return &fieldStreamer{onDelta: onDelta}
}

func (s *fieldStreamer) Feed(delta string) {
	if s.onDelta == nil || s.completed {
		return
	}
	s.raw.WriteString(delta)
	raw := s.raw.String()

	if s.mode == shellUnknown {
		s.mode = shellRequestedMode(raw)
		if s.mode == shellUnknown {
			// Mode unknown but text may have arrived — try chat_response eagerly.
			// DeepSeek often emits chat_response before shell_command_requested.
			s.drainField(raw, "chat_response")
			return
		}
	}

	if s.mode == shellTrue {
		s.drainShellFields(raw)
		return
	}
	s.drainField(raw, "chat_response")
}

func (s *fieldStreamer) drainShellFields(raw string) {
	if !s.fieldDone {
		s.drainField(raw, "shell_command_explanation")
		if !s.fieldDone {
			return
		}
		// reset for next field
		s.emitted = 0
	}
	s.drainField(raw, "shell_command")
}

func (s *fieldStreamer) drainField(raw, field string) {
	value, complete, ok := partialJSONStringField(raw, field)
	if !ok {
		return
	}
	if len(value) > s.emitted {
		s.onDelta(field, value[s.emitted:])
		s.emitted = len(value)
	}
	if complete {
		s.fieldDone = true
		if field == "shell_command" {
			s.completed = true
		}
	}
}

func shellRequestedMode(raw string) shellMode {
	key := `"shell_command_requested"`
	idx := strings.Index(raw, key)
	if idx < 0 {
		return shellUnknown
	}
	rest := strings.TrimLeft(raw[idx+len(key):], " \n\r\t")
	if !strings.HasPrefix(rest, ":") {
		return shellUnknown
	}
	rest = strings.TrimLeft(rest[1:], " \n\r\t")
	if strings.HasPrefix(rest, "false") {
		return shellFalse
	}
	if strings.HasPrefix(rest, "true") {
		return shellTrue
	}
	return shellUnknown
}

func partialJSONStringField(raw, field string) (string, bool, bool) {
	key := `"` + field + `"`
	idx := strings.Index(raw, key)
	if idx < 0 {
		return "", false, false
	}
	rest := strings.TrimLeft(raw[idx+len(key):], " \n\r\t")
	if !strings.HasPrefix(rest, ":") {
		return "", false, false
	}
	rest = strings.TrimLeft(rest[1:], " \n\r\t")
	if !strings.HasPrefix(rest, `"`) {
		return "", false, false
	}
	content := rest[1:]
	escaped := false
	for i, r := range content {
		if escaped {
			escaped = false
			continue
		}
		if r == '\\' {
			escaped = true
			continue
		}
		if r == '"' {
			value, err := strconvUnquote(`"` + content[:i] + `"`)
			if err != nil {
				return "", false, false
			}
			return value, true, true
		}
	}
	value, err := strconvUnquote(`"` + content + `"`)
	if err != nil {
		return "", false, true
	}
	return value, false, true
}

func strconvUnquote(s string) (string, error) {
	var out string
	err := json.Unmarshal([]byte(s), &out)
	return out, err
}
