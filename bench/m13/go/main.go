// The comparison server: the same routes as ../app.roc.
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
)

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /plaintext", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		io.WriteString(w, "Hello, World!")
	})
	mux.HandleFunc("GET /json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"message":"Hello, World!"}`)
	})
	mux.HandleFunc("POST /echo", func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(r.Body)
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		w.Write(body)
	})
	// 100 routes that differ in their first segment.
	for index := 0; index < 100; index++ {
		mux.HandleFunc(fmt.Sprintf("GET /r%d/items/{id}", index), func(w http.ResponseWriter, r *http.Request) {
			io.WriteString(w, r.PathValue("id"))
		})
	}
	address := "127.0.0.1:0"
	mode, err := os.ReadFile("benchmark-remote")
	if err == nil && string(mode) == "enabled\n" {
		address = "0.0.0.0:8080"
	} else if !os.IsNotExist(err) {
		panic("benchmark-remote must contain enabled followed by a newline")
	}
	listener, err := net.Listen("tcp", address)
	if err != nil {
		panic(err)
	}
	fmt.Println(listener.Addr().(*net.TCPAddr).Port)
	http.Serve(listener, mux)
}
