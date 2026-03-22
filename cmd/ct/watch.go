package main

import (
	"database/sql"
	"fmt"
	"os"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/bubbles/v2/spinner"
	"charm.land/bubbles/v2/viewport"
	"charm.land/lipgloss/v2"
)

type watchYield struct {
	field, value   string
	frozen, bottom bool
}

type watchCell struct {
	id, prog, name, state, bodyType string
	body                            string
	computingSince                  *time.Time
	assignedPiston                  string
	yields                          []watchYield
}

type watchDataMsg struct {
	cells    []watchCell
	programs map[string][3]int // [total, frozen, bottom]
	err      error
}

type tickRefresh struct{}

type navKind int

const (
	navProgram navKind = iota
	navCell
)

type navItem struct {
	kind    navKind
	prog    string
	cellIdx int // index into m.cells (-1 for program headers)
}

type watchModel struct {
	db        *sql.DB
	progID    string
	cells     []watchCell
	programs  map[string][3]int // [total, frozen, bottom]
	progOrder []string
	err       error
	width     int
	height    int
	viewport  viewport.Model
	spinner   spinner.Model
	fetching  bool
	lastFetch time.Time
	collapsed map[string]bool // program-level collapse
	expanded  map[string]bool // cell-level yield expand (key: cell id)
	cursor    int             // index into navItems()
	ready     bool
	// Detail pane
	showDetail bool
	detailVP   viewport.Model
	detail     *cellDetail
	detailCell string // cell id currently shown in detail
	// Search
	filtering  bool
	filterText string
	// Active-only filter
	activeOnly bool
	// Help overlay
	showHelp bool
	// Auto-retry state
	retryCountdown int // seconds until next retry (0 = not retrying)
	// Monotonicity tracking
	prevNonFrozen  int  // non-frozen count from previous refresh
	nonFrozenAlert bool // true if non-frozen count increased
	// Session stats
	stats watchStats
}

type watchStats struct {
	sessionStart   time.Time
	navCount       int            // j/k moves
	expandCount    int            // enter on cells
	collapseCount  int            // enter on programs
	detailOpens    int            // d presses to open
	detailTime     time.Duration  // total time detail was open
	detailOpenedAt *time.Time     // when detail was last opened
	searchCount    int            // / presses
	expandAll      int            // e presses
	collapseAll    int            // c presses
	cellVisits     map[string]int // "prog/cell" -> visit count
}

var (
	headerStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	doneStyle      = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("2"))
	progStyle      = lipgloss.NewStyle().Bold(true)
	footerStyle    = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	cursorStyle    = lipgloss.NewStyle().Bold(true).Foreground(lipgloss.Color("6"))
	frozenValStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("4"))
	pendValStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("3"))
	bottomValStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("1"))
	errStyle       = lipgloss.NewStyle().Foreground(lipgloss.Color("1")).Bold(true)
	barDoneStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("2"))
	barTodoStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
	iconStyles     = map[string]lipgloss.Style{
		"frozen":    lipgloss.NewStyle().Foreground(lipgloss.Color("4")),
		"computing": lipgloss.NewStyle().Foreground(lipgloss.Color("3")),
		"declared":  lipgloss.NewStyle().Foreground(lipgloss.Color("7")),
		"bottom":    lipgloss.NewStyle().Foreground(lipgloss.Color("1")),
	}
	detailLabelStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("5")).Bold(true)
	detailDimStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("8"))
)

// --- Detail pane types ---

type givenInfo struct {
	sourceCell, sourceField string
	value                   string
	frozen, optional        bool
}

type oracleInfo struct {
	oracleType, assertion string
}

type traceEvent struct {
	eventType, detail string
	createdAt         time.Time
}

type yieldInfo struct {
	fieldName string
	valueText string
	isFrozen  bool
}

type cellDetail struct {
	body, bodyType, modelHint string
	assignedPiston            string
	givens                    []givenInfo
	yields                    []yieldInfo
	oracles                   []oracleInfo
	trace                     []traceEvent
}

type detailDataMsg struct {
	cellKey string
	detail  *cellDetail
	err     error
}

