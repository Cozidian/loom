// Renders LLM-authored markdown (headings, emphasis, code, tables, lists,
// block quotes, links, rules) into styled, word-wrapped ratatui lines for a
// fixed-width terminal pane. Tables are the main reason this exists: rendered
// as raw text they wrap mid-row and lose all alignment, which is the exact
// "broken table" problem this module fixes.
use pulldown_cmark::{Alignment, Event, HeadingLevel, Options, Parser, Tag, TagEnd};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use unicode_width::UnicodeWidthStr;

#[derive(Clone, Copy)]
pub struct Palette {
    pub text: Color,
    pub muted: Color,
    pub heading: Color,
    pub code: Color,
    pub link: Color,
    pub rule: Color,
}

/// A single wrappable unit: either a run of non-space text carrying its own
/// style, or a forced line break (from a markdown hard break).
enum Word {
    Text(String, Style),
    Break,
}

struct ListFrame {
    ordered: bool,
    next_index: u64,
}

pub struct Renderer<'a> {
    width: usize,
    palette: &'a Palette,
    lines: Vec<Line<'static>>,
    words: Vec<Word>,
    bold: u32,
    italic: u32,
    strike: u32,
    code: u32,
    link: u32,
    heading: u32,
    link_url: Vec<String>,
    list_stack: Vec<ListFrame>,
    task_marker: Option<bool>,
    quote_depth: usize,
    code_lang: Option<String>,
    code_lines: Vec<String>,
    code_current: String,
    in_code_block: bool,
    table_alignments: Vec<Alignment>,
    table_rows: Vec<Vec<String>>,
    table_header_rows: usize,
    in_table_cell: bool,
    cell_buffer: String,
    blank_before_next: bool,
}

pub fn render(input: &str, width: u16, palette: &Palette) -> Vec<Line<'static>> {
    let mut renderer = Renderer::new(width, palette);
    let options =
        Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH | Options::ENABLE_TASKLISTS;
    for event in Parser::new_ext(input, options) {
        renderer.event(event);
    }
    renderer.finish()
}

impl<'a> Renderer<'a> {
    fn new(width: u16, palette: &'a Palette) -> Self {
        Renderer {
            width: usize::from(width).max(4),
            palette,
            lines: Vec::new(),
            words: Vec::new(),
            bold: 0,
            italic: 0,
            heading: 0,
            strike: 0,
            code: 0,
            link: 0,
            link_url: Vec::new(),
            list_stack: Vec::new(),
            task_marker: None,
            quote_depth: 0,
            code_lang: None,
            code_lines: Vec::new(),
            code_current: String::new(),
            in_code_block: false,
            table_alignments: Vec::new(),
            table_rows: Vec::new(),
            table_header_rows: 0,
            in_table_cell: false,
            cell_buffer: String::new(),
            blank_before_next: false,
        }
    }

    fn event(&mut self, event: Event<'_>) {
        match event {
            Event::Start(tag) => self.start(tag),
            Event::End(tag) => self.end(tag),
            Event::Text(text) => self.text(&text),
            Event::Code(text) => {
                self.code += 1;
                self.text(&text);
                self.code -= 1;
            }
            Event::SoftBreak => self.words.push(Word::Text(" ".into(), self.style())),
            Event::HardBreak => self.words.push(Word::Break),
            Event::Rule => {
                self.flush_paragraph();
                self.blank();
                self.lines.push(Line::styled(
                    "─".repeat(self.width),
                    Style::default().fg(self.palette.rule),
                ));
                self.blank_before_next = true;
            }
            Event::TaskListMarker(checked) => self.task_marker = Some(checked),
            Event::InlineHtml(_) | Event::Html(_) | Event::FootnoteReference(_) => {}
            Event::InlineMath(text) | Event::DisplayMath(text) => self.text(&text),
        }
    }

