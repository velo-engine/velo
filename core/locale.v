module core

import os

// Locale — the game's text in several languages, shared by every scene through `scene.locale`.
//
// One text file per language, `locales/<code>.txt` in the assets (code in lower case: `en`, `vi`, `pt-br`):
//
//   # comment
//   menu.play = Play
//   coins.one = {n} coin          (plural forms: .zero .one .few .many .other, picked by the language's rules)
//   coins.other = {n} coins
//   greeting = Hello, {name}!\nWelcome back.     (\n \t \\ escapes)
//
// App loads every `locales/*.txt` asset, picks the saved language (`language` in scene.store), else the system's,
// else Config.language. In code: `c.scene().locale.tr('menu.play')`, `.tr_n('coins', 3)`, `.set_language('vi')`.
// A Label with `text_key` set shows its translation and follows language changes by itself.
@[heap]
pub struct Locale {
mut:
	tables map[string]map[string]string // language -> key -> text
	lang   string
	warned map[string]bool
pub mut:
	fallback string = 'en' // used for keys the current language lacks
	// Saves the chosen language ('language') when set (App sets it to the scene store).
	store &Store = unsafe { nil }
	// Counts changes of language or tables; components compare it to know when to refresh their text.
	version int
}

// normalize_lang: 'pt_BR.UTF-8' -> 'pt-br'.
pub fn normalize_lang(code string) string {
	mut c := code.all_before('.').all_before('@').replace('_', '-').to_lower().trim_space()
	if c == 'c' || c == 'posix' {
		c = ''
	}
	return c
}

// parse_locale_text reads the `key = text` format.
pub fn parse_locale_text(text string) map[string]string {
	mut out := map[string]string{}
	for line in text.split_into_lines() {
		l := line.trim_space()
		if l == '' || l.starts_with('#') {
			continue
		}
		k, v := l.split_once('=') or { continue }
		out[k.trim_space()] = unescape_locale(v.trim_space())
	}
	return out
}

fn unescape_locale(s string) string {
	if !s.contains('\\') {
		return s
	}
	mut out := []u8{cap: s.len}
	mut i := 0
	for i < s.len {
		if s[i] == `\\` && i + 1 < s.len {
			i++
			match s[i] {
				`n` { out << `\n` }
				`t` { out << `\t` }
				else { out << s[i] }
			}
		} else {
			out << s[i]
		}
		i++
	}
	return out.bytestr()
}

// add_table adds (or replaces) the texts of a language from file text.
pub fn (mut l Locale) add_table(lang string, text string) {
	l.tables[normalize_lang(lang)] = parse_locale_text(text)
	l.version++
}

pub fn (mut l Locale) remove_table(lang string) {
	l.tables.delete(normalize_lang(lang))
	l.version++
}

// languages: the codes that have a table, sorted.
pub fn (l &Locale) languages() []string {
	mut keys := l.tables.keys()
	keys.sort()
	return keys
}

pub fn (l &Locale) language() string {
	return l.lang
}

// resolve_language picks the table for a wanted code: exact ('pt-br'), else its base ('pt'), else ''.
pub fn (l &Locale) resolve_language(code string) string {
	c := normalize_lang(code)
	if c in l.tables {
		return c
	}
	base := c.all_before('-')
	if base in l.tables {
		return base
	}
	return ''
}

// set_language switches language (and saves the choice). false when no table matches the code (nothing changes).
pub fn (mut l Locale) set_language(code string) bool {
	found := l.resolve_language(code)
	if found == '' {
		return false
	}
	l.apply(found)
	if l.store != unsafe { nil } {
		mut st := l.store
		st.set_string('language', found)
	}
	return true
}

// apply switches without saving (used for the startup choice).
fn (mut l Locale) apply(code string) {
	if l.lang != code {
		l.lang = code
		l.version++
	}
}

// choose_startup_language: the saved language, else the system's, else `default_lang`, else the fallback, else
// any table. Does not write the store.
pub fn (mut l Locale) choose_startup_language(saved string, default_lang string) {
	for c in [saved, system_language(), default_lang, l.fallback] {
		found := l.resolve_language(c)
		if found != '' {
			l.apply(found)
			return
		}
	}
	langs := l.languages()
	if langs.len > 0 {
		l.apply(langs[0])
	}
}

// system_language reads the user's language from the environment ('' when it is not set, e.g. on phones and the
// web, where App passes Config.language).
pub fn system_language() string {
	for name in ['LC_ALL', 'LC_MESSAGES', 'LANG', 'LANGUAGE'] {
		v := os.getenv(name)
		if v != '' {
			c := normalize_lang(v.all_before(':'))
			if c != '' {
				return c
			}
		}
	}
	return ''
}

// find returns the text of a key in the current language, else in the fallback; none when neither has it.
pub fn (l &Locale) find(key string) ?string {
	if t := l.tables[l.lang] {
		if s := t[key] {
			return s
		}
		// 'pt-br' falls back to 'pt' before the fallback language
		base := l.lang.all_before('-')
		if base != l.lang {
			if s := l.tables[base][key] {
				return s
			}
		}
	}
	if t := l.tables[l.fallback] {
		if s := t[key] {
			return s
		}
	}
	return none
}

pub fn (l &Locale) has(key string) bool {
	_ := l.find(key) or { return false }
	return true
}

// tr returns the text of a key; a missing key gives the key itself (and is reported once on stderr).
pub fn (mut l Locale) tr(key string) string {
	return l.find(key) or {
		if key !in l.warned {
			l.warned[key] = true
			eprintln('[velo] missing text "${key}" (language ${l.lang})')
		}
		key
	}
}

// tr_args translates and replaces `{name}` with args[name].
pub fn (mut l Locale) tr_args(key string, args map[string]string) string {
	return format_locale(l.tr(key), args)
}

// tr_n picks the plural form for `n` (`key.one`, `key.other`, ...), falling back to `key.other`, then `key`,
// and replaces `{n}` with the number.
pub fn (mut l Locale) tr_n(key string, n int) string {
	cat := plural_category(l.lang, n)
	for k in ['${key}.${cat}', '${key}.other', key] {
		if s := l.find(k) {
			return format_locale(s, {
				'n': n.str()
			})
		}
	}
	return l.tr(key)
}

fn format_locale(text string, args map[string]string) string {
	if args.len == 0 || !text.contains('{') {
		return text
	}
	mut out := text
	for k, v in args {
		out = out.replace('{${k}}', v)
	}
	return out
}

// plural_category: 'zero' | 'one' | 'few' | 'many' | 'other' for a whole number, for the common languages.
pub fn plural_category(lang string, n int) string {
	base := lang.all_before('-')
	count := if n < 0 { -n } else { n }
	return match base {
		'ja', 'zh', 'ko', 'vi', 'th', 'id', 'ms', 'lo', 'my', 'km' {
			'other'
		}
		'fr', 'pt' {
			if count == 0 || count == 1 { 'one' } else { 'other' }
		}
		'ru', 'uk', 'be' {
			if count % 10 == 1 && count % 100 != 11 {
				'one'
			} else if count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 12 || count % 100 > 14) {
				'few'
			} else {
				'many'
			}
		}
		'pl' {
			if count == 1 {
				'one'
			} else if count % 10 >= 2 && count % 10 <= 4 && (count % 100 < 12 || count % 100 > 14) {
				'few'
			} else {
				'many'
			}
		}
		else {
			if count == 1 { 'one' } else { 'other' }
		}
	}
}
