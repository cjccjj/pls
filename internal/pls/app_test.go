package pls

import (
	"testing"
)

func TestParseArgs(t *testing.T) {
	got, err := parseArgs([]string{"-p", "how", "now"})
	if err != nil {
		t.Fatal(err)
	}
	if !got.showPiped || len(got.messages) != 2 {
		t.Fatalf("args = %#v", got)
	}
	got, err = parseArgs([]string{"-h"})
	if err != nil {
		t.Fatal(err)
	}
	if !got.help {
		t.Fatalf("help = %#v", got)
	}
	if _, err := parseArgs([]string{"-x"}); err == nil {
		t.Fatal("expected unknown flag error")
	}
}
