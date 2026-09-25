package main

import (
	"fmt"

	"github.com/WenshuaiDev/Omega/libs/buildinfo"
)

func main() {
	fmt.Printf("Omega example-service version=%s\n", buildinfo.Version())
}
