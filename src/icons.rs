use std::borrow::Cow;

use gpui::{AssetSource, SharedString};

pub const FORK: &str = "tabler/git-fork.svg";
pub const COPY: &str = "tabler/copy.svg";
pub const DOWNLOAD: &str = "tabler/download.svg";
pub const ZOOM_IN: &str = "tabler/zoom-in.svg";
pub const ZOOM_OUT: &str = "tabler/zoom-out.svg";
pub const QUESTION: &str = "tabler/message-question.svg";
pub const ANSWER: &str = "tabler/circle-letter-a.svg";
pub const ARROW_DOWN: &str = "tabler/arrow-down.svg";
pub const PENCIL: &str = "tabler/pencil.svg";
pub const REFRESH: &str = "tabler/refresh.svg";
pub const BRANCH: &str = "tabler/git-branch.svg";
pub const PLUS: &str = "tabler/plus.svg";
pub const CHEVRON_DOWN: &str = "tabler/chevron-down.svg";
pub const ARROW_UP: &str = "tabler/arrow-up.svg";
pub const STOP: &str = "tabler/player-stop.svg";
pub const WORLD: &str = "tabler/world.svg";
pub const ACTIVITY: &str = "tabler/activity.svg";
pub const FOLDER_OPEN: &str = "tabler/folder-open.svg";
pub const HASH: &str = "tabler/hash.svg";
pub const DOTS_VERTICAL: &str = "tabler/dots-vertical.svg";
pub const FILE_TEXT: &str = "tabler/file-text.svg";
pub const CLIPBOARD: &str = "tabler/clipboard.svg";
pub const TERMINAL: &str = "tabler/terminal-2.svg";
pub const DESKTOP: &str = "status/desktop.svg";
pub const ZAP: &str = "status/bolt.svg";
pub const PHOTO: &str = "tabler/photo.svg";
pub const MODEL_STAR: &str = "status/model-star.svg";
pub const MODEL_STAR_FILLED: &str = "status/model-star-filled.svg";
pub const LIST_DETAILS: &str = "tabler/list-details.svg";
pub const SIDEBAR_SEARCH: &str = "tabler/search.svg";
pub const SIDEBAR_LEFT: &str = "codicon/layout-sidebar-left.svg";
pub const TAB_CLOSE: &str = "codicon/close.svg";
pub const CHROME_MINIMIZE: &str = "codicon/chrome-minimize.svg";
pub const CHROME_MAXIMIZE: &str = "codicon/chrome-maximize.svg";
pub const CHROME_RESTORE: &str = "codicon/chrome-restore.svg";
pub const CHROME_CLOSE: &str = "codicon/chrome-close.svg";
pub const SEARCH: &str = "codicon/search.svg";
pub const SETTINGS: &str = "codicon/settings-gear.svg";
pub const ADD: &str = "codicon/add.svg";
pub const LINK: &str = "codicon/link.svg";
pub const ROBOT: &str = "codicon/robot.svg";
pub const ARCHIVE: &str = "codicon/archive.svg";
pub const KEBAB: &str = "codicon/kebab-vertical.svg";
pub const PIN: &str = "codicon/pin.svg";
pub const RENAME: &str = "codicon/edit.svg";
pub const MAIL: &str = "codicon/mail.svg";
pub const MAIL_READ: &str = "codicon/mail-read.svg";
pub const CLOUD_DOWNLOAD: &str = "codicon/cloud-download.svg";
pub const LINK_EXTERNAL: &str = "codicon/link-external.svg";
pub const BACK: &str = "codicon/arrow-left.svg";
pub const CLOSE_OTHERS: &str = "codicon/close-all.svg";
pub const RIGHT: &str = "codicon/arrow-right.svg";
pub const CLEAR_ALL: &str = "codicon/clear-all.svg";
pub const DISCUSSION: &str = "codicon/comment-discussion.svg";
pub const FILE: &str = "codicon/file.svg";
pub const FOLDER: &str = "codicon/folder.svg";
pub const FOLDER_OPENED: &str = "codicon/folder-opened.svg";
pub const CHEVRON_RIGHT: &str = "codicon/chevron-right.svg";
pub const ELLIPSIS: &str = "codicon/ellipsis.svg";
pub const EYE: &str = "phosphor/eye-fill.svg";
pub const CLOCK: &str = "tabler/clock.svg";
pub const TASK_CHECK: &str = "status/task-check.svg";
pub const PROFILE_CARD: &str = "status/profile-card.svg";
pub const SESSION_PALETTE: &str = "status/session-palette.svg";
pub const NO_COLOR: &str = "status/no-color.svg";
const LICENSE: &str = "tabler/LICENSE";

