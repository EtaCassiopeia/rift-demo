package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
)

type Response struct {
	Method  string              `json:"method"`
	URL     string              `json:"url"`
	Path    string              `json:"path"`
	Headers map[string]string   `json:"headers"`
	Args    map[string][]string `json:"args,omitempty"`
	Body    string              `json:"body,omitempty"`
	JSON    any                 `json:"json,omitempty"`
}

func handler(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)

	headers := make(map[string]string)
	for k, v := range r.Header {
		headers[k] = strings.Join(v, ", ")
	}

	resp := Response{
		Method:  r.Method,
		URL:     r.URL.String(),
		Path:    r.URL.Path,
		Headers: headers,
		Args:    r.URL.Query(),
		Body:    string(body),
	}

	// Try to parse body as JSON
	if len(body) > 0 {
		var jsonBody any
		if json.Unmarshal(body, &jsonBody) == nil {
			resp.JSON = jsonBody
		}
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func main() {
	port := "8080"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	fmt.Printf("Echo server running on http://localhost:%s\n", port)
	http.HandleFunc("/", handler)
	http.ListenAndServe(":"+port, nil)
}
