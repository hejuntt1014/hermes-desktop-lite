use std::{
    collections::{HashMap, HashSet},
    ops::Range,
    sync::LazyLock,
};

use gpui::SharedString;
use icu_normalizer::ComposingNormalizerBorrowed;
use markdown::{
    ParseOptions,
    mdast::{AlignKind, Node, Table},
    to_mdast,
};
use regex::Regex;
use url::Url;

use crate::app::remote_refs::{
    collect_definitions, gateway_path, scoped_path, split_markdown_destination,
};

pub(super) struct DocumentPreview {
    pub sections: Vec<DocumentSection>,
    pub links: Vec<DocumentLink>,
    headings: HashMap<String, usize>,
}

impl DocumentPreview {
    pub fn heading_index(&self, fragment: &str) -> Option<usize> {
        let fragment = ComposingNormalizerBorrowed::new_nfc().normalize(fragment);
        self.headings
            .get(fragment.as_ref())
            .or_else(|| self.headings.get(&heading_slug(&fragment)))
            .copied()
    }
}

pub(super) struct DocumentLink {
    pub target: DocumentTarget,
    pub label: String,
}

#[derive(Clone, PartialEq, Eq, Hash)]
pub(super) enum DocumentTarget {
    Heading(String),
    File {
        path: String,
        fragment: Option<String>,
    },
}

impl DocumentTarget {
    pub fn location(&self) -> String {
        match self {
            Self::Heading(fragment) => format!("#{fragment}"),
            Self::File {
                path,
                fragment: Some(fragment),
            } => format!("{path}#{fragment}"),
            Self::File {
                path,
                fragment: None,
            } => path.clone(),
        }
    }
}

pub(super) enum DocumentSection {
    Markdown(SharedString),
    Table(DocumentTable),
    Heading {
        depth: u8,
        label: SharedString,
        content: SharedString,
    },
}

pub(super) struct DocumentTable {
    pub align: Vec<AlignKind>,
    pub rows: Vec<Vec<InlineContent>>,
}

pub(super) enum InlineContent {
    Text(SharedString),
    Markdown(SharedString),
}

struct Rewrite {
    range: Range<usize>,
    text: String,
    link: Option<DocumentLink>,
}

pub(super) fn is_markdown(path: &str, language: &str) -> bool {
    language.eq_ignore_ascii_case("markdown")
        || path.rsplit_once('.').is_some_and(|(_, extension)| {
            ["md", "markdown", "mdown", "mkd"]
                .iter()
                .any(|expected| extension.eq_ignore_ascii_case(expected))
        })
}

pub(super) fn prepare_markdown(source: &str, path: &str) -> Option<DocumentPreview> {
    let mut options = ParseOptions::gfm();
    options.constructs.frontmatter = true;
    let document = to_mdast(source, &options).ok()?;
    let folder = match path.rsplit_once(['/', '\\']) {
        Some(("", _)) if path.starts_with('/') => "/",
        Some((parent, _)) => parent,
        None => "",
    };
    let mut definitions = HashMap::new();
    collect_definitions(&document, &mut definitions);
    let mut builder = DocumentBuilder {
        source,
        folder,
        definitions,
        links: Vec::new(),
        seen: HashSet::new(),
    };
    let mut sections = Vec::new();
    let mut headings = HashMap::new();
    let mut counts = HashMap::new();
    let mut rewrites = Vec::new();
    let mut start = 0;
    for child in document.children().into_iter().flatten() {
        let Some(position) = child
            .position()
            .filter(|_| matches!(child, Node::Table(_) | Node::Heading(_)))
        else {
            collect_rewrites(child, &builder.definitions, folder, &mut rewrites);
            continue;
        };
        let body =
            builder.rewrite_text(start..position.start.offset, std::mem::take(&mut rewrites));
        if !body.trim().is_empty() {
            sections.push(DocumentSection::Markdown(body.into()));
        }
        let block = match child {
            Node::Table(table) => DocumentSection::Table(builder.prepare_table(table)),
            Node::Heading(heading) => {
                let (explicit_id, suffix) = explicit_heading_id(child, source).unwrap_or(("", ""));
                let label = child.to_string();
                let label = strip_heading_suffix(&label, suffix);
                let base = if explicit_id.is_empty() {
                    heading_slug(label)
                } else {
                    ComposingNormalizerBorrowed::new_nfc()
                        .normalize(explicit_id)
                        .into_owned()
                };
                if !base.is_empty() {
                    let count = counts.entry(base.clone()).or_insert(0);
                    loop {
                        let id = if *count == 0 {
                            base.clone()
                        } else {
                            format!("{base}-{count}")
                        };
                        *count += 1;
                        if let std::collections::hash_map::Entry::Vacant(slot) = headings.entry(id)
                        {
                            slot.insert(sections.len());
                            break;
                        }
                    }
                }
                let content = match builder.prepare_inline(child) {
                    InlineContent::Text(text) => {
                        literal_caption(strip_heading_suffix(&text, suffix)).into()
                    }
                    InlineContent::Markdown(text) => {
                        strip_heading_suffix(&text, suffix).to_owned().into()
                    }
                };
                DocumentSection::Heading {
                    depth: heading.depth,
                    label: label.to_owned().into(),
                    content,
                }
            }
            _ => unreachable!(),
        };
        sections.push(block);
        start = position.end.offset;
    }
    let body = builder.rewrite_text(start..source.len(), rewrites);
    if !body.trim().is_empty() {
        sections.push(DocumentSection::Markdown(body.into()));
    }
    Some(DocumentPreview {
        sections,
        links: builder.links,
        headings,
    })
}

