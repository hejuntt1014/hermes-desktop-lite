use std::{borrow::Cow, collections::HashMap, ops::Range, path::Path};

use markdown::{ParseOptions, mdast::Node, to_mdast};
use percent_encoding::percent_decode_str;

use crate::media::is_image_file;

pub(super) enum ReplyPart<'a> {
    Text(&'a str),
    File { path: &'a str, label: &'a str },
}

pub(super) fn gateway_path(path: &str, allow_relative: bool) -> bool {
    if path.is_empty() || path.len() > 4096 || path.chars().any(char::is_control) {
        return false;
    }
    path.starts_with('/')
        || path.starts_with("~/")
        || path.starts_with("\\\\")
        || path.starts_with("file://")
        || path.as_bytes().get(1..3).is_some_and(|prefix| {
            path.as_bytes()[0].is_ascii_alphabetic() && matches!(prefix, b":/" | b":\\")
        })
        || (allow_relative && !path.contains(':'))
}

pub(super) fn scoped_path<'a>(cwd: &str, path: &'a str) -> Cow<'a, str> {
    if cwd.is_empty() || gateway_path(path, false) {
        return Cow::Borrowed(path);
    }
    let separator = if cwd.contains('\\') && !cwd.contains('/') {
        '\\'
    } else {
        '/'
    };
    Cow::Owned(format!(
        "{}{separator}{path}",
        cwd.trim_end_matches(['/', '\\'])
    ))
}

pub(super) struct ReplyLink {
    pub path: String,
    pub label: String,
    pub fragment: Option<String>,
}

pub(super) fn split_markdown_destination(destination: &str) -> (&str, Option<String>) {
    let (path, fragment) = destination.split_once('#').unwrap_or((destination, ""));
    let fragment = (!fragment.is_empty()).then(|| {
        percent_decode_str(fragment)
            .decode_utf8()
            .map_or_else(|_| fragment.to_owned(), |text| text.into_owned())
    });
    let path = path.split_once('?').map_or(path, |(path, _)| path);
    (path, fragment)
}

pub(super) fn reply_links(text: &str) -> (Cow<'_, str>, Vec<ReplyLink>) {
    if !text.contains('[') || !text.contains(['.', '/', '\\']) {
        return (Cow::Borrowed(text), Vec::new());
    }
    let Ok(document) = to_mdast(text, &ParseOptions::gfm()) else {
        return (Cow::Borrowed(text), Vec::new());
    };
    let mut definitions = HashMap::new();
    collect_definitions(&document, &mut definitions);
    let mut edits = Vec::new();
    collect_links(&document, &definitions, text, &mut edits);
    if edits.is_empty() {
        return (Cow::Borrowed(text), Vec::new());
    }

    let mut body = String::with_capacity(text.len());
    let mut links = Vec::new();
    let mut start = 0;
    for (range, caption, link) in edits {
        body.push_str(&text[start..range.start]);
        body.push_str(caption);
        start = range.end;
        links.push(link);
    }
    body.push_str(&text[start..]);
    (Cow::Owned(body), links)
}

pub(super) fn preserve_chat_breaks(text: Cow<'_, str>) -> Cow<'_, str> {
    if !text.contains(['\n', '\r']) {
        return text;
    }
    let Ok(document) = to_mdast(&text, &ParseOptions::gfm()) else {
        return text;
    };
    let mut breaks = Vec::new();
    collect_chat_breaks(&document, text.as_bytes(), &mut breaks);
    if breaks.is_empty() {
        return text;
    }
    let mut caption = String::with_capacity(text.len() + breaks.len() * 2);
    let mut start = 0;
    for offset in breaks {
        caption.push_str(&text[start..offset]);
        caption.push_str("  ");
        start = offset;
    }
    caption.push_str(&text[start..]);
    Cow::Owned(caption)
}

fn collect_chat_breaks(node: &Node, source: &[u8], breaks: &mut Vec<usize>) {
    if let Node::Text(text) = node
        && let Some(position) = &text.position
        && let Some(span) = source.get(position.start.offset..position.end.offset)
    {
        breaks.extend(span.iter().enumerate().filter_map(|(index, byte)| {
            let offset = position.start.offset + index;
            (*byte == b'\r' || (*byte == b'\n' && (offset == 0 || source[offset - 1] != b'\r')))
                .then_some(offset)
        }));
    }
    if let Some(children) = node.children() {
        for child in children {
            collect_chat_breaks(child, source, breaks);
        }
    }
}

pub(super) fn collect_definitions<'a>(node: &'a Node, definitions: &mut HashMap<&'a str, &'a str>) {
    if let Node::Definition(definition) = node {
        definitions
            .entry(&definition.identifier)
            .or_insert(&definition.url);
    }
    if let Some(children) = node.children() {
        for child in children {
            collect_definitions(child, definitions);
        }
    }
}