const ASSETS: &[(&str, &[u8])] = &[
    (
        "icons/chevron-right.svg",
        include_bytes!("../assets/codicon/chevron-right.svg"),
    ),
    (NO_COLOR, include_bytes!("../assets/status/no-color.svg")),
    (
        SESSION_PALETTE,
        include_bytes!("../assets/status/session-palette.svg"),
    ),
    (
        PROFILE_CARD,
        include_bytes!("../assets/status/profile-card.svg"),
    ),
    (
        TASK_CHECK,
        include_bytes!("../assets/status/task-check.svg"),
    ),
    (CLOCK, include_bytes!("../assets/tabler/clock.svg")),
    (EYE, include_bytes!("../assets/phosphor/eye-fill.svg")),
    (
        "phosphor/LICENSE",
        include_bytes!("../assets/phosphor/LICENSE"),
    ),
    // The same Tabler 3.49.0 outlines used by Hermes Desktop.
    (FORK, include_bytes!("../assets/tabler/git-fork.svg")),
    (COPY, include_bytes!("../assets/tabler/copy.svg")),
    (DOWNLOAD, include_bytes!("../assets/tabler/download.svg")),
    (ZOOM_IN, include_bytes!("../assets/tabler/zoom-in.svg")),
    (ZOOM_OUT, include_bytes!("../assets/tabler/zoom-out.svg")),
    (
        QUESTION,
        include_bytes!("../assets/tabler/message-question.svg"),
    ),
    (
        ANSWER,
        include_bytes!("../assets/tabler/circle-letter-a.svg"),
    ),
    (
        ARROW_DOWN,
        include_bytes!("../assets/tabler/arrow-down.svg"),
    ),
    (PENCIL, include_bytes!("../assets/tabler/pencil.svg")),
    (REFRESH, include_bytes!("../assets/tabler/refresh.svg")),
    (BRANCH, include_bytes!("../assets/tabler/git-branch.svg")),
    (PLUS, include_bytes!("../assets/tabler/plus.svg")),
    (
        CHEVRON_DOWN,
        include_bytes!("../assets/tabler/chevron-down.svg"),
    ),
    (ARROW_UP, include_bytes!("../assets/tabler/arrow-up.svg")),
    (STOP, include_bytes!("../assets/tabler/player-stop.svg")),
    (WORLD, include_bytes!("../assets/tabler/world.svg")),
    (ACTIVITY, include_bytes!("../assets/tabler/activity.svg")),
    (
        FOLDER_OPEN,
        include_bytes!("../assets/tabler/folder-open.svg"),
    ),
    (HASH, include_bytes!("../assets/tabler/hash.svg")),
    (
        DOTS_VERTICAL,
        include_bytes!("../assets/tabler/dots-vertical.svg"),
    ),
    (FILE_TEXT, include_bytes!("../assets/tabler/file-text.svg")),
    (CLIPBOARD, include_bytes!("../assets/tabler/clipboard.svg")),
    (TERMINAL, include_bytes!("../assets/tabler/terminal-2.svg")),
    (DESKTOP, include_bytes!("../assets/status/desktop.svg")),
    (ZAP, include_bytes!("../assets/status/bolt.svg")),
    (PHOTO, include_bytes!("../assets/tabler/photo.svg")),
    (
        MODEL_STAR,
        include_bytes!("../assets/status/model-star.svg"),
    ),
    (
        MODEL_STAR_FILLED,
        include_bytes!("../assets/status/model-star-filled.svg"),
    ),
    (
        LIST_DETAILS,
        include_bytes!("../assets/tabler/list-details.svg"),
    ),
    (LICENSE, include_bytes!("../assets/tabler/LICENSE")),
    (
        SIDEBAR_SEARCH,
        include_bytes!("../assets/tabler/search.svg"),
    ),
];

