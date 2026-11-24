use icu_normalizer::ComposingNormalizerBorrowed;
use icu_properties::{CodePointSetData, props::DefaultIgnorableCodePoint};

use crate::Error;

pub const MAX_NAME_LEN: usize = 128;

/// Check that a secret name looks like `github/token`: path-like segments of
/// Unicode letters, numbers, `.`, `_`, and `-`, separated by single slashes.
pub fn validate_name(name: &str) -> Result<(), Error> {
    let invalid = |why| Err(Error::InvalidName(name.to_owned(), why));
    if name.is_empty() {
        return invalid("name is empty");
    }
    if name.chars().count() > MAX_NAME_LEN {
        return invalid("name is longer than 128 characters");
    }
    if !name
        .chars()
        .all(|c| is_visible_alphanumeric(c) || matches!(c, '.' | '_' | '-' | '/'))
    {
        return invalid("only letters, digits, `.`, `_`, `-`, and `/` are allowed");
    }
    // Swift compares canonically equivalent names as equal. Store only one
    // spelling so the UI and the vault identify the same items.
    if !ComposingNormalizerBorrowed::new_nfc().is_normalized(name) {
        return invalid("name must use Unicode NFC");
    }
    for segment in name.split('/') {
        if segment.is_empty() {
            return invalid("leading, trailing, or repeated `/`");
        }
        if segment == "." || segment == ".." {
            return invalid("`.` and `..` segments are not allowed");
        }
    }
    Ok(())
}

/// Exclude default-ignorable letters so identifiers stay visible in prompts.
pub(crate) fn is_visible_alphanumeric(c: char) -> bool {
    c.is_alphanumeric() && !CodePointSetData::new::<DefaultIgnorableCodePoint>().contains(c)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_typical_names() {
        for name in [
            "github",
            "github/token",
            "aws/prod/ACCESS_KEY",
            "my-app.v2/api_key",
            "工作/账号２",
            "研发/凭据.v2",
            &"账".repeat(MAX_NAME_LEN),
        ] {
            assert!(validate_name(name).is_ok(), "{name}");
        }
    }

    #[test]
    fn rejects_bad_names() {
        let long = "a".repeat(MAX_NAME_LEN + 1);
        for name in [
            "",
            "/a",
            "a/",
            "a//b",
            "a/../b",
            ".",
            "has space",
            "emoji🔑",
            "工作／账号",
            "工作/\u{202e}账号",
            "\u{3164}",
            "\u{212A}",
            &long,
            &"账".repeat(MAX_NAME_LEN + 1),
        ] {
            assert!(validate_name(name).is_err(), "{name}");
        }
    }
}
