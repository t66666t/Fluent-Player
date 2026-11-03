//! Native word boundaries only. No text rewriting or fabricated timestamps.
use lindera::{dictionary::load_dictionary, mode::Mode, segmenter::Segmenter};
use serde_json::{json, Value};
use std::{borrow::Cow, ffi::{c_char, CStr, CString}, panic::catch_unwind, sync::OnceLock};
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

static JAPANESE: OnceLock<Result<Segmenter, String>> = OnceLock::new();
static KOREAN: OnceLock<Result<Segmenter, String>> = OnceLock::new();

fn segmenter(language: &str) -> Result<&'static Segmenter, String> {
    let (slot, uri) = match language {
        "ja" => (&JAPANESE, "embedded://ipadic"),
        "ko" => (&KOREAN, "embedded://ko-dic"),
        _ => return Err("Unsupported native tokenizer language".into()),
    };
    slot.get_or_init(|| load_dictionary(uri)
        .map(|dictionary| Segmenter::new(Mode::Normal, dictionary, None))
        .map_err(|e| e.to_string())).as_ref().map_err(Clone::clone)
}

fn units(text: &str, language: &str) -> Result<Value, String> {
    // Normalize for dictionary lookup and retain an exact grapheme-to-original
    // map. In particular, Hangul Jamo and Japanese combining dakuten may occupy
    // different byte / UTF-16 lengths before and after NFC.
    let mut normalized = String::new();
    let mut mapping = Vec::new();
    for (original, grapheme) in text.grapheme_indices(true) {
        let start = normalized.len();
        normalized.extend(grapheme.nfc());
        mapping.push((start, normalized.len(), original, original + grapheme.len()));
    }
    let tokens = segmenter(language)?.segment(Cow::Borrowed(normalized.as_str())).map_err(|e| e.to_string())?;
    let mut offsets: Vec<(usize, usize)> = Vec::new();
    let spaced_korean = language == "ko" && text.chars().any(char::is_whitespace);
    for token in tokens {
        let normalized_start = token.byte_start;
        let normalized_end = token.byte_end;
        if normalized_start >= normalized_end || normalized_end > normalized.len() ||
            !normalized.is_char_boundary(normalized_start) || !normalized.is_char_boundary(normalized_end) {
            return Err("Tokenizer returned an invalid UTF-8 range".into());
        }
        if !normalized[normalized_start..normalized_end].chars().any(char::is_alphanumeric) { continue; }
        let first = mapping.partition_point(|&(_, end, _, _)| end <= normalized_start);
        let last = mapping.partition_point(|&(start, _, _, _)| start < normalized_end) - 1;
        let start = mapping[first].2;
        let end = mapping[last].3;
        if let Some(previous) = offsets.last_mut() {
            if start < previous.1 { previous.1 = previous.1.max(end); continue; }
        }
        // Korean display units preserve existing eojeol spacing. With no
        // spaces, the dictionary's morphological boundaries remain available.
        if spaced_korean {
            if let Some(last) = offsets.last_mut() {
                if last.1 == start { last.1 = end; continue; }
            }
        }
        offsets.push((start, end));
    }
    Ok(json!({"version": 1, "units": offsets.into_iter().map(|(start, end)| {
        let normalized: String = text[start..end].nfc().filter(|c| c.is_alphanumeric() || *c == '\'').collect();
        json!({"text": normalized, "start": text[..start].encode_utf16().count(),
            "end": text[..end].encode_utf16().count()})
    }).collect::<Vec<_>>()}))
}

/// The returned UTF-8 JSON is owned by Rust and must use fluent_asr_text_free.
/// Panics and malformed input never unwind across the C ABI.
#[no_mangle]
pub unsafe extern "C" fn fluent_asr_text_tokenize(text: *const c_char, language: *const c_char) -> *mut c_char {
    let result = catch_unwind(|| {
        if text.is_null() || language.is_null() { return Err("Null tokenizer input".to_owned()); }
        let text = CStr::from_ptr(text).to_str().map_err(|e| e.to_string())?;
        let language = CStr::from_ptr(language).to_str().map_err(|e| e.to_string())?;
        if text.len() > 65536 { return Err("Tokenizer input is too large".to_owned()); }
        units(text, language)
    }).unwrap_or_else(|_| Err("Native tokenizer failed".into()));
    let value = result.unwrap_or_else(|error| json!({"error": error}));
    CString::new(value.to_string()).map(CString::into_raw).unwrap_or(std::ptr::null_mut())
}

#[no_mangle]
pub unsafe extern "C" fn fluent_asr_text_free(value: *mut c_char) {
    if !value.is_null() { drop(CString::from_raw(value)); }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn japanese_offsets_preserve_utf16_and_mixed_words() {
        let text = "😀東京大学でPythonを使います。";
        let result = units(text, "ja").unwrap();
        assert!(result["units"].as_array().unwrap().iter().any(|u| u["text"] == "Python"));
        for unit in result["units"].as_array().unwrap() {
            let start = unit["start"].as_u64().unwrap() as usize;
            let end = unit["end"].as_u64().unwrap() as usize;
            assert!(start >= 2 && end > start && end <= text.encode_utf16().count());
        }
    }
    #[test]
    fn korean_preserves_eojeol_without_rewriting_spaces() {
        let result = units("한국어를  공부합니다. Python도 좋아요.", "ko").unwrap();
        let words: Vec<_> = result["units"].as_array().unwrap().iter().map(|u| u["text"].as_str().unwrap()).collect();
        assert_eq!(words, ["한국어를", "공부합니다", "Python도", "좋아요"]);
    }
    #[test]
    fn canonical_equivalents_map_back_to_original_graphemes() {
        for (text, language) in [("😀カ\u{3099}ッツ", "ja"), ("한국어를 배워요", "ko")] {
            let value = units(text, language).unwrap();
            let utf16: Vec<_> = text.encode_utf16().collect();
            assert!(!value["units"].as_array().unwrap().is_empty());
            for word in value["units"].as_array().unwrap() {
                let start = word["start"].as_u64().unwrap() as usize;
                let end = word["end"].as_u64().unwrap() as usize;
                let original = String::from_utf16(&utf16[start..end]).unwrap();
                let clean: String = original.nfc().filter(|c| c.is_alphanumeric() || *c == '\'').collect();
                assert_eq!(clean, word["text"].as_str().unwrap());
            }
        }
    }
}
