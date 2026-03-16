package main

import (
	"fmt"
	"os"
	"strings"
)

func cmdLint(filename string) {
	data, err := os.ReadFile(filename)
	if err != nil {
		fatal("read %s: %v", filename, err)
	}

	cells := parseCellFile(string(data))
	if cells == nil {
		fmt.Printf("✗ %s: parse failed (not valid v1 or v2 syntax)\n", filename)
		os.Exit(1)
	}

	errors := lintCells(cells)
	if len(errors) == 0 {
		fmt.Printf("✓ %s: %d cells, no issues\n", filename, len(cells))
		return
	}

	fmt.Printf("✗ %s: %d cells, %d issues:\n", filename, len(cells), len(errors))
	for _, e := range errors {
		fmt.Printf("  %s\n", e)
	}
	os.Exit(1)
}

func lintCells(cells []parsedCell) []string {
	var errs []string

	// Build name set
	names := make(map[string]int)
	for _, c := range cells {
		names[c.name]++
	}

	// Check: duplicate cell names
	for name, count := range names {
		if count > 1 {
			errs = append(errs, fmt.Sprintf("duplicate cell name %q (%d definitions)", name, count))
		}
	}

	// Check: dangling givens (reference non-existent cells)
	// Account for iteration expansion: "refine" with iterate>0 creates "refine-1", etc.
	iterBases := make(map[string]int)
	for _, c := range cells {
		if c.iterate > 0 {
			iterBases[c.name] = c.iterate
		}
	}

	for _, c := range cells {
		for _, g := range c.givens {
			src := g.sourceCell
			// Handle gather wildcards
			if strings.HasSuffix(src, "-*") {
				base := strings.TrimSuffix(src, "-*")
				if _, ok := iterBases[base]; !ok {
					if _, exists := names[base]; !exists {
						errs = append(errs, fmt.Sprintf("cell %q: dangling given %s.%s (no cell or iteration %q)", c.name, src, g.sourceField, base))
					}
				}
				continue
			}
			if _, exists := names[src]; !exists {
				// Check if it's an iteration reference like "refine-1"
				isIterRef := false
				for base, n := range iterBases {
					for i := 1; i <= n; i++ {
						if src == fmt.Sprintf("%s-%d", base, i) {
							isIterRef = true
							break
						}
					}
				}
				// Check if it's a judge reference
				if !isIterRef && !strings.Contains(src, "-judge-") {
					errs = append(errs, fmt.Sprintf("cell %q: dangling given %s.%s (no cell %q)", c.name, src, g.sourceField, src))
				}
			}
		}
	}

	// Check: cells with no yields
	for _, c := range cells {
		if len(c.yields) == 0 {
			errs = append(errs, fmt.Sprintf("cell %q: no yields declared", c.name))
		}
	}

	// Check: dependency cycles (DFS)
	// Build adjacency: cell -> cells it depends on
	adj := make(map[string][]string)
	for _, c := range cells {
		for _, g := range c.givens {
			adj[c.name] = append(adj[c.name], g.sourceCell)
		}
	}
	// DFS for cycles (skip self-loops for iteration/stem cells)
	visited := make(map[string]int) // 0=unvisited, 1=visiting, 2=done
	var cyclePath []string
	var dfs func(string) bool
	dfs = func(node string) bool {
		if visited[node] == 2 {
			return false
		}
		if visited[node] == 1 {
			cyclePath = append(cyclePath, node)
			return true
		}
		visited[node] = 1
		for _, dep := range adj[node] {
			if dep == node {
				continue // self-loop (iteration chaining)
			}
			if dfs(dep) {
				cyclePath = append(cyclePath, node)
				return true
			}
		}
		visited[node] = 2
		return false
	}
	for _, c := range cells {
		if visited[c.name] == 0 {
			if dfs(c.name) {
				errs = append(errs, fmt.Sprintf("dependency cycle: %s", strings.Join(cyclePath, " → ")))
				break
			}
		}
	}

	// Check: stem cells missing body
	for _, c := range cells {
		if c.bodyType == "stem" && c.body == "" {
			errs = append(errs, fmt.Sprintf("cell %q: stem cell with no body", c.name))
		}
	}

	return errs
}
