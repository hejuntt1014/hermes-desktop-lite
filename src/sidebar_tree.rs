use std::collections::{HashMap, HashSet};

use crate::session::Summary;

pub(super) struct Entry<'a> {
    pub row: &'a Summary,
    pub depth: usize,
    pub last: bool,
}

fn lineage(row: &Summary) -> (&str, &str) {
    let profile = if row.profile.is_empty() {
        "default"
    } else {
        row.profile.as_str()
    };
    let root = if row.lineage_root.is_empty() {
        row.id.as_str()
    } else {
        row.lineage_root.as_str()
    };
    (profile, root)
}

pub(super) fn entries<'a>(rows: &[&'a Summary], preserve_order: bool) -> Vec<Entry<'a>> {
    let continued: HashSet<_> = rows
        .iter()
        .filter(|row| !row.branch_parent.is_empty())
        .map(|row| (lineage(row), row.branch_parent.as_str()))
        .collect();
    let priority = |row: &Summary| {
        (
            !continued.contains(&(lineage(row), row.id.as_str())),
            row.updated_at,
        )
    };
    let mut winners = HashMap::new();
    for (index, row) in rows.iter().enumerate() {
        let candidate = winners.entry(lineage(row)).or_insert(index);
        if priority(row) > priority(rows[*candidate]) {
            *candidate = index;
        }
    }
    let mut survivors: Vec<_> = winners.values().copied().collect();
    survivors.sort_unstable();

    let mut aliases = HashMap::new();
    for row in rows {
        let (profile, root) = lineage(row);
        let winner = winners[&(profile, root)];
        aliases.insert((profile, row.id.as_str()), winner);
        aliases.insert((profile, root), winner);
    }
    let mut children = vec![Vec::new(); rows.len()];
    let mut roots = Vec::new();
    for &index in &survivors {
        let row = rows[index];
        let profile = lineage(row).0;
        match aliases.get(&(profile, row.branch_parent.as_str())).copied() {
            Some(parent) if parent != index => children[parent].push(index),
            _ => roots.push(index),
        }
    }
    for group in &mut children {
        group.sort_by_key(|&index| std::cmp::Reverse(rows[index].updated_at));
    }
    if !preserve_order {
        let mut memo = HashMap::new();
        roots.sort_by_key(|&index| {
            std::cmp::Reverse(group_recency(index, rows, &children, &mut memo))
        });
    }

    let mut output = Vec::with_capacity(survivors.len());
    let mut seen = HashSet::new();
    for root in roots.into_iter().chain(survivors) {
        let mut stack = vec![(root, 0, true)];
        while let Some((index, depth, last)) = stack.pop() {
            if !seen.insert(index) {
                continue;
            }
            output.push(Entry {
                row: rows[index],
                depth,
                last,
            });
            let nested = &children[index];
            stack.extend(
                nested
                    .iter()
                    .enumerate()
                    .rev()
                    .map(|(position, &child)| (child, depth + 1, position + 1 == nested.len())),
            );
        }
    }
    output
}

fn group_recency(
    index: usize,
    rows: &[&Summary],
    children: &[Vec<usize>],
    memo: &mut HashMap<usize, i64>,
) -> i64 {
    if let Some(&cached) = memo.get(&index) {
        return cached;
    }
    let mut newest = rows[index].updated_at;
    memo.insert(index, newest);
    for &child in &children[index] {
        newest = newest.max(group_recency(child, rows, children, memo));
    }
    memo.insert(index, newest);
    newest
}
