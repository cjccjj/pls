package pls

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"time"
)

const historyTimeFormat = "2006-01-02 15:04:05"

type HistoryStore struct {
	Path string
	Now  func() time.Time
}

func (h HistoryStore) Add(userMessage, assistantMessage string) error {
	now := h.now()
	if err := os.MkdirAll(filepath.Dir(h.Path), 0o755); err != nil {
		return err
	}
	file, err := os.OpenFile(h.Path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer file.Close()

	records := []HistoryRecord{
		{TimeText: now.Format(historyTimeFormat), Role: "user", Content: userMessage},
		{TimeText: now.Format(historyTimeFormat), Role: "assistant", Content: assistantMessage},
	}
	enc := json.NewEncoder(file)
	for _, record := range records {
		if err := enc.Encode(record); err != nil {
			return err
		}
	}
	return nil
}

func (h HistoryStore) Recent(maxRecords, windowMinutes int) ([]HistoryRecord, error) {
	if maxRecords <= 0 {
		maxRecords = defaultHistoryMaxRecords
	}
	if windowMinutes <= 0 {
		windowMinutes = defaultHistoryWindowMinutes
	}
	file, err := os.Open(h.Path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var all []HistoryRecord
	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		var record HistoryRecord
		if err := json.Unmarshal(scanner.Bytes(), &record); err != nil {
			continue
		}
		ts, err := time.ParseInLocation(historyTimeFormat, record.TimeText, time.Local)
		if err != nil {
			continue
		}
		record.Timestamp = ts
		all = append(all, record)
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	if len(all) > maxRecords {
		all = all[len(all)-maxRecords:]
	}
	cutoff := h.now().Add(-time.Duration(windowMinutes) * time.Minute)
	out := all[:0]
	for _, record := range all {
		if !record.Timestamp.Before(cutoff) {
			out = append(out, record)
		}
	}
	return out, nil
}

func (h HistoryStore) now() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}
