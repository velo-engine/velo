module tests

import velo.core
import velo.render

const en_text = '# English
menu.play = Play
greeting = Hello, {name}!\\nWelcome back
coins.one = {n} coin
coins.other = {n} coins
only_en = English only
'

const vi_text = 'menu.play = Chơi
greeting = Xin chào, {name}!
coins.other = {n} xu
'

fn make_locale() &core.Locale {
	mut l := &core.Locale{}
	l.add_table('en', en_text)
	l.add_table('vi', vi_text)
	l.add_table('pt_BR', 'menu.play = Jogar')
	l.add_table('pt', 'menu.play = Jogar PT\nonly_pt = so pt')
	l.choose_startup_language('', 'en')
	return l
}

fn test_translate_args_and_escapes() {
	mut l := make_locale()
	assert l.language() == 'en' || l.language() == core.normalize_lang(core.system_language()).all_before('-')
	assert l.set_language('en')
	assert l.tr('menu.play') == 'Play'
	assert l.tr_args('greeting', {
		'name': 'An'
	}) == 'Hello, An!\nWelcome back'
	assert l.set_language('vi')
	assert l.tr('menu.play') == 'Chơi'
	assert l.tr('only_en') == 'English only' // falls back to the fallback language
	assert l.tr('nope') == 'nope'
}

fn test_set_language_matching_and_saving() {
	mut l := make_locale()
	l.store = core.Store.from_text('')!
	assert !l.set_language('fr') // no table: nothing changes
	assert l.set_language('vi_VN.UTF-8') // base language matches
	assert l.language() == 'vi'
	assert l.store.get_string('language', '') == 'vi'
	assert l.set_language('pt-BR')
	assert l.tr('menu.play') == 'Jogar'
	assert l.tr('only_pt') == 'so pt' // pt-br -> pt before the fallback
}

fn test_plurals() {
	mut l := make_locale()
	l.set_language('en')
	assert l.tr_n('coins', 1) == '1 coin'
	assert l.tr_n('coins', 5) == '5 coins'
	l.set_language('vi')
	assert l.tr_n('coins', 1) == '1 xu'
	assert core.plural_category('ru', 21) == 'one'
	assert core.plural_category('ru', 3) == 'few'
	assert core.plural_category('ru', 12) == 'many'
	assert core.plural_category('pl', 22) == 'few'
	assert core.plural_category('fr', 0) == 'one'
	assert core.plural_category('ja', 1) == 'other'
}

fn test_startup_language_choice() {
	mut l := &core.Locale{}
	l.add_table('en', 'a = 1')
	l.add_table('vi', 'a = 2')
	l.choose_startup_language('vi', 'en')
	assert l.language() == 'vi' // the saved choice wins
	mut m := &core.Locale{}
	m.add_table('de', 'a = 1')
	m.choose_startup_language('xx', 'xx')
	assert m.language() == 'de' // nothing matches: any table
}

fn test_label_text_key_follows_language() {
	mut s := core.Scene.new('t')
	s.locale = make_locale()
	s.locale.set_language('en')
	mut n := core.Node.new('L')
	s.add(mut n)
	n.add_component(&render.Label{
		text:     'placeholder'
		text_key: 'menu.play'
	})
	s.update(0.016)
	assert n.get_component[render.Label]()?.text == 'Play'
	s.locale.set_language('vi')
	s.update(0.016)
	assert n.get_component[render.Label]()?.text == 'Chơi'
	mut m := core.Node.new('M')
	s.add(mut m)
	m.add_component(&render.Label{
		text:     'keep me'
		text_key: 'unknown.key'
	})
	s.update(0.016)
	assert m.get_component[render.Label]()?.text == 'keep me'
}