fn collect_links<'a>(
    node: &Node,
    definitions: &HashMap<&str, &str>,
    source: &'a str,
    edits: &mut Vec<(Range<usize>, &'a str, ReplyLink)>,
) {
    let destination = match node {
        Node::Link(link) => Some(link.url.as_str()),
        Node::Image(image) => Some(image.url.as_str()),
        Node::LinkReference(link) => definitions.get(link.identifier.as_str()).copied(),
        Node::ImageReference(image) => definitions.get(image.identifier.as_str()).copied(),
        _ => None,
    };
    if let Some(destination) = destination
        && let (path, fragment) = split_markdown_destination(destination)
        && let Some(filename) = link_filename(path)
        && let Some(position) = node.position()
    {
        let range = position.start.offset..position.end.offset;
        // Preserve the original inline formatting and put the actionable file beside its prose.
        let caption = node
            .children()
            .and_then(|children| {
                let start = children.first()?.position()?.start.offset;
                let end = children.last()?.position()?.end.offset;
                source.get(start..end)
            })
            .unwrap_or("");
        let label = match node {
            Node::Image(image) => image.alt.clone(),
            Node::ImageReference(image) => image.alt.clone(),
            _ => node.to_string(),
        };
        edits.push((
            range,
            caption,
            ReplyLink {
                path: path.to_owned(),
                fragment,
                label: if label.is_empty() {
                    filename.to_owned()
                } else {
                    label
                },
            },
        ));
        return;
    }
    if let Some(children) = node.children() {
        for child in children {
            collect_links(child, definitions, source, edits);
        }
    }
}

fn link_filename(path: &str) -> Option<&str> {
    if path.starts_with("//") {
        return None;
    }
    let filename = path.rsplit(['/', '\\']).next()?;
    if !filename.is_empty()
        && (gateway_path(path, false)
            || (path.starts_with("./") || path.starts_with("../")) && gateway_path(path, true))
    {
        return Some(filename);
    }
    reference(path, true).map(|(_, filename)| filename)
}

pub(super) fn reply_files(text: &str, include_bare_images: bool) -> Vec<ReplyPart<'_>> {
    if !text.contains(['/', '\\']) && !text.contains("MEDIA:") {
        return Vec::new();
    }
    let mut parts = Vec::new();
    let mut start = 0;
    let mut offset = 0;
    let mut fence = None;
    for line in text.split_inclusive('\n') {
        let trimmed = line.trim();
        if let Some(character @ ('`' | '~')) = trimmed.chars().next() {
            let length = trimmed
                .chars()
                .take_while(|current| *current == character)
                .count();
            if length >= 3 {
                match fence {
                    Some((mark, minimum))
                        if mark == character
                            && length >= minimum
                            && trimmed[length..].trim().is_empty() =>
                    {
                        fence = None
                    }
                    None => fence = Some((character, length)),
                    _ => {}
                }
                offset += line.len();
                continue;
            }
        }
        if fence.is_none()
            && !line.starts_with([' ', '\t'])
            && let Some((path, label)) = file_line(trimmed, include_bare_images)
        {
            if start < offset {
                parts.push(ReplyPart::Text(&text[start..offset]));
            }
            parts.push(ReplyPart::File { path, label });
            start = offset + line.len();
        }
        offset += line.len();
    }
    if !parts.is_empty() && start < text.len() {
        parts.push(ReplyPart::Text(&text[start..]));
    }
    parts
}

fn file_line(line: &str, include_bare_images: bool) -> Option<(&str, &str)> {
    if let Some(path) = line.strip_prefix("MEDIA:") {
        let path = unquote(path.trim());
        return reference(path, true);
    }
    if let Some((label, value)) = line
        .strip_prefix('[')
        .and_then(|line| line.split_once("]("))
        && let Some(path) = value.strip_suffix(')')
        && !path.contains(['#', '?', '"', '\''])
        && let Some((path, name)) = reference(unquote(path.trim()), false)
    {
        return Some((path, if label.is_empty() { name } else { label }));
    }
    let (path, label) = reference(line, false)?;
    (include_bare_images || !is_image_file(Path::new(label))).then_some((path, label))
}

fn reference(path: &str, allow_relative: bool) -> Option<(&str, &str)> {
    if !gateway_path(path, allow_relative) {
        return None;
    }
    let name = path.rsplit(['/', '\\']).next()?.trim();
    let (_, ext) = name.rsplit_once('.')?;
    if !(1..=12).contains(&ext.len())
        || !ext
            .chars()
            .all(|character| character.is_ascii_alphanumeric())
    {
        return None;
    }
    Some((path, name))
}

fn unquote(text: &str) -> &str {
    match text.chars().next() {
        Some('<') => text
            .strip_prefix('<')
            .and_then(|text| text.strip_suffix('>'))
            .unwrap_or(text),
        Some(quote @ ('`' | '\'' | '"')) => text
            .strip_prefix(quote)
            .and_then(|text| text.strip_suffix(quote))
            .unwrap_or(text),
        _ => text,
    }
}
