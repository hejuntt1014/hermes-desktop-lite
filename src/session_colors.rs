use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionTitleColor {
    Red,
    Orange,
    Gold,
    Olive,
    Green,
    Jade,
    Teal,
    Blue,
    Indigo,
    Purple,
    Magenta,
    Rose,
}

impl SessionTitleColor {
    pub const PALETTE: [[Self; 6]; 2] = [
        [
            Self::Red,
            Self::Orange,
            Self::Gold,
            Self::Olive,
            Self::Green,
            Self::Jade,
        ],
        [
            Self::Teal,
            Self::Blue,
            Self::Indigo,
            Self::Purple,
            Self::Magenta,
            Self::Rose,
        ],
    ];

    // Swatches are the Desktop PROFILE_SWATCHES palette (HSL 68% 58%, 30° steps).
    // The middle value applies the same hue to title text at a readable contrast.
    pub fn style(self) -> (&'static str, u32, u32) {
        match self {
            Self::Red => ("红色", 0xad3544, 0xdd4b4b),
            Self::Orange => ("橙色", 0xa24d20, 0xdd944b),
            Self::Gold => ("黄色", 0x796800, 0xdddd4b),
            Self::Olive => ("黄绿色", 0x59701e, 0x94dd4b),
            Self::Green => ("绿色", 0x317341, 0x4bdd4b),
            Self::Jade => ("翡翠绿", 0x1b6b52, 0x4bdd94),
            Self::Teal => ("青色", 0x196a76, 0x4bdddd),
            Self::Blue => ("蓝色", 0x2a5f9a, 0x4b94dd),
            Self::Indigo => ("靛蓝", 0x4848a7, 0x4b4bdd),
            Self::Purple => ("紫色", 0x70459e, 0x944bdd),
            Self::Magenta => ("品红", 0x99437f, 0xdd4bdd),
            Self::Rose => ("玫瑰色", 0xa53865, 0xdd4b94),
        }
    }
}