    fn start(&mut self, tag: Tag<'_>) {
        match tag {
            Tag::Paragraph => {}
            Tag::Heading { .. } => {
                self.flush_paragraph();
                self.blank();
                self.bold += 1;
                self.heading += 1;
            }
            Tag::Strong => self.bold += 1,
            Tag::Emphasis => self.italic += 1,
            Tag::Strikethrough => self.strike += 1,
            Tag::BlockQuote(_) => {
                self.flush_paragraph();
                self.quote_depth += 1;
            }
            Tag::CodeBlock(kind) => {
                self.flush_paragraph();
                self.blank();
                self.in_code_block = true;
                self.code_lang = match kind {
                    pulldown_cmark::CodeBlockKind::Fenced(lang) if !lang.is_empty() => {
                        Some(lang.to_string())
                    }
                    _ => None,
                };
            }
            Tag::List(start) => {
                self.flush_paragraph();
                self.list_stack.push(ListFrame {
                    ordered: start.is_some(),
                    next_index: start.unwrap_or(1),
                });
            }
            Tag::Item => self.flush_paragraph(),
            Tag::Link { dest_url, .. } => {
                self.link += 1;
                self.link_url.push(dest_url.to_string());
            }
            Tag::Table(alignments) => {
                self.flush_paragraph();
                self.blank();
                self.table_alignments = alignments;
                self.table_rows.clear();
                self.table_header_rows = 0;
            }
            Tag::TableHead => self.table_rows.push(Vec::new()),
            Tag::TableRow => self.table_rows.push(Vec::new()),
            Tag::TableCell => {
                self.in_table_cell = true;
                self.cell_buffer.clear();
            }
            Tag::Image { .. }
            | Tag::HtmlBlock
            | Tag::FootnoteDefinition(_)
            | Tag::DefinitionList
            | Tag::DefinitionListTitle
            | Tag::DefinitionListDefinition
            | Tag::Superscript
            | Tag::Subscript
            | Tag::MetadataBlock(_) => {}
        }
    }

    fn end(&mut self, tag: TagEnd) {
        match tag {
            TagEnd::Paragraph => self.flush_paragraph(),
            TagEnd::Heading(level) => {
                self.bold -= 1;
                self.heading -= 1;
                let underline = matches!(level, HeadingLevel::H1);
                self.flush_block(underline);
                self.blank_before_next = true;
            }
            TagEnd::Strong => self.bold -= 1,
            TagEnd::Emphasis => self.italic -= 1,
            TagEnd::Strikethrough => self.strike -= 1,
            TagEnd::BlockQuote(_) => {
                self.flush_paragraph();
                self.quote_depth = self.quote_depth.saturating_sub(1);
            }
            TagEnd::CodeBlock => {
                self.in_code_block = false;
                if !self.code_current.is_empty() {
                    self.code_lines.push(std::mem::take(&mut self.code_current));
                }
                self.flush_code_block();
                self.blank_before_next = true;
            }
            TagEnd::List(_) => {
                self.list_stack.pop();
                self.blank_before_next = true;
            }
            TagEnd::Item => {
                self.flush_paragraph();
                if let Some(frame) = self.list_stack.last_mut()
                    && frame.ordered
                {
                    frame.next_index += 1;
                }
            }
            TagEnd::Link => {
                self.link -= 1;
                let url = self.link_url.pop().unwrap_or_default();
                if !url.is_empty() {
                    self.words.push(Word::Text(
                        format!(" ({url})"),
                        Style::default().fg(self.palette.muted),
                    ));
                }
            }
            TagEnd::Table => {
                let rows = std::mem::take(&mut self.table_rows);
                let alignments = std::mem::take(&mut self.table_alignments);
                self.render_table(rows, &alignments);
                self.blank_before_next = true;
            }
            TagEnd::TableHead => self.table_header_rows = 1,
            TagEnd::TableRow => {}
            TagEnd::TableCell => {
                self.in_table_cell = false;
                if let Some(row) = self.table_rows.last_mut() {
                    row.push(std::mem::take(&mut self.cell_buffer));
                }
            }
            TagEnd::Image
            | TagEnd::HtmlBlock
            | TagEnd::FootnoteDefinition
            | TagEnd::DefinitionList
            | TagEnd::DefinitionListTitle
            | TagEnd::DefinitionListDefinition
            | TagEnd::Superscript
            | TagEnd::Subscript
            | TagEnd::MetadataBlock(_) => {}
        }
    }

