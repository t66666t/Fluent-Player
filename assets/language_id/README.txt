Offline language identification profiles

The bundled n-gram data is derived from franc-all:
https://github.com/wooorm/franc
ISO language labels are mapped with:
https://github.com/wooorm/iso-639-3
Both upstream notices are included in this directory.

profiles.json contains 139 language profiles in 27 script groups, filtered and
mapped to the application's translation language catalog. It is loaded locally;
no network request or separate model installation is needed.

SubtitleLanguageIdentifier combines script evidence, frequent-word evidence,
n-gram ranks and nearby subtitle context. Scores are routing heuristics, not
calibrated language probabilities. Short text and related languages can remain
ambiguous. SmartTranslationPolicy controls whether to retain such a fragment or
apply the other-language destination. Translation model language capabilities
are separate from identification coverage.
