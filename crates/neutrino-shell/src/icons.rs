// SPDX-License-Identifier: MPL-2.0
pub fn outline(name: &str) -> &'static str {
    match name {
        "back"=>"m14 5-7 7 7 7", "forward"=>"m10 5 7 7-7 7", "down"=>"m6 9 6 6 6-6", "close"=>"m6 6 12 12M18 6 6 18",
        "plus"=>"M12 5v14M5 12h14", "search"=>"M20 20l-5-5M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14",
        "reload"=>"M20 7v5h-5M19 12a7 7 0 1 0-2 5M20 12l-2-6", "check"=>"m5 12 4 4L19 6", "more"=>"M5 12h.01M12 12h.01M19 12h.01",
        "sidebar"=>"M4 4h16v16H4zM9 4v16", "split"=>"M4 4h16v16H4zM12 4v16", "folder"=>"M3 7V5h7l2 3h9v12H3V7z",
        "appearance"=>"M4 4h16v16H4zM4 9h16M9 9v11",
        "quote"=>"M4 5h6v7H6v7H3v-7l1-7zM14 5h6v7h-4v7h-3v-7l1-7z",
        "bookmark"=>"M6 3h12v18l-6-4-6 4V3z", "history"=>"M3 11a9 9 0 1 1 2 7M3 5v6h6M12 7v5l3 2",
        "download"=>"M12 3v12m-5-5 5 5 5-5M4 16v5h16v-5", "settings"=>"M4 7h16M4 17h16M8 4v6M16 14v6",
        "globe"=>"M3 12h18M12 3c-6 5-6 13 0 18 6-5 6-13 0-18M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18",
        "lock"=>"M7 10V7a5 5 0 0 1 10 0v3M5 10h14v11H5zM12 14v3", "shield"=>"M12 3 3 7v6c0 4 9 8 9 8s9-4 9-8V7L12 3zm-5 9 3 3 6-6",
        "pin"=>"m9 3 8 0-1 6 3 4H5l3-4 1-6M12 13v8", "edit"=>"m4 16 12-12 4 4L8 20H4v-4M13 7l4 4",
        "sun"=>"M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1 1M18 18l1 1M5 19l1-1M18 6l1-1",
        "moon"=>"M20 15A9 9 0 0 1 9 4a9 9 0 1 0 11 11", "spark"=>"m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5L12 3z",
        "undo"=>"M4 5v6h6M4 11a8 8 0 1 1 2 7", "focus"=>"M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5", "kebab"=>"M12 5h.01M12 12h.01M12 19h.01", "menu"=>"M4 7h16M4 12h16M4 17h16", "home"=>"M4 11 12 4l8 7v9h-5v-6h-6v6H4z", "copy"=>"M9 9h11v11H9zM5 15H4V4h11v1", "arrow"=>"M5 12h14m-5-5 5 5-5 5", "user"=>"M12 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8M4 21v-3a6 6 0 0 1 6-5h4a6 6 0 0 1 6 5v3",
        "grid"=>"M3 3h7v7H3zM14 3h7v7h-7zM3 14h7v7H3zM14 14h7v7h-7z", "external"=>"M14 3h7v7M21 3 10 14M10 3H3v18h18v-7",
        "grip"=>"M8 5h.01M16 5h.01M8 12h.01M16 12h.01M8 19h.01M16 19h.01", "key"=>"M14 3a7 7 0 1 0 7 7 7 7 0 0 0-7-7M9 15l-6 6H1v-3l6-6M17 7h.01",
        "book"=>"M3 4h7l2 2 2-2h7v16h-7l-2 2-2-2H3V4zM12 6v16", "activity"=>"M2 12h5l3-8 4 16 3-8h5", "camera"=>"M3 7h5l2-3h4l2 3h5v14H3V7zM8 14a4 4 0 1 0 8 0 4 4 0 0 0-8 0", "plug"=>"M8 3v5M16 3v5M6 8h12v4a6 6 0 0 1-12 0V8zM12 18v4",
        "volume"=>"M4 9h4l5-4v14l-5-4H4V9zM16 9a4 4 0 0 1 0 6M19 6a8 8 0 0 1 0 12", "muted"=>"M4 9h4l5-4v14l-5-4H4V9zM17 9l5 6M22 9l-5 6",
        "code"=>"m8 7-5 5 5 5M16 7l5 5-5 5M14 4l-4 16", "print"=>"M6 9V3h12v6M6 17H3V9h18v8h-3M6 14h12v7H6z",
        "pip"=>"M3 5h18v14H3zM12 12h7v5h-7z", "trash"=>"M4 7h16M10 11v6M14 11v6M5 7l1 14h12l1-14M9 7V4h6v3", "minus"=>"M5 12h14",
        "pause"=>"M8 5v14M16 5v14", "play"=>"M7 4v16l13-8z", "panel"=>"M4 4h16v16H4zM15 4v16", "star"=>"m12 3 2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z",
        "window"=>"M3 7h14v13H3zM7 7V4h14v13h-4", "reader"=>"M5 5h14M5 9h14M5 13h14M5 17h9", "terminal"=>"M3 4h18v16H3zM7 9l3 3-3 3M12 15h5", "feed"=>"M5 11a8 8 0 0 1 8 8M5 5a14 14 0 0 1 14 14M6 18h.01",
        "rewind"=>"m11 5-7 7 7 7M20 5l-7 7 7 7", "fast-forward"=>"m13 5 7 7-7 7M4 5l7 7-7 7",
        _=>"M5 5h14v14H5z"
    }
}

pub fn path(name: &str, pack: &str) -> &'static str {
    if pack == "precision" {
        match name {
            "back" => "M15 4 7 12l8 8",
            "forward" => "m9 4 8 8-8 8",
            "search" => "M3 3h12v12H3zM15 15l6 6",
            "reload" => "M20 10V4h-6M20 4H4v16h16v-6",
            "folder" => "M3 5h7l3 3h8v12H3z",
            "settings" => "M3 6h18M3 18h18M7 3v6M17 15v6",
            "user" => "M8 3h8v8H8zM4 21v-6h16v6",
            "globe" => "M3 3h18v18H3zM3 12h18M12 3v18",
            "moon" => "M20 15H9V4H4v16h16z",
            "book" => "M3 4h18v16H3zM12 4v16",
            "grid" => "M3 3h6v6H3zM15 3h6v6h-6zM3 15h6v6H3zM15 15h6v6h-6z",
            _ => outline(name),
        }
    } else {
        outline(name)
    }
}
pub fn valid_path(path: &str) -> bool {
    !path.is_empty()
        && path.len() <= 4096
        && path.starts_with(['M', 'm'])
        && path
            .bytes()
            .all(|b| b.is_ascii_digit() || b"MmLlHhVvCcSsQqTtAaZz., +-\n\t".contains(&b))
}