    fn text(&mut self, raw: &str) {
        if self.in_table_cell {
            self.cell_buffer.push_str(raw);
            return;
        }
        if self.in_code_block {
            for (index, part) in raw.split('\n').enumerate() {
                if index > 0 {
                    self.code_lines.push(std::mem::take(&mut self.code_current));
                }
                self.code_current.push_str(part);
            }
            return;
        }
        let style = self.style();
        for (index, word) in raw.split_whitespace().enumerate() {
            if index > 0 {
                self.words.push(Word::Text(" ".into(), style));
            }
            self.words.push(Word::Text(word.to_string(), style));
        }
        if raw.starts_with(char::is_whitespace) && !raw.is_empty() {
            self.words.push(Word::Text(" ".into(), style));
        }
    }

    fn style(&self) -> Style {
        let mut style = Style::default();
        style = style.fg(if self.heading > 0 {
            self.palette.heading
        } else if self.code > 0 {
            self.palette.code
        } else if self.link > 0 {
            self.palette.link
        } else {
            self.palette.text
        });
        if self.bold > 0 {
            style = style.add_modifier(Modifier::BOLD);
        }
        if self.italic > 0 {
            style = style.add_modifier(Modifier::ITALIC);
        }
        if self.strike > 0 {
            style = style.add_modifier(Modifier::CROSSED_OUT);
        }
        if self.link > 0 {
            style = style.add_modifier(Modifier::UNDERLINED);
        }
        style
    }

    fn blank(&mut self) {
        if !self.lines.is_empty() {
            self.blank_before_next = true;
        }
    }

    fn flush_paragraph(&mut self) {
        self.flush_block(false);
    }

    /// Wraps the accumulated words for the current block into lines, applying
    /// list/quote prefixes and an optional underline (used for H1 only).
    fn flush_block(&mut self, underline: bool) {
        if self.words.is_empty() {
            return;
        }
        let words = std::mem::take(&mut self.words);

        let (prefix, cont_prefix, prefix_style) = self.block_prefix();
        let available = self.width.saturating_sub(prefix.chars().count()).max(1);

        if self.blank_before_next {
            self.lines.push(Line::default());
            self.blank_before_next = false;
        }

        let mut wrapped = wrap_words(&words, available);
        if underline {
            for line in &mut wrapped {
                for span in &mut line.spans {
                    span.style = span.style.add_modifier(Modifier::UNDERLINED);
                }
            }
        }
        for (index, mut line) in wrapped.into_iter().enumerate() {
            let (marker, marker_style) = if index == 0 {
                (prefix.clone(), prefix_style)
            } else {
                (cont_prefix.clone(), prefix_style)
            };
            if !marker.is_empty() {
                let mut spans = vec![Span::styled(marker, marker_style)];
                spans.append(&mut line.spans);
                line.spans = spans;
            }
            self.lines.push(line);
        }
    }

    fn block_prefix(&mut self) -> (String, String, Style) {
        let quote = "▏ ".repeat(self.quote_depth);
        let quote_style = Style::default().fg(self.palette.muted);

        let depth = self.list_stack.len();
        if let Some(frame) = self.list_stack.last_mut() {
            let indent = "  ".repeat(depth.saturating_sub(1));
            let marker = if let Some(checked) = self.task_marker.take() {
                if checked { "[x] " } else { "[ ] " }.to_string()
            } else if frame.ordered {
                format!("{}. ", frame.next_index)
            } else {
                "• ".to_string()
            };
            let cont = " ".repeat(marker.chars().count());
            return (
                format!("{quote}{indent}{marker}"),
                format!("{quote}{indent}{cont}"),
                quote_style,
            );
        }

        (quote.clone(), quote, quote_style)
    }

