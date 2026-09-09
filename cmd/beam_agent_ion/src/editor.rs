use unicode_segmentation::UnicodeSegmentation;

#[derive(Default)]
pub struct Editor {
    pub text: String,
    pub cursor: usize,
}

pub fn clean(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect::<String>()
        .replace('\t', "    ")
}

impl Editor {
    pub fn set(&mut self, text: &str) {
        self.text = clean(text);
        self.cursor = self.text.len();
    }
    pub fn insert(&mut self, text: &str) {
        let text = clean(text);
        if self.text.len() + text.len() <= 100_000 {
            self.text.insert_str(self.cursor, &text);
            self.cursor += text.len();
        }
    }
    pub fn left(&mut self) {
        self.cursor = self.text[..self.cursor]
            .grapheme_indices(true)
            .next_back()
            .map_or(0, |(i, _)| i);
    }
    pub fn right(&mut self) {
        self.cursor += self.text[self.cursor..]
            .graphemes(true)
            .next()
            .map_or(0, str::len);
    }
    pub fn backspace(&mut self) {
        let end = self.cursor;
        self.left();
        self.text.replace_range(self.cursor..end, "");
    }
    pub fn delete(&mut self) {
        let start = self.cursor;
        self.right();
        self.text.replace_range(start..self.cursor, "");
        self.cursor = start;
    }
    pub fn home(&mut self) {
        self.cursor = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
    }
    pub fn end(&mut self) {
        self.cursor += self.text[self.cursor..]
            .find('\n')
            .unwrap_or(self.text.len() - self.cursor);
    }
    pub fn vertical(&mut self, down: bool) {
        let start = self.text[..self.cursor].rfind('\n').map_or(0, |i| i + 1);
        let col = self.text[start..self.cursor].graphemes(true).count();
        let target = if down {
            self.text[self.cursor..]
                .find('\n')
                .map(|i| self.cursor + i + 1)
        } else if start > 0 {
            Some(self.text[..start - 1].rfind('\n').map_or(0, |i| i + 1))
        } else {
            None
        };
        if let Some(target) = target {
            let line = self.text[target..].split('\n').next().unwrap_or("");
            self.cursor = target + line.graphemes(true).take(col).map(str::len).sum::<usize>();
        }
    }
    pub fn reference(&self) -> Option<(usize, &str)> {
        let prefix = &self.text[..self.cursor];
        let start = prefix.rfind('@')?;
        if start > 0 && !prefix[..start].chars().last()?.is_whitespace() {
            return None;
        }
        let query = &prefix[start + 1..];
        if query.contains(['\n', '\t', '"']) {
            return None;
        }
        Some((start, query))
    }
    pub fn insert_reference(&mut self, path: &str) {
        if let Some((start, _)) = self.reference() {
            let reference = if path.contains(char::is_whitespace) {
                format!("@\"{path}\" ")
            } else {
                format!("@{path} ")
            };
            self.text.replace_range(start..self.cursor, &reference);
            self.cursor = start + reference.len();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unicode_editing_and_multiline() {
        let mut e = Editor::default();
        e.insert("a👩‍💻e\u{301}\n世界");
        e.backspace();
        assert!(e.text.ends_with('世'));
        e.home();
        e.left();
        e.backspace();
        assert_eq!(e.text, "a👩‍💻\n世");
        e.home();
        e.delete();
        assert_eq!(e.text, "👩‍💻\n世");
    }
    #[test]
    fn references_do_not_submit_and_preserve_suffix() {
        let mut e = Editor::default();
        e.set("read @my then fix");
        e.cursor = 8;
        e.insert_reference("my folder/a.ex");
        assert_eq!(e.text, "read @\"my folder/a.ex\"  then fix");
        e.set("email@domain");
        assert!(e.reference().is_none());
    }
    #[test]
    fn paste_cannot_inject_terminal_controls() {
        assert_eq!(clean("a\u{1b}[31m\r\nb"), "a[31m\nb");
    }
}
