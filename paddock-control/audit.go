package main

import (
	"encoding/json"
	"os"
	"sync"
	"time"
)

// auditLog appends one JSON line per event that changes who can reach the control plane: tokens
// made, hosts enrolled or removed, links opened, refused and closed. It never holds a secret.
type auditLog struct {
	mu   sync.Mutex
	file *os.File
}

type auditEvent struct {
	Time   time.Time `json:"time"`
	Event  string    `json:"event"`
	Host   string    `json:"host,omitempty"`
	Name   string    `json:"name,omitempty"`
	Remote string    `json:"remote,omitempty"`
	Reason string    `json:"reason,omitempty"`
}

func openAuditLog(path string) (*auditLog, error) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return &auditLog{file: file}, nil
}

func (a *auditLog) record(event auditEvent) {
	event.Time = time.Now().UTC()
	line, err := json.Marshal(event)
	if err != nil {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	_, _ = a.file.Write(append(line, '\n'))
}

func (a *auditLog) close() error {
	return a.file.Close()
}