    fn flush_code_block(&mut self) {
        let lines = std::mem::take(&mut self.code_lines);
        let label = self.code_lang.take();
        let border_style = Style::default().fg(self.palette.muted);
        let code_style = Style::default().fg(self.palette.code);

        if self.blank_before_next {
            self.lines.push(Line::default());
            self.blank_before_next = false;
        }
        let header = match label {
            Some(lang) => format!("┌─ {lang}"),
            None => "┌─ code".to_string(),
        };
        self.lines.push(Line::styled(header, border_style));
        for line in lines {
            self.lines.push(Line::styled(line, code_style));
        }
        self.lines
            .push(Line::styled("└─".to_string(), border_style));
    }

    fn render_table(&mut self, rows: Vec<Vec<String>>, alignments: &[Alignment]) {
        if rows.is_empty() {
            return;
        }
        let columns = rows.iter().map(Vec::len).max().unwrap_or(0);
        if columns == 0 {
            return;
        }

        let mut widths = vec![0usize; columns];
        for row in &rows {
            for (index, cell) in row.iter().enumerate() {
                widths[index] = widths[index].max(cell.width());
            }
        }

        // Shrink proportionally if the table is wider than the pane, leaving
        // every column at least a few characters instead of overflowing.
        let separators = columns.saturating_sub(1) * 3 + 4;
        let content_width: usize = widths.iter().sum();
        let budget = self.width.saturating_sub(separators);
        if content_width > budget && content_width > 0 {
            for width in &mut widths {
                *width = (*width * budget / content_width).max(3);
            }
        }

        let rule_style = Style::default().fg(self.palette.rule);
        let text_style = Style::default().fg(self.palette.text);
        let header_style = text_style.add_modifier(Modifier::BOLD);

        if self.blank_before_next {
            self.lines.push(Line::default());
            self.blank_before_next = false;
        }
        self.lines
            .push(border_line(&widths, '┌', '┬', '┐', rule_style));
        for (row_index, row) in rows.iter().enumerate() {
            let is_header = row_index < self.table_header_rows;
            self.lines.push(row_line(
                row,
                &widths,
                alignments,
                if is_header { header_style } else { text_style },
                rule_style,
            ));
            if is_header {
                self.lines
                    .push(border_line(&widths, '├', '┼', '┤', rule_style));
            }
        }
        self.lines
            .push(border_line(&widths, '└', '┴', '┘', rule_style));
    }

    fn finish(mut self) -> Vec<Line<'static>> {
        self.flush_paragraph();
        self.lines
    }
}

fn wrap_words(words: &[Word], width: usize) -> Vec<Line<'static>> {
    let mut lines = Vec::new();
    let mut current: Vec<Span<'static>> = Vec::new();
    let mut current_width = 0usize;
    let mut pending_space = false;

    for word in words {
        match word {
            Word::Break => {
                lines.push(Line::from(std::mem::take(&mut current)));
                current_width = 0;
                pending_space = false;
            }
            Word::Text(text, style) => {
                if text == " " {
                    pending_space = !current.is_empty();
                    continue;
                }
                let word_width = text.width();
                let extra = if pending_space { 1 } else { 0 };
                if current_width + extra + word_width > width && !current.is_empty() {
                    lines.push(Line::from(std::mem::take(&mut current)));
                    current_width = 0;
                    pending_space = false;
                }
                if pending_space {
                    current.push(Span::raw(" "));
                    current_width += 1;
                    pending_space = false;
                }
                current.push(Span::styled(text.clone(), *style));
                current_width += word_width;
            }
        }
    }
    if !current.is_empty() {
        lines.push(Line::from(current));
    }
    if lines.is_empty() {
        lines.push(Line::default());
    }
    lines
}

fn border_line(
    widths: &[usize],
    left: char,
    mid: char,
    right: char,
    style: Style,
) -> Line<'static> {
    let mut text = String::new();
    text.push(left);
    for (index, width) in widths.iter().enumerate() {
        if index > 0 {
            text.push(mid);
        }
        text.push_str(&"─".repeat(width + 2));
    }
    text.push(right);
    Line::styled(text, style)
}

