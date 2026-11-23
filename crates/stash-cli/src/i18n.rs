//! Human-facing CLI messages. English source text is also the fallback.

use std::collections::HashMap;
use std::fmt::{Display, Write};
use std::sync::OnceLock;

use clap::Command;
use clap::builder::StyledStr;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Language {
    English,
    SimplifiedChinese,
}

impl Language {
    fn from_locale(locale: &str) -> Self {
        let locale = locale
            .split(['.', '@'])
            .next()
            .unwrap_or_default()
            .replace('_', "-")
            .to_ascii_lowercase();
        match locale.as_str() {
            "zh" | "zh-cn" | "zh-sg" | "zh-hans" => Self::SimplifiedChinese,
            _ if locale.starts_with("zh-hans-") => Self::SimplifiedChinese,
            _ => Self::English,
        }
    }

    fn current() -> Self {
        static LANGUAGE: OnceLock<Language> = OnceLock::new();
        *LANGUAGE.get_or_init(|| {
            ["STASH_LANG", "LC_ALL", "LC_MESSAGES", "LANG"]
                .into_iter()
                .filter_map(|name| std::env::var(name).ok())
                .find(|value| !value.trim().is_empty())
                .map_or(Self::English, |value| Self::from_locale(value.trim()))
        })
    }
}

fn chinese() -> &'static HashMap<String, String> {
    static MESSAGES: OnceLock<HashMap<String, String>> = OnceLock::new();
    MESSAGES.get_or_init(|| {
        serde_json::from_str(include_str!("../locales/zh-Hans.json"))
            .expect("the bundled Simplified Chinese catalog is valid JSON")
    })
}

pub fn text(english: &str) -> &str {
    match Language::current() {
        Language::English => english,
        Language::SimplifiedChinese => chinese()
            .get(english)
            .map(String::as_str)
            .unwrap_or(english),
    }
}

/// Format named placeholders without interpreting any text supplied by callers.
pub fn message(english: &str, values: &[(&str, &dyn Display)]) -> String {
    let mut template = text(english);
    let mut output = String::new();
    while let Some((before, rest)) = template.split_once('{') {
        output.push_str(before);
        let Some((name, after)) = rest.split_once('}') else {
            output.push('{');
            output.push_str(rest);
            return output;
        };
        if let Some((_, value)) = values.iter().find(|(key, _)| *key == name) {
            write!(output, "{value}").expect("writing to a String cannot fail");
        } else {
            output.push('{');
            output.push_str(name);
            output.push('}');
        }
        template = after;
    }
    output.push_str(template);
    output
}

pub fn localize_help(command: Command) -> Command {
    match Language::current() {
        Language::English => command,
        Language::SimplifiedChinese => chinese_help(command),
    }
}

fn translate(help: Option<&StyledStr>) -> Option<&'static str> {
    chinese()
        .get(help?.to_string().as_str())
        .map(String::as_str)
}

fn chinese_help(mut command: Command) -> Command {
    if let Some(about) = translate(command.get_about()) {
        command = command.about(about);
    }
    if let Some(about) = translate(command.get_long_about()) {
        command = command.long_about(about);
    }
    if let Some(after_help) = translate(command.get_after_help()) {
        command = command.after_help(after_help);
    }
    if let Some(after_help) = translate(command.get_after_long_help()) {
        command = command.after_long_help(after_help);
    }
    command
        .mut_args(|mut arg| {
            if let Some(help) = translate(arg.get_help()) {
                arg = arg.help(help);
            }
            if let Some(help) = translate(arg.get_long_help()) {
                arg = arg.long_help(help);
            }
            arg
        })
        .mut_subcommands(chinese_help)
        .subcommand_help_heading("子命令")
        .help_template("{about-with-newline}\n用法：{usage}\n\n{all-args}{after-help}")
}

#[cfg(test)]
mod tests {
    use super::{Language, chinese};

    #[test]
    fn reads_multiline_translations_from_the_bundled_catalog() {
        let example = "Example:\n  stash inject -i config.tpl.yml -o config.yml";
        assert_eq!(
            chinese()[example],
            "示例：\n  stash inject -i config.tpl.yml -o config.yml"
        );
    }

    #[test]
    fn recognizes_simplified_chinese_locale_variants() {
        for value in ["zh", "zh_CN.UTF-8", "zh-Hans-CN", "zh_SG", "zh-CN@pinyin"] {
            assert!(Language::from_locale(value) == Language::SimplifiedChinese);
        }
        for value in ["en_US.UTF-8", "fr", "zh_TW", "zh-Hant", "C"] {
            assert!(Language::from_locale(value) == Language::English);
        }
    }
}