struct DocumentBuilder<'a> {
    source: &'a str,
    folder: &'a str,
    definitions: HashMap<&'a str, &'a str>,
    links: Vec<DocumentLink>,
    seen: HashSet<DocumentTarget>,
}

impl DocumentBuilder<'_> {
    fn rewrite_text(&mut self, range: Range<usize>, rewrites: Vec<Rewrite>) -> String {
        let mut body = String::with_capacity(range.len());
        let mut start = range.start;
        for rewrite in rewrites {
            body.push_str(&self.source[start..rewrite.range.start]);
            body.push_str(&rewrite.text);
            start = rewrite.range.end;
            if let Some(link) = rewrite.link
                && self.seen.insert(link.target.clone())
            {
                self.links.push(link);
            }
        }
        body.push_str(&self.source[start..range.end]);
        body
    }

    fn prepare_inline(&mut self, node: &Node) -> InlineContent {
        let Some(children) = node.children().filter(|children| !children.is_empty()) else {
            return InlineContent::Text("".into());
        };
        if let [Node::Text(text)] = children.as_slice() {
            return InlineContent::Text(text.value.clone().into());
        }
        let range = children
            .first()
            .and_then(Node::position)
            .zip(children.last().and_then(Node::position))
            .map(|(first, last)| first.start.offset..last.end.offset);
        let Some(range) = range else {
            return InlineContent::Text(node.to_string().into());
        };
        let mut rewrites = Vec::new();
        collect_rewrites(node, &self.definitions, self.folder, &mut rewrites);
        let inline = self.rewrite_text(range, rewrites);
        // Inline text may start with a character that would open a block at the document root.
        InlineContent::Markdown(format!("\u{2060}{inline}").into())
    }

    fn prepare_table(&mut self, table: &Table) -> DocumentTable {
        let rows = table
            .children
            .iter()
            .filter_map(Node::children)
            .map(|cells| cells.iter().map(|cell| self.prepare_inline(cell)).collect())
            .collect();
        DocumentTable {
            align: table.align.clone(),
            rows,
        }
    }
}