fn row_line(
    cells: &[String],
    widths: &[usize],
    alignments: &[Alignment],
    text_style: Style,
    rule_style: Style,
) -> Line<'static> {
    let mut spans = vec![Span::styled("│".to_string(), rule_style)];
    for (index, width) in widths.iter().enumerate() {
        let empty = String::new();
        let cell = cells.get(index).unwrap_or(&empty);
        let truncated = truncate(cell, *width);
        let pad = width.saturating_sub(truncated.width());
        let alignment = alignments.get(index).copied().unwrap_or(Alignment::None);
        let (left, right) = match alignment {
            Alignment::Right => (pad, 0),
            Alignment::Center => (pad / 2, pad - pad / 2),
            _ => (0, pad),
        };
        spans.push(Span::styled(
            format!(" {}{}{} ", " ".repeat(left), truncated, " ".repeat(right)),
            text_style,
        ));
        spans.push(Span::styled("│".to_string(), rule_style));
    }
    Line::from(spans)
}

fn truncate(text: &str, width: usize) -> String {
    if text.width() <= width {
        return text.to_string();
    }
    let mut out = String::new();
    let mut used = 0;
    for grapheme in text.chars() {
        let w = grapheme.to_string().width();
        if used + w > width.saturating_sub(1) {
            out.push('…');
            break;
        }
        out.push(grapheme);
        used += w;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const PALETTE: Palette = Palette {
        text: Color::White,
        muted: Color::Gray,
        heading: Color::Yellow,
        code: Color::Cyan,
        link: Color::Blue,
        rule: Color::Gray,
    };

    fn plain(line: &Line<'static>) -> String {
        line.spans.iter().map(|s| s.content.as_ref()).collect()
    }

    fn text(input: &str, width: u16) -> Vec<String> {
        render(input, width, &PALETTE).iter().map(plain).collect()
    }

    fn find<'a>(lines: &'a [String], needle: &str) -> &'a str {
        lines
            .iter()
            .find(|line| line.contains(needle))
            .unwrap_or_else(|| panic!("no line contains {needle:?}; got {lines:?}"))
    }

    #[test]
    fn heading_is_bold_underlined_and_uses_heading_color() {
        let rendered = render("# Title", 40, &PALETTE);
        let line = rendered
            .iter()
            .find(|line| plain(line).contains("Title"))
            .expect("heading line");
        let span = line
            .spans
            .iter()
            .find(|s| s.content.contains("Title"))
            .unwrap();
        assert!(span.style.add_modifier.contains(Modifier::BOLD));
        assert!(span.style.add_modifier.contains(Modifier::UNDERLINED));
        assert_eq!(span.style.fg, Some(PALETTE.heading));
    }

    #[test]
    fn nested_heading_is_not_underlined() {
        let rendered = render("## Subtitle", 40, &PALETTE);
        let line = rendered
            .iter()
            .find(|line| plain(line).contains("Subtitle"))
            .expect("heading line");
        let span = line
            .spans
            .iter()
            .find(|s| s.content.contains("Subtitle"))
            .unwrap();
        assert!(!span.style.add_modifier.contains(Modifier::UNDERLINED));
        assert_eq!(span.style.fg, Some(PALETTE.heading));
    }

    #[test]
    fn emphasis_modifiers_are_applied_and_do_not_leak() {
        let rendered = render("plain **bold** *italic* ~~strike~~ end", 80, &PALETTE);
        let line = &rendered[0];
        let get = |needle: &str| {
            line.spans
                .iter()
                .find(|s| s.content.as_ref() == needle)
                .unwrap_or_else(|| panic!("missing span {needle:?} in {line:?}"))
        };
        assert!(get("bold").style.add_modifier.contains(Modifier::BOLD));
        assert!(get("italic").style.add_modifier.contains(Modifier::ITALIC));
        assert!(
            get("strike")
                .style
                .add_modifier
                .contains(Modifier::CROSSED_OUT)
        );
        assert!(!get("plain").style.add_modifier.contains(Modifier::BOLD));
        assert!(!get("end").style.add_modifier.contains(Modifier::ITALIC));
    }

    #[test]
    fn inline_code_uses_code_color() {
        let rendered = render("run `mix test` now", 80, &PALETTE);
        let line = &rendered[0];
        let span = line
            .spans
            .iter()
            .find(|s| s.content.as_ref() == "mix")
            .unwrap();
        assert_eq!(span.style.fg, Some(PALETTE.code));
    }

    #[test]
    fn fenced_code_block_keeps_language_header_and_body_lines() {
        let rendered = text("```elixir\nRuntime.connect(:x)\n```", 40);
        assert!(find(&rendered, "┌─").contains("elixir"));
        find(&rendered, "Runtime.connect(:x)");
        find(&rendered, "└─");
    }

    #[test]
    fn code_block_without_language_gets_generic_header() {
        let rendered = text("```\nplain\n```", 40);
        assert!(find(&rendered, "┌─").contains("code"));
    }

    #[test]
    fn task_list_renders_checked_and_unchecked_markers() {
        let rendered = text("- [x] done\n- [ ] todo", 40);
        assert!(find(&rendered, "done").starts_with("[x]"));
        assert!(find(&rendered, "todo").starts_with("[ ]"));
    }

    #[test]
    fn ordered_list_numbers_each_item() {
        let rendered = text("1. first\n2. second\n3. third", 40);
        assert!(find(&rendered, "first").starts_with("1."));
        assert!(find(&rendered, "second").starts_with("2."));
        assert!(find(&rendered, "third").starts_with("3."));
    }

    #[test]
    fn unordered_list_uses_bullet_marker() {
        let rendered = text("- one\n- two", 40);
        assert!(find(&rendered, "one").starts_with("• "));
    }

    #[test]
    fn blockquote_gets_quote_prefix() {
        let rendered = text("> quoted text", 40);
        assert!(find(&rendered, "quoted text").starts_with("▏"));
    }

    #[test]
    fn link_keeps_label_and_appends_url() {
        let rendered = render("[Loom](https://example.com/loom)", 80, &PALETTE);
        let line = &rendered[0];
        let label = line
            .spans
            .iter()
            .find(|s| s.content.as_ref() == "Loom")
            .unwrap();
        assert_eq!(label.style.fg, Some(PALETTE.link));
        assert!(label.style.add_modifier.contains(Modifier::UNDERLINED));
        let flat = plain(line);
        assert!(flat.contains("https://example.com/loom"));
    }

    #[test]
    fn horizontal_rule_spans_full_width() {
        let rendered = text("above\n\n---\n\nbelow", 12);
        let rule = find(&rendered, "─");
        assert_eq!(rule.chars().count(), 12);
    }

    #[test]
    fn table_renders_aligned_columns_with_borders() {
        let rendered = text(
            "| Name | Score |\n| :--- | ----: |\n| Alice | 10 |\n| Bob | 5 |",
            40,
        );
        assert!(rendered.iter().any(|l| l.contains('┌')));
        assert!(rendered.iter().any(|l| l.contains('┼')));
        assert!(rendered.iter().any(|l| l.contains('└')));
        find(&rendered, "Alice");
        find(&rendered, "Bob");
        let header = find(&rendered, "Name");
        assert!(header.contains('│'));
    }

    #[test]
    fn table_right_alignment_pads_on_the_left() {
        let rendered = text("| Score |\n| ----: |\n| 5 |\n| 100 |", 40);
        let row = find(&rendered, "5 ");
        assert!(row.contains("  5"));
    }

    #[test]
    fn wide_table_shrinks_to_fit_pane_width() {
        let long = "x".repeat(200);
        let rendered = text(&format!("| Col |\n| --- |\n| {long} |"), 40);
        for line in &rendered {
            assert!(
                line.chars().count() <= 40,
                "line exceeds pane width: {line:?}"
            );
        }
    }

    #[test]
    fn empty_input_produces_no_visible_content() {
        let rendered = render("", 40, &PALETTE);
        let flat: String = rendered.iter().map(plain).collect();
        assert!(flat.trim().is_empty());
    }

    #[test]
    fn plain_paragraph_word_wraps_to_width() {
        let rendered = text("one two three four five six seven eight", 10);
        for line in &rendered {
            assert!(line.chars().count() <= 10, "line too wide: {line:?}");
        }
        assert!(rendered.len() > 1);
    }
}
