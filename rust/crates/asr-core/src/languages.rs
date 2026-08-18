//! Language picker, mirroring the reference app's list (auto + 15 languages).
//! Qwen3-ASR itself supports 30 languages + 22 Chinese dialects; extend as needed.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct LanguageOption {
    pub id: String,
    pub label: String,
}

pub const AUTO: &str = "auto";

pub fn all() -> Vec<LanguageOption> {
    [
        (AUTO, "自动检测 (Auto)"),
        ("Chinese", "中文 (Chinese)"),
        ("Cantonese", "粤语 (Cantonese)"),
        ("English", "English"),
        ("Japanese", "日本語 (Japanese)"),
        ("Korean", "한국어 (Korean)"),
        ("French", "Français (French)"),
        ("German", "Deutsch (German)"),
        ("Spanish", "Español (Spanish)"),
        ("Portuguese", "Português"),
        ("Italian", "Italiano"),
        ("Russian", "Русский (Russian)"),
        ("Arabic", "العربية (Arabic)"),
        ("Thai", "ภาษาไทย (Thai)"),
        ("Vietnamese", "Tiếng Việt (Vietnamese)"),
        ("Indonesian", "Bahasa Indonesia"),
    ]
    .into_iter()
    .map(|(id, label)| LanguageOption { id: id.to_string(), label: label.to_string() })
    .collect()
}

/// Value passed to the model; `None` = let it auto-detect.
pub fn model_value(id: &str) -> Option<String> {
    if id == AUTO { None } else { Some(id.to_string()) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_maps_to_none() {
        assert_eq!(model_value(AUTO), None);
        assert_eq!(model_value("Chinese").as_deref(), Some("Chinese"));
    }

    #[test]
    fn list_matches_reference_app() {
        let all = all();
        assert_eq!(all.len(), 16);
        assert_eq!(all[0].id, AUTO);
    }
}