func queryDetailData(db *sql.DB, cellID, progID string) (*cellDetail, error) {
	d := &cellDetail{}

	// Cell metadata
	db.QueryRow("SELECT COALESCE(body,''), body_type, COALESCE(model_hint,''), COALESCE(assigned_piston,'') FROM cells WHERE id = ?", cellID).
		Scan(&d.body, &d.bodyType, &d.modelHint, &d.assignedPiston)

	// Givens with resolved values
	gRows, err := db.Query(`
		SELECT g.source_cell, g.source_field, g.is_optional,
		       COALESCE(y.value_text, ''), COALESCE(y.is_frozen, 0)
		FROM givens g
		JOIN cells src ON src.program_id = ? AND src.name = g.source_cell
		LEFT JOIN yields y ON y.cell_id = src.id AND y.field_name = g.source_field
		WHERE g.cell_id = ?`, progID, cellID)
	if err == nil {
		defer gRows.Close()
		for gRows.Next() {
			var gi givenInfo
			gRows.Scan(&gi.sourceCell, &gi.sourceField, &gi.optional, &gi.value, &gi.frozen)
			d.givens = append(d.givens, gi)
		}
	}

	// Yields
	yRows, err := db.Query("SELECT field_name, COALESCE(value_text, ''), is_frozen FROM yields WHERE cell_id = ?", cellID)
	if err == nil {
		defer yRows.Close()
		for yRows.Next() {
			var yi yieldInfo
			yRows.Scan(&yi.fieldName, &yi.valueText, &yi.isFrozen)
			d.yields = append(d.yields, yi)
		}
	}

	// Oracles
	oRows, err := db.Query("SELECT oracle_type, assertion FROM oracles WHERE cell_id = ?", cellID)
	if err == nil {
		defer oRows.Close()
		for oRows.Next() {
			var oi oracleInfo
			oRows.Scan(&oi.oracleType, &oi.assertion)
			d.oracles = append(d.oracles, oi)
		}
	}

	// Recent trace
	tRows, err := db.Query("SELECT event_type, COALESCE(detail,''), created_at FROM trace WHERE cell_id = ? ORDER BY created_at DESC LIMIT 5", cellID)
	if err == nil {
		defer tRows.Close()
		for tRows.Next() {
			var te traceEvent
			tRows.Scan(&te.eventType, &te.detail, &te.createdAt)
			d.trace = append(d.trace, te)
		}
	}

	return d, nil
}

func (m watchModel) fetchDetailCmd() tea.Cmd {
	items := m.navItems()
	if m.cursor < 0 || m.cursor >= len(items) || items[m.cursor].kind != navCell {
		return nil
	}
	c := m.cells[items[m.cursor].cellIdx]
	cellKey := c.id
	progID := c.prog
	db := m.db
	return func() tea.Msg {
		detail, err := queryDetailData(db, cellKey, progID)
		return detailDataMsg{cellKey: cellKey, detail: detail, err: err}
	}
}

func (m watchModel) renderDetail() string {
	if m.detail == nil {
		items := m.navItems()
		if m.cursor >= 0 && m.cursor < len(items) && items[m.cursor].kind == navProgram {
			return detailDimStyle.Render("  Select a cell to inspect")
		}
		return detailDimStyle.Render("  Loading...")
	}

	d := m.detail
	var buf strings.Builder
	maxW := m.width - 4
	if maxW < 40 {
		maxW = 40
	}

	// Body
	buf.WriteString(detailLabelStyle.Render("  BODY"))
	if d.bodyType != "" {
		buf.WriteString(detailDimStyle.Render(fmt.Sprintf(" (%s)", d.bodyType)))
	}
	if d.modelHint != "" {
		buf.WriteString(detailDimStyle.Render(fmt.Sprintf(" model:%s", d.modelHint)))
	}
	if d.assignedPiston != "" {
		buf.WriteString(detailDimStyle.Render(fmt.Sprintf(" piston:%s", d.assignedPiston)))
	}
	buf.WriteString("\n")
	body := d.body
	if len(body) > maxW*3 {
		body = body[:maxW*3] + "..."
	}
	for _, line := range strings.Split(body, "\n") {
		buf.WriteString("    " + line + "\n")
	}

	// Givens
	if len(d.givens) > 0 {
		buf.WriteString(detailLabelStyle.Render("  GIVENS") + "\n")
		for _, g := range d.givens {
			frozen := "○"
			if g.frozen {
				frozen = frozenValStyle.Render("■")
			}
			opt := ""
			if g.optional {
				opt = detailDimStyle.Render(" (optional)")
			}
			val := g.value
			if val == "" {
				val = detailDimStyle.Render("—")
			} else {
				val = trunc(val, maxW-30)
			}
			buf.WriteString(fmt.Sprintf("    %s %s→%s%s = %s\n", frozen, g.sourceCell, g.sourceField, opt, val))
		}
	}

	// Yields — full content with word wrapping (scrollable via detail viewport)
	if len(d.yields) > 0 {
		buf.WriteString(detailLabelStyle.Render("  YIELDS") + "\n")
		for _, y := range d.yields {
			icon := "○"
			valStyle := pendValStyle
			if y.isFrozen {
				icon = frozenValStyle.Render("■")
				valStyle = frozenValStyle
			}
			if y.valueText == "" {
				buf.WriteString(fmt.Sprintf("    %s %s = %s\n", icon, y.fieldName, detailDimStyle.Render("—")))
			} else {
				// Show full value with word wrapping for long content
				wrapW := maxW - 8 // indent for continuation lines
				if wrapW < 30 {
					wrapW = 30
				}
				wrapped := wordWrap(y.valueText, wrapW)
				lines := strings.Split(wrapped, "\n")
				buf.WriteString(fmt.Sprintf("    %s %s = %s\n", icon, y.fieldName, valStyle.Render(lines[0])))
				for _, wl := range lines[1:] {
					buf.WriteString(fmt.Sprintf("        %s\n", valStyle.Render(wl)))
				}
			}
		}
	}

	// Oracles
	if len(d.oracles) > 0 {
		buf.WriteString(detailLabelStyle.Render("  ORACLES") + "\n")
		for _, o := range d.oracles {
			typ := detailDimStyle.Render(fmt.Sprintf("[%s]", o.oracleType))
			buf.WriteString(fmt.Sprintf("    %s %s\n", typ, o.assertion))
		}
	}

	// Trace
	if len(d.trace) > 0 {
		buf.WriteString(detailLabelStyle.Render("  TRACE") + "\n")
		for _, t := range d.trace {
			ts := detailDimStyle.Render(t.createdAt.Format("15:04:05"))
			detail := ""
			if t.detail != "" {
				detail = " " + trunc(t.detail, maxW-30)
			}
			buf.WriteString(fmt.Sprintf("    %s %s%s\n", ts, t.eventType, detail))
		}
	}

	return buf.String()
}

