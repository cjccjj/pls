package pls

import (
	"fmt"
	"io"
	"sort"
	"strings"
	"time"
)

const (
	colorReset  = "\033[0m"
	colorGreen  = "\033[32m"
	colorGrey   = "\033[90m"
	colorCyan   = "\033[36m"
	colorYellow = "\033[33m"
)

const spinnerDelay = 200 * time.Millisecond

var spinnerFrames = []string{"⠷", "⠯", "⠟", "⠻", "⠽", "⠾"}

func startSpinner(w io.Writer, model string) (stop func()) {
	done := make(chan struct{})
	exited := make(chan struct{})
	go func() {
		defer close(exited)
		i := 0
		for {
			select {
			case <-done:
				return
			default:
				fmt.Fprintf(w, "\r%s%s%s %s%s:%s", colorGreen, spinnerFrames[i%len(spinnerFrames)], colorReset, colorGrey, model, colorReset)
				i++
			}
			select {
			case <-done:
				return
			case <-time.After(spinnerDelay):
			}
		}
	}()
	return func() {
		close(done)
		<-exited
		fmt.Fprint(w, "\r\033[K")
	}
}

func formatMenu(items string) string {
	var s string
	s += colorGrey + "( " + colorReset
	if containsRune(items, 'r') {
		s += colorCyan + "r ⏎" + colorReset + colorGrey + " : run cmd | " + colorReset
	}
	if containsRune(items, 'e') {
		s += colorCyan + "e ⏎" + colorReset + colorGrey + " : edit cmd | " + colorReset
	}
	if containsRune(items, 'q') {
		s += colorCyan + "q ⏎" + colorReset + colorGrey + " : quit | " + colorReset
	}
	s += colorCyan + "... ⏎" + colorReset + colorGrey + " : chat )" + colorReset
	return s
}

func containsRune(s string, r rune) bool {
	for _, c := range s {
		if c == r {
			return true
		}
	}
	return false
}

func formatProfileList(profiles map[string]Profile, env map[string]string) string {
	var names []string
	for name := range profiles {
		names = append(names, name)
	}
	sort.Strings(names)
	var sb strings.Builder
	for _, name := range names {
		p := profiles[name]
		sb.WriteString(colorCyan + name + colorReset)
		sb.WriteString("  " + p.Provider + "  " + p.Model)
		if env[p.EnvKey] != "" {
			sb.WriteString("  " + colorGreen + "KEY" + colorReset)
		}
		sb.WriteString("\n")
	}
	sb.WriteString("\n" + colorGrey + `Say "switch to <name>" to change.` + colorReset)
	return sb.String()
}