// Codicons 0.0.45, the same version used by Hermes Desktop.
const CODICONS: &[(&str, &[u8])] = &[
    (
        SIDEBAR_LEFT,
        include_bytes!("../assets/codicon/layout-sidebar-left.svg"),
    ),
    (TAB_CLOSE, include_bytes!("../assets/codicon/close.svg")),
    (
        CHROME_MINIMIZE,
        include_bytes!("../assets/codicon/chrome-minimize.svg"),
    ),
    (
        CHROME_MAXIMIZE,
        include_bytes!("../assets/codicon/chrome-maximize.svg"),
    ),
    (
        CHROME_RESTORE,
        include_bytes!("../assets/codicon/chrome-restore.svg"),
    ),
    (
        CHROME_CLOSE,
        include_bytes!("../assets/codicon/chrome-close.svg"),
    ),
    (SEARCH, include_bytes!("../assets/codicon/search.svg")),
    (
        SETTINGS,
        include_bytes!("../assets/codicon/settings-gear.svg"),
    ),
    (ADD, include_bytes!("../assets/codicon/add.svg")),
    (LINK, include_bytes!("../assets/codicon/link.svg")),
    (ROBOT, include_bytes!("../assets/codicon/robot.svg")),
    (ARCHIVE, include_bytes!("../assets/codicon/archive.svg")),
    (
        KEBAB,
        include_bytes!("../assets/codicon/kebab-vertical.svg"),
    ),
    (PIN, include_bytes!("../assets/codicon/pin.svg")),
    (RENAME, include_bytes!("../assets/codicon/edit.svg")),
    (MAIL, include_bytes!("../assets/codicon/mail.svg")),
    (MAIL_READ, include_bytes!("../assets/codicon/mail-read.svg")),
    (
        CLOUD_DOWNLOAD,
        include_bytes!("../assets/codicon/cloud-download.svg"),
    ),
    (
        LINK_EXTERNAL,
        include_bytes!("../assets/codicon/link-external.svg"),
    ),
    (BACK, include_bytes!("../assets/codicon/arrow-left.svg")),
    (
        CLOSE_OTHERS,
        include_bytes!("../assets/codicon/close-all.svg"),
    ),
    (RIGHT, include_bytes!("../assets/codicon/arrow-right.svg")),
    (CLEAR_ALL, include_bytes!("../assets/codicon/clear-all.svg")),
    (
        DISCUSSION,
        include_bytes!("../assets/codicon/comment-discussion.svg"),
    ),
    (FILE, include_bytes!("../assets/codicon/file.svg")),
    (FOLDER, include_bytes!("../assets/codicon/folder.svg")),
    (
        FOLDER_OPENED,
        include_bytes!("../assets/codicon/folder-opened.svg"),
    ),
    (
        CHEVRON_RIGHT,
        include_bytes!("../assets/codicon/chevron-right.svg"),
    ),
    (ELLIPSIS, include_bytes!("../assets/codicon/ellipsis.svg")),
    (
        "codicon/LICENSE",
        include_bytes!("../assets/codicon/LICENSE"),
    ),
    ("codicon/NOTICE", include_bytes!("../assets/codicon/NOTICE")),
];

pub struct Icons;

impl AssetSource for Icons {
    fn load(&self, path: &str) -> gpui::Result<Option<Cow<'static, [u8]>>> {
        Ok(ASSETS
            .iter()
            .chain(CODICONS)
            .find(|(name, _)| *name == path)
            .map(|(_, bytes)| Cow::Borrowed(*bytes)))
    }

    fn list(&self, path: &str) -> gpui::Result<Vec<SharedString>> {
        Ok(ASSETS
            .iter()
            .chain(CODICONS)
            .filter(|(name, _)| name.starts_with(path))
            .map(|(name, _)| (*name).into())
            .collect())
    }
}