// navItems builds the flat list of navigable items (program headers + cells).
func (m watchModel) navItems() []navItem {
	var items []navItem
	filter := strings.ToLower(m.filterText)
	for _, prog := range m.progOrder {
		// Collect cells for this program first to decide if program header is shown
		var progCells []navItem
		if !m.collapsed[prog] {
			for i, c := range m.cells {
				if c.prog != prog {
					continue
				}
				// Active-only filter: hide frozen and bottom cells
				if m.activeOnly && (c.state == "frozen" || c.state == "bottom") {
					continue
				}
				if filter != "" && !strings.Contains(strings.ToLower(c.name), filter) &&
					!strings.Contains(strings.ToLower(c.prog), filter) {
					continue
				}
				progCells = append(progCells, navItem{kind: navCell, prog: prog, cellIdx: i})
			}
		}
		// In active-only mode with expanded programs, skip programs with no visible cells
		if m.activeOnly && !m.collapsed[prog] && len(progCells) == 0 {
			continue
		}
		items = append(items, navItem{kind: navProgram, prog: prog, cellIdx: -1})
		items = append(items, progCells...)
	}
	return items
}

// clampCursor keeps cursor in bounds after data refresh.
func (m *watchModel) clampCursor() {
	items := m.navItems()
	if m.cursor >= len(items) {
		m.cursor = len(items) - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
}

// cursorLine computes which line in renderContent the cursor item is on.
func (m watchModel) cursorLine() int {
	items := m.navItems()
	line := 0
	if m.err != nil {
		line++ // error line
		if !m.lastFetch.IsZero() {
			line++ // last-ok line
		}
		line++ // blank
	}

	for i, item := range items {
		if i == m.cursor {
			return line
		}
		line++ // this item's line
		// If it's an expanded cell, count yield lines too
		if item.kind == navCell {
			c := m.cells[item.cellIdx]
			if m.expanded[c.id] {
				line += len(c.yields)
			}
		}
	}
	return line
}

func queryWatchData(db *sql.DB, progID string) ([]watchCell, map[string][3]int, error) {
	var rows *sql.Rows
	var err error
	// Join frames to sort yields by generation DESC so the latest frame's yields
	// come first — the Go dedup below keeps only the first occurrence per field_name,
	// which gives us the latest generation's value for multi-gen stem cells.
	q := `SELECT c.id, c.program_id, c.name, c.state, c.body_type, c.body,
	             c.computing_since, c.assigned_piston,
	             y.field_name, y.value_text, y.is_frozen, y.is_bottom
	      FROM cells c
	      LEFT JOIN yields y ON y.cell_id = c.id
	      LEFT JOIN frames yf ON yf.id = y.frame_id`
	// Order: computing first (active), then declared (ready), then frozen (done).
	// Within a cell, sort yields by generation DESC so latest frame wins in dedup.
	orderClause := ` ORDER BY c.program_id,
		CASE c.state WHEN 'computing' THEN 0 WHEN 'declared' THEN 1 WHEN 'bottom' THEN 2 ELSE 3 END,
		c.name, c.id, COALESCE(yf.generation, 0) DESC, y.field_name`
	if progID != "" {
		rows, err = db.Query(q+" WHERE c.program_id = ?"+orderClause, progID)
	} else {
		rows, err = db.Query(q + orderClause)
	}
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()

	var cells []watchCell
	var cur *watchCell
	var seenFields map[string]bool // dedup yield field_names per cell (keep latest gen)
	programs := make(map[string][3]int) // [total, frozen, bottom]

	for rows.Next() {
		var cellID, prog, name, state, bodyType, body, piston sql.NullString
		var compSince sql.NullTime
		var fn, val sql.NullString
		var frozen, bottom sql.NullBool
		rows.Scan(&cellID, &prog, &name, &state, &bodyType, &body,
			&compSince, &piston,
			&fn, &val, &frozen, &bottom)

		if cur == nil || cur.id != cellID.String {
			if cur != nil {
				cells = append(cells, *cur)
			}
			cur = &watchCell{
				id:   cellID.String,
				prog: prog.String, name: name.String,
				state: state.String, bodyType: bodyType.String,
				body: body.String, assignedPiston: piston.String,
			}
			seenFields = make(map[string]bool)
			if compSince.Valid {
				t := compSince.Time
				cur.computingSince = &t
			}
			counts := programs[prog.String]
			counts[0]++
			if state.String == "frozen" {
				counts[1]++
			} else if state.String == "bottom" {
				counts[2]++
			}
			programs[prog.String] = counts
		}
		if fn.Valid && !seenFields[fn.String] {
			seenFields[fn.String] = true
			yi := watchYield{field: fn.String}
			if val.Valid {
				yi.value = val.String
			}
			if frozen.Valid {
				yi.frozen = frozen.Bool
			}
			if bottom.Valid {
				yi.bottom = bottom.Bool
			}
			cur.yields = append(cur.yields, yi)
		}
	}
	if cur != nil {
		cells = append(cells, *cur)
	}
	return cells, programs, rows.Err()
}

func (m watchModel) fetchCmd() tea.Cmd {
	return func() tea.Msg {
		cells, programs, err := queryWatchData(m.db, m.progID)
		return watchDataMsg{cells: cells, programs: programs, err: err}
	}
}

func (m watchModel) Init() tea.Cmd {
	return tea.Batch(m.fetchCmd(), m.spinner.Tick)
}

func (m watchModel) updateViewportSizes() watchModel {
	headerH := 2 // header + blank
	footerH := 1
	listH := m.height - headerH - footerH
	if m.showDetail {
		detailH := m.height / 3
		if detailH < 5 {
			detailH = 5
		}
		listH = m.height - headerH - footerH - detailH - 1 // -1 for separator
		m.detailVP.SetWidth(m.width)
		m.detailVP.SetHeight(detailH)
	}
	if listH < 3 {
		listH = 3
	}
	m.viewport.SetWidth(m.width)
	m.viewport.SetHeight(listH)
	return m
}

func (m watchModel) cursorMoved() (watchModel, tea.Cmd) {
	m.viewport.SetContent(m.renderContent())
	m.ensureCursorVisible()
	if m.showDetail {
		// Check if cursor is on a different cell
		items := m.navItems()
		newKey := ""
		if m.cursor >= 0 && m.cursor < len(items) && items[m.cursor].kind == navCell {
			c := m.cells[items[m.cursor].cellIdx]
			newKey = c.id
		}
		if newKey != m.detailCell {
			m.detailCell = newKey
			m.detail = nil
			if m.showDetail {
				m.detailVP.SetContent(m.renderDetail())
			}
			return m, m.fetchDetailCmd()
		}
	}
	return m, nil
}

func (m watchModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmds []tea.Cmd

	switch msg := msg.(type) {
	case watchDataMsg:
		m.fetching = false
		if msg.err != nil {
			m.err = msg.err
			m.retryCountdown = 4 // will retry in 4s (ticks every 2s, decrements by 2)
		} else {
			m.cells = msg.cells
			m.programs = msg.programs
			m.err = nil
			m.retryCountdown = 0
			m.lastFetch = time.Now()
			m.progOrder = m.progOrder[:0]
			seen := make(map[string]bool)
			for _, c := range m.cells {
				if !seen[c.prog] {
					m.progOrder = append(m.progOrder, c.prog)
					seen[c.prog] = true
				}
			}
			// Monotonicity check: alert if pending count increased
			var total, resolved int
			for _, counts := range m.programs {
				total += counts[0]
				resolved += counts[1] + counts[2] // frozen + bottom
			}
			pending := total - resolved
			if m.prevNonFrozen > 0 && pending > m.prevNonFrozen {
				m.nonFrozenAlert = true
			} else {
				m.nonFrozenAlert = false
			}
			m.prevNonFrozen = pending
		}
		m.clampCursor()
		if m.ready {
			m.viewport.SetContent(m.renderContent())
		}
		return m, tea.Tick(2*time.Second, func(t time.Time) tea.Msg { return tickRefresh{} })

	case detailDataMsg:
		if msg.cellKey == m.detailCell && msg.err == nil {
			m.detail = msg.detail
			m.detailVP.SetContent(m.renderDetail())
		}
		return m, nil

	case tickRefresh:
		if m.retryCountdown > 2 {
			m.retryCountdown -= 2
			if m.ready {
				m.viewport.SetContent(m.renderContent())
			}
			return m, tea.Tick(2*time.Second, func(t time.Time) tea.Msg { return tickRefresh{} })
		}
		m.retryCountdown = 0
		m.fetching = true
		return m, m.fetchCmd()

	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		if !m.ready {
			m.viewport = viewport.New(viewport.WithWidth(msg.Width), viewport.WithHeight(msg.Height-3))
			m.detailVP = viewport.New(viewport.WithWidth(msg.Width), viewport.WithHeight(0))
			m.viewport.SetContent(m.renderContent())
			m.ready = true
		}
		m = m.updateViewportSizes()
		return m, nil

	case tea.KeyPressMsg:
		// Help overlay intercepts all keys — any key dismisses it
		if m.showHelp {
			m.showHelp = false
			return m, nil
		}

		// Filter mode intercepts most keys
		if m.filtering {
			switch msg.String() {
			case "ctrl+c":
				return m, tea.Quit
			case "esc":
				m.filtering = false
				m.filterText = ""
				m.clampCursor()
				m.viewport.SetContent(m.renderContent())
				return m, nil
			case "backspace":
				if len(m.filterText) > 0 {
					m.filterText = m.filterText[:len(m.filterText)-1]
				}
				m.clampCursor()
				m.viewport.SetContent(m.renderContent())
				return m, nil
			case "enter":
				m.filtering = false
				// keep filterText active
				m.viewport.SetContent(m.renderContent())
				return m, nil
			default:
				r := msg.String()
				if len(r) == 1 {
					m.filterText += r
					m.clampCursor()
					m.viewport.SetContent(m.renderContent())
				}
				return m, nil
			}
		}

		items := m.navItems()
		switch msg.String() {
		case "ctrl+c", "q":
			return m, tea.Quit

		case "j", "down":
			m.stats.navCount++
			if m.cursor < len(items)-1 {
				m.cursor++
			}
			// Track cell visit
			if m.cursor < len(items) && items[m.cursor].kind == navCell {
				c := m.cells[items[m.cursor].cellIdx]
				m.stats.cellVisits[c.prog+"/"+c.name]++
			}
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "k", "up":
			m.stats.navCount++
			if m.cursor > 0 {
				m.cursor--
			}
			if m.cursor < len(items) && items[m.cursor].kind == navCell {
				c := m.cells[items[m.cursor].cellIdx]
				m.stats.cellVisits[c.prog+"/"+c.name]++
			}
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "enter", " ":
			if m.cursor >= 0 && m.cursor < len(items) {
				item := items[m.cursor]
				switch item.kind {
				case navProgram:
					m.stats.collapseCount++
					m.collapsed[item.prog] = !m.collapsed[item.prog]
					m.clampCursor()
				case navCell:
					m.stats.expandCount++
					c := m.cells[item.cellIdx]
					key := c.id
					m.expanded[key] = !m.expanded[key]
				}
				m.viewport.SetContent(m.renderContent())
				m.ensureCursorVisible()
			}
			return m, nil

		case "e":
			m.stats.expandAll++
			m.collapsed = make(map[string]bool)
			for _, c := range m.cells {
				m.expanded[c.id] = true
			}
			m.viewport.SetContent(m.renderContent())
			return m, nil

		case "c":
			m.stats.collapseAll++
			m.expanded = make(map[string]bool)
			m.viewport.SetContent(m.renderContent())
			return m, nil

		case "a":
			m.activeOnly = !m.activeOnly
			m.clampCursor()
			m.viewport.SetContent(m.renderContent())
			m.ensureCursorVisible()
			return m, nil

		case "d":
			m.showDetail = !m.showDetail
			if m.showDetail {
				m.stats.detailOpens++
				now := time.Now()
				m.stats.detailOpenedAt = &now
			} else if m.stats.detailOpenedAt != nil {
				m.stats.detailTime += time.Since(*m.stats.detailOpenedAt)
				m.stats.detailOpenedAt = nil
			}
			m = m.updateViewportSizes()
			if m.showDetail {
				m.detailVP.SetContent(m.renderDetail())
				return m, m.fetchDetailCmd()
			}
			return m, nil

		case "/":
			m.stats.searchCount++
			m.filtering = true
			m.filterText = ""
			return m, nil

		case "G":
			// Jump to bottom
			m.stats.navCount++
			m.cursor = len(items) - 1
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "g":
			// Jump to top
			m.stats.navCount++
			m.cursor = 0
			m2, cmd := m.cursorMoved()
			return m2, cmd

		case "tab":
			// Jump to next program header
			m.stats.navCount++
			for i := m.cursor + 1; i < len(items); i++ {
				if items[i].kind == navProgram {
					m.cursor = i
					m2, cmd := m.cursorMoved()
					return m2, cmd
				}
			}
			return m, nil

		case "shift+tab":
			// Jump to previous program header
			m.stats.navCount++
			for i := m.cursor - 1; i >= 0; i-- {
				if items[i].kind == navProgram {
					m.cursor = i
					m2, cmd := m.cursorMoved()
					return m2, cmd
				}
			}
			return m, nil

		case "esc":
			if m.showDetail {
				m.showDetail = false
				m = m.updateViewportSizes()
				return m, nil
			}
			if m.filterText != "" {
				m.filterText = ""
				m.clampCursor()
				m.viewport.SetContent(m.renderContent())
				return m, nil
			}

		case "?":
			m.showHelp = !m.showHelp
			return m, nil
		}
	}

	// Update spinner
	var cmd tea.Cmd
	m.spinner, cmd = m.spinner.Update(msg)
	if cmd != nil {
		cmds = append(cmds, cmd)
	}

	return m, tea.Batch(cmds...)
}

// ensureCursorVisible scrolls the viewport to keep the cursor line on screen.
func (m *watchModel) ensureCursorVisible() {
	cl := m.cursorLine()
	vpH := m.viewport.Height()
	if vpH <= 0 {
		return
	}
	off := m.viewport.YOffset()
	if cl < off {
		m.viewport.SetYOffset(cl)
	} else if cl >= off+vpH {
		m.viewport.SetYOffset(cl - vpH + 1)
	}
}

func (m watchModel) renderContent() string {
	var buf strings.Builder

	// Full terminal width for yields (no artificial cap)
	maxVal := m.width - 16
	if maxVal < 40 {
		maxVal = 40
	}

	if m.err != nil {
		retryInfo := ""
		if m.retryCountdown > 0 {
			retryInfo = fmt.Sprintf(" (retry in %ds)", m.retryCountdown)
		}
		buf.WriteString(errStyle.Render(fmt.Sprintf("  error: %v%s", m.err, retryInfo)))
		buf.WriteString("\n")
		if !m.lastFetch.IsZero() {
			buf.WriteString(footerStyle.Render(fmt.Sprintf("  last ok: %s", m.lastFetch.Format("15:04:05"))))
			buf.WriteString("\n")
		}
		buf.WriteString("\n")
	}

	items := m.navItems()

	for i, item := range items {
		isCursor := i == m.cursor
		prefix := "  "
		if isCursor {
			prefix = cursorStyle.Render("▸ ")
		}

		switch item.kind {
		case navProgram:
			counts := m.programs[item.prog]
			frozen, bottom, total := counts[1], counts[2], counts[0]
			done := frozen + bottom
			// Count computing cells for this program
			progComputing := 0
			for _, c := range m.cells {
				if c.prog == item.prog && c.state == "computing" {
					progComputing++
				}
			}
			filled := 8 * done / max(total, 1)
			barStr := barDoneStyle.Render(strings.Repeat("█", filled)) +
				barTodoStyle.Render(strings.Repeat("░", 8-filled))
			status := fmt.Sprintf("%s %d/%d", barStr, done, total)
			if bottom > 0 {
				status += bottomValStyle.Render(fmt.Sprintf(" ⊥%d", bottom))
			}
			if progComputing > 0 {
				status += pendValStyle.Render(fmt.Sprintf(" ⚡%d", progComputing))
			}
			if done == total && total > 0 {
				status = barDoneStyle.Render("████████") + " " + doneStyle.Render("DONE")
			}
			collapseIcon := "▾"
			if m.collapsed[item.prog] {
				collapseIcon = "▸"
			}
			buf.WriteString(prefix)
			buf.WriteString(progStyle.Render(fmt.Sprintf("━━ %s %s", collapseIcon, item.prog)))
			buf.WriteString(fmt.Sprintf(" %s ━━\n", status))

		case navCell:
			c := m.cells[item.cellIdx]
			cellKey := c.id
			isExpanded := m.expanded[cellKey]

			// Hard/soft-aware state icons
			var icon string
			switch c.state {
			case "frozen":
				icon = "■"
			case "bottom":
				icon = "⊥"
			case "computing":
				if c.bodyType == "soft" {
					icon = "◈"
				} else {
					icon = "▶"
				}
			case "declared":
				if c.bodyType == "soft" {
					icon = "◇"
				} else {
					icon = "○"
				}
			default:
				icon = "?"
			}
			if style, ok := iconStyles[c.state]; ok {
				icon = style.Render(icon)
			}

			arrow := "▸"
			if isExpanded {
				arrow = "▾"
			}
			if len(c.yields) == 0 {
				arrow = " "
			}

			// State label with elapsed time and piston for computing cells
			stateLabel := c.state
			if c.state == "computing" {
				// Check if all yields are actually frozen (anomaly)
				allFrozen := len(c.yields) > 0
				for _, y := range c.yields {
					if !y.frozen {
						allFrozen = false
						break
					}
				}
				if allFrozen {
					stateLabel = pendValStyle.Render("computing→frozen")
				} else if c.computingSince != nil {
					stateLabel += " " + fmtDuration(time.Since(*c.computingSince))
				}
				if c.assignedPiston != "" {
					stateLabel += detailDimStyle.Render(" (" + trunc(c.assignedPiston, 16) + ")")
				}
			}

			// Show short ID suffix when multiple cells share the same name
			displayName := c.name
			dupCount := 0
			for _, other := range m.cells {
				if other.prog == c.prog && other.name == c.name {
					dupCount++
				}
			}
			if dupCount > 1 {
				// Extract hash suffix from cell ID for disambiguation
				suffix := c.id
				if idx := strings.LastIndex(suffix, "-"); idx >= 0 && idx < len(suffix)-1 {
					suffix = suffix[idx+1:]
				}
				if len(suffix) > 6 {
					suffix = suffix[:6]
				}
				displayName = c.name + detailDimStyle.Render("#"+suffix)
			}

			line := fmt.Sprintf("%s  %s %s %-20s %s", prefix, arrow, icon, displayName, stateLabel)

			// Show yield info when collapsed
			if !isExpanded {
				if c.state == "frozen" && len(c.yields) == 1 && c.yields[0].value != "" {
					// Single frozen yield — show inline preview
					line += detailDimStyle.Render(" = ") + frozenValStyle.Render(trunc(c.yields[0].value, 40))
				} else if len(c.yields) > 0 {
					// Count frozen yields
					frozenY := 0
					for _, y := range c.yields {
						if y.frozen {
							frozenY++
						}
					}
					if frozenY == len(c.yields) {
						line += footerStyle.Render(fmt.Sprintf("  [%d yields ■]", len(c.yields)))
					} else if frozenY > 0 {
						line += footerStyle.Render(fmt.Sprintf("  [%d/%d yields]", frozenY, len(c.yields)))
					} else {
						line += footerStyle.Render(fmt.Sprintf("  [%d yields]", len(c.yields)))
					}
				}
			}
			buf.WriteString(line + "\n")

			if isExpanded {
				for _, y := range c.yields {
					if y.bottom {
						buf.WriteString(fmt.Sprintf("          %s = %s\n", y.field, bottomValStyle.Render("⊥")))
					} else if y.frozen && y.value != "" {
						buf.WriteString(fmt.Sprintf("          %s = %s\n", y.field, frozenValStyle.Render(trunc(y.value, maxVal))))
					} else if y.value != "" {
						buf.WriteString(fmt.Sprintf("          %s ~ %s\n", y.field, pendValStyle.Render(trunc(y.value, maxVal))))
					} else {
						buf.WriteString(fmt.Sprintf("          %s   %s\n", y.field, footerStyle.Render("—")))
					}
				}
			}
		}
	}

	if len(m.cells) == 0 && m.err == nil {
		buf.WriteString("\n")
		buf.WriteString(detailDimStyle.Render("  No programs loaded. Use ct pour <name> <file.cell> to load one."))
		buf.WriteString("\n")
	}

	return buf.String()
}

func (m watchModel) View() tea.View {
	if !m.ready {
		v := tea.NewView("  Loading...")
		v.AltScreen = true
		return v
	}

	// Help overlay
	if m.showHelp {
		help := headerStyle.Render("  ct watch — keybindings") + "\n\n"
		help += "  j / down       Move cursor down\n"
		help += "  k / up         Move cursor up\n"
		help += "  enter / space  Toggle expand/collapse on cell or program\n"
		help += "  e              Expand all programs and cells\n"
		help += "  c              Collapse all cells\n"
		help += "  tab            Jump to next program\n"
		help += "  shift+tab      Jump to previous program\n"
		help += "  g              Jump to top\n"
		help += "  G              Jump to bottom\n"
		help += "  d              Toggle detail pane\n"
		help += "  a              Toggle active-only (hide frozen/bottom)\n"
		help += "  /              Search / filter cells\n"
		help += "  esc            Close detail, clear filter\n"
		help += "  ?              Toggle this help\n"
		help += "  q / ctrl+c     Quit\n"
		help += "\n" + footerStyle.Render("  Press any key to dismiss")
		v := tea.NewView(help)
		v.AltScreen = true
		return v
	}

	var buf strings.Builder

	// Header with aggregate stats
	now := time.Now().Format("15:04:05")
	spin := ""
	if m.fetching {
		spin = " " + m.spinner.View()
	}
	// Count aggregate cell states
	var totalCells, frozenCells, bottomCells, computingCells int
	for _, counts := range m.programs {
		totalCells += counts[0]
		frozenCells += counts[1]
		bottomCells += counts[2]
	}
	for _, c := range m.cells {
		if c.state == "computing" {
			computingCells++
		}
	}
	resolvedCells := frozenCells + bottomCells
	pendingCells := totalCells - resolvedCells
	statsStr := fmt.Sprintf("%d/%d", resolvedCells, totalCells)
	if bottomCells > 0 {
		statsStr += bottomValStyle.Render(fmt.Sprintf(" ⊥%d", bottomCells))
	}
	if pendingCells > 0 {
		nfStr := fmt.Sprintf(" %d pending", pendingCells)
		if m.nonFrozenAlert {
			statsStr += errStyle.Render(nfStr + " ▲")
		} else {
			statsStr += pendValStyle.Render(nfStr)
		}
	}
	if computingCells > 0 {
		statsStr += fmt.Sprintf(" %s", pendValStyle.Render(fmt.Sprintf("⚡%d", computingCells)))
	}
	header := headerStyle.Render(fmt.Sprintf("  ct watch  ·  %s  ·  %d programs  %s", now, len(m.programs), statsStr))
	buf.WriteString(header)
	buf.WriteString(spin)
	if m.activeOnly {
		buf.WriteString("  " + pendValStyle.Render("[active only]"))
	}

	// Filter bar
	if m.filtering {
		buf.WriteString("  " + detailLabelStyle.Render("/") + m.filterText + cursorStyle.Render("▎"))
	} else if m.filterText != "" {
		buf.WriteString("  " + detailDimStyle.Render("filter: "+m.filterText+" (esc to clear)"))
	}
	buf.WriteString("\n")

	// Cell list viewport
	buf.WriteString(m.viewport.View())
	buf.WriteString("\n")

	// Detail pane (if enabled)
	if m.showDetail {
		label := " DETAIL "
		padLen := m.width - len(label)
		if padLen < 0 {
			padLen = 0
		}
		left := padLen / 2
		right := padLen - left
		sep := strings.Repeat("─", left) + label + strings.Repeat("─", right)
		buf.WriteString(detailDimStyle.Render(sep) + "\n")
		buf.WriteString(m.detailVP.View())
	}

	// Footer
	detailKey := "d detail"
	if m.showDetail {
		detailKey = "d hide"
	}
	activeKey := "a active"
	if m.activeOnly {
		activeKey = "a all"
	}
	buf.WriteString(footerStyle.Render(fmt.Sprintf("  j/k nav · tab/S-tab prog · g/G top/bot · enter toggle · e expand · c collapse · %s · %s · / search · esc back · ? help · q quit", activeKey, detailKey)))

	v := tea.NewView(buf.String())
	v.AltScreen = true
	return v
}

func cmdWatch(db *sql.DB, progID string) {
	s := spinner.New()
	model := watchModel{
		db:        db,
		progID:    progID,
		collapsed: make(map[string]bool),
		expanded:  make(map[string]bool),
		spinner:   s,
		stats: watchStats{
			sessionStart: time.Now(),
			cellVisits:   make(map[string]int),
		},
	}
	p := tea.NewProgram(model)
	finalModel, err := p.Run()
	if err != nil {
		fmt.Fprintf(os.Stderr, "watch error: %v\n", err)
		os.Exit(1)
	}

	// Print session stats
	if m, ok := finalModel.(watchModel); ok {
		m.printStats()
	}
}

func (m watchModel) printStats() {
	st := m.stats
	dur := time.Since(st.sessionStart)

	// Finalize detail time if still open
	if st.detailOpenedAt != nil {
		st.detailTime += time.Since(*st.detailOpenedAt)
	}

	fmt.Fprintf(os.Stderr, "\n")
	fmt.Fprintf(os.Stderr, "  ct watch session: %s\n", fmtDuration(dur))
	fmt.Fprintf(os.Stderr, "  nav: %d · expand: %d · collapse: %d · expand-all: %d · collapse-all: %d\n",
		st.navCount, st.expandCount, st.collapseCount, st.expandAll, st.collapseAll)
	fmt.Fprintf(os.Stderr, "  detail: %d opens (%s) · search: %d\n",
		st.detailOpens, fmtDuration(st.detailTime), st.searchCount)

	// Top visited cells
	if len(st.cellVisits) > 0 {
		type kv struct {
			key   string
			count int
		}
		var sorted []kv
		for k, v := range st.cellVisits {
			sorted = append(sorted, kv{k, v})
		}
		// Simple insertion sort (small N)
		for i := 1; i < len(sorted); i++ {
			for j := i; j > 0 && sorted[j].count > sorted[j-1].count; j-- {
				sorted[j], sorted[j-1] = sorted[j-1], sorted[j]
			}
		}
		n := len(sorted)
		if n > 5 {
			n = 5
		}
		fmt.Fprintf(os.Stderr, "  most visited: ")
		for i := 0; i < n; i++ {
			if i > 0 {
				fmt.Fprintf(os.Stderr, ", ")
			}
			fmt.Fprintf(os.Stderr, "%s (%d)", sorted[i].key, sorted[i].count)
		}
		fmt.Fprintf(os.Stderr, "\n")
	}
	fmt.Fprintf(os.Stderr, "\n")
}