fn collect_rewrites(
    node: &Node,
    definitions: &HashMap<&str, &str>,
    folder: &str,
    edits: &mut Vec<Rewrite>,
) {
    let link = match node {
        Node::Link(link) => Some((link.url.as_str(), false, node.to_string())),
        Node::Image(image) => Some((image.url.as_str(), true, image.alt.clone())),
        Node::LinkReference(link) => definitions
            .get(link.identifier.as_str())
            .map(|url| (*url, false, node.to_string())),
        Node::ImageReference(image) => definitions
            .get(image.identifier.as_str())
            .map(|url| (*url, true, image.alt.clone())),
        _ => None,
    };
    if let Some(position) = node.position() {
        let range = position.start.offset..position.end.offset;
        if matches!(node, Node::Yaml(_) | Node::Toml(_)) {
            edits.push(Rewrite {
                range,
                text: String::new(),
                link: None,
            });
            return;
        }
        if let Node::Html(html) = node {
            // Raw HTML can name local paths and load remote resources.
            edits.push(Rewrite {
                range,
                text: if html.value.contains('\n') { "\n" } else { " " }.to_owned(),
                link: None,
            });
            return;
        }
        if let Some((url, image, label)) = link {
            if !image && let Some(target) = browser_link(url) {
                if matches!(node, Node::LinkReference(_)) {
                    let label = literal_caption(&label);
                    // A reference definition can be on the other side of a table.
                    edits.push(Rewrite {
                        range,
                        text: format!("[{label}](<{target}>)"),
                        link: None,
                    });
                    return;
                }
            } else {
                let target = link_destination(folder, url)
                    .filter(|target| !image || matches!(target, DocumentTarget::File { .. }));
                let caption = if label.is_empty() {
                    target
                        .as_ref()
                        .and_then(|target| match target {
                            DocumentTarget::File { path, .. } => {
                                path.rsplit(['/', '\\']).find(|part| !part.is_empty())
                            }
                            DocumentTarget::Heading(fragment) => Some(fragment.as_str()),
                        })
                        .unwrap_or(if image { "" } else { url })
                } else {
                    &label
                };
                let text = literal_caption(caption);
                let label = caption.to_owned();
                edits.push(Rewrite {
                    range,
                    text,
                    link: target.map(|target| DocumentLink { target, label }),
                });
                return;
            }
        }
    }
    if let Some(children) = node.children() {
        for child in children {
            collect_rewrites(child, definitions, folder, edits);
        }
    }
}

fn link_destination(folder: &str, destination: &str) -> Option<DocumentTarget> {
    let (path, fragment) = split_markdown_destination(destination);
    if path.is_empty() {
        return fragment.map(DocumentTarget::Heading);
    }
    if path.starts_with("//") || !gateway_path(path, true) {
        return None;
    }
    Some(DocumentTarget::File {
        path: scoped_path(folder, path).into_owned(),
        fragment,
    })
}

fn explicit_heading_id<'a>(heading: &Node, source: &'a str) -> Option<(&'a str, &'a str)> {
    let Node::Text(tail) = heading.children()?.last()? else {
        return None;
    };
    let position = tail.position.as_ref()?;
    let raw = source
        .get(position.start.offset..position.end.offset)?
        .trim_end();
    let (prefix, id) = raw.strip_suffix('}')?.rsplit_once("{#")?;
    if !prefix.ends_with(char::is_whitespace)
        || id.is_empty()
        || id.len() > 256
        || id
            .chars()
            .any(|ch| ch.is_whitespace() || ch.is_control() || matches!(ch, '{' | '}' | '#'))
    {
        return None;
    }
    Some((id, &raw[prefix.len()..]))
}

fn strip_heading_suffix<'a>(text: &'a str, suffix: &str) -> &'a str {
    let text = text.trim_end();
    text.strip_suffix(suffix).unwrap_or(text).trim_end()
}

fn heading_slug(text: &str) -> String {
    static NON_SLUG: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"[^\p{L}\p{N}\p{M}_\- ]+").unwrap());
    static SEPARATORS: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[ -]+").unwrap());
    let normalized = ComposingNormalizerBorrowed::new_nfc()
        .normalize(text)
        .to_lowercase();
    let slug = NON_SLUG.replace_all(normalized.trim(), "");
    SEPARATORS
        .replace_all(&slug, "-")
        .trim_matches('-')
        .to_owned()
}

fn browser_link(destination: &str) -> Option<Url> {
    Url::parse(destination).ok().filter(|url| {
        matches!(url.scheme(), "http" | "https")
            && url.has_host()
            && url.username().is_empty()
            && url.password().is_none()
    })
}

fn literal_caption(caption: &str) -> String {
    // Character references keep punctuation literal, including GFM autolink markers.
    let mut result = String::with_capacity(caption.len());
    for ch in caption.chars() {
        match ch {
            '\n' | '\r' => result.push(' '),
            ch if ch.is_ascii_punctuation() => {
                result.push_str(&format!("&#{};", ch as u32));
            }
            ch => result.push(ch),
        }
    }
    result
}
