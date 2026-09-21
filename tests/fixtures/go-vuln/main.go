// Package main reaches the vulnerable symbol on purpose. govulncheck reports
// only advisories that are actually reachable from the code, so importing the
// module without calling into it would report nothing.
package main

import (
	"fmt"

	"golang.org/x/text/language"
)

func main() {
	tags, _, err := language.ParseAcceptLanguage("en-US,en;q=0.9")
	fmt.Println(tags, err)
}
