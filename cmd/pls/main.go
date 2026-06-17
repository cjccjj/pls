package main

import (
	"context"
	"fmt"
	"os"

	"github.com/cjccjj/pls/internal/pls"
)

func main() {
	app := pls.NewApp(os.Stdin, os.Stdout, os.Stderr, os.Environ())
	if err := app.Run(context.Background(), os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
