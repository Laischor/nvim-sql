package db

import "strings"

// SplitStatements splits a script at top-level semicolons; leading comments and comment-only pieces are dropped.
func SplitStatements(src string) []string {
	var out []string
	n := len(src)
	i := 0
	cs := -1       // start of the current statement's first content char
	first := ""    // first keyword of the current statement
	body := false  // CREATE TRIGGER/FUNCTION/PROCEDURE: BEGIN…END may hold semicolons
	depth := 0     // BEGIN/CASE nesting inside such a body
	prevWord := "" // for E'…' detection

	mark := func(pos int) {
		if cs < 0 {
			cs = pos
		}
	}
	flush := func(end int) {
		if cs >= 0 {
			if s := strings.TrimSpace(src[cs:end]); s != "" {
				out = append(out, s)
			}
		}
		cs, first, body, depth, prevWord = -1, "", false, 0, ""
	}

	for i < n {
		ch := src[i]
		switch {
		case ch == '-' && i+1 < n && src[i+1] == '-':
			if j := strings.IndexByte(src[i:], '\n'); j < 0 {
				i = n
			} else {
				i += j
			}
		case ch == '/' && i+1 < n && src[i+1] == '*':
			i = skipBlockComment(src, i)
		case ch == '\'':
			mark(i)
			i = skipQuoted(src, i, '\'', prevWord == "e")
			prevWord = ""
		case ch == '"' || ch == '`':
			mark(i)
			i = skipQuoted(src, i, ch, false)
			prevWord = ""
		case ch == '[':
			mark(i)
			if j := strings.IndexByte(src[i:], ']'); j < 0 {
				i = n
			} else {
				i += j + 1
			}
			prevWord = ""
		case ch == '$':
			mark(i)
			i = skipDollarQuoted(src, i)
			prevWord = ""
		case ch == ';':
			if depth > 0 {
				i++
				continue
			}
			flush(i)
			i++
		case isIdentStart(ch):
			mark(i)
			j := i + 1
			for j < n && isIdentChar(src[j]) {
				j++
			}
			word := strings.ToLower(src[i:j])
			if first == "" {
				first = word
			}
			if first == "create" {
				switch word {
				case "trigger", "function", "procedure":
					body = true
				case "begin":
					if body {
						depth++
					}
				case "case":
					if depth > 0 {
						depth++
					}
				case "end":
					if depth > 0 {
						depth--
					}
				}
			}
			prevWord = word
			i = j
		default:
			if !isSpace(ch) {
				mark(i)
				prevWord = ""
			}
			i++
		}
	}
	flush(n)
	return out
}

func isSpace(c byte) bool {
	return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v'
}

func isIdentStart(c byte) bool {
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c >= 0x80
}

func isIdentChar(c byte) bool {
	return isIdentStart(c) || (c >= '0' && c <= '9') || c == '$'
}

// skipBlockComment returns the index after the (nested) comment starting at i.
func skipBlockComment(src string, i int) int {
	n := len(src)
	depth := 0
	for i < n {
		if i+1 < n && src[i] == '/' && src[i+1] == '*' {
			depth++
			i += 2
			continue
		}
		if i+1 < n && src[i] == '*' && src[i+1] == '/' {
			depth--
			i += 2
			if depth == 0 {
				return i
			}
			continue
		}
		i++
	}
	return n
}

// skipQuoted returns the index after the closing quote; doubled quotes stay inside, backslashes escape in E'…'.
func skipQuoted(src string, i int, q byte, backslash bool) int {
	n := len(src)
	i++
	for i < n {
		c := src[i]
		if backslash && c == '\\' {
			i += 2
			continue
		}
		if c == q {
			if i+1 < n && src[i+1] == q {
				i += 2
				continue
			}
			return i + 1
		}
		i++
	}
	return n
}

// skipDollarQuoted returns the index after a $tag$…$tag$ literal, or i+1 when src[i] starts none.
func skipDollarQuoted(src string, i int) int {
	n := len(src)
	j := i + 1
	for j < n && (isIdentStart(src[j]) || (j > i+1 && src[j] >= '0' && src[j] <= '9')) {
		j++
	}
	if j >= n || src[j] != '$' {
		return i + 1
	}
	tag := src[i : j+1]
	end := strings.Index(src[j+1:], tag)
	if end < 0 {
		return n
	}
	return j + 1 + end + len(tag)
}
