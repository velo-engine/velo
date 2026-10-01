module main

// More features for the native-vs-JavaScript comparison (called from main.v).

struct Counter {
mut:
	n       int
	on_tick fn (n int) = unsafe { nil }
	parent  ?&Counter
}

fn Counter.new(start int) Counter {
	return Counter{
		n: start
	}
}

fn (mut c Counter) tick() {
	c.n++
	if c.on_tick != unsafe { nil } {
		c.on_tick(c.n)
	}
}

type Score = int

fn (s Score) doubled() Score {
	return s * 2
}

type Token = Num | Word

struct Num {
	v int
}

struct Word {
	s string
}

fn (t Token) text() string {
	return match t {
		Num { 'n${t.v}' }
		Word { 'w:${t.s}' }
	}
}

interface Named {
	name string
	greet() string
}

struct Person {
	name string
}

fn (p Person) greet() string {
	return 'hi ${p.name}'
}

const origin = Point{0, 0}
const unit_x = Point{1, 0} + origin

fn fib(n int) int {
	return if n < 2 { n } else { fib(n - 1) + fib(n - 2) }
}

fn kind_of(s string) string {
	return match s {
		'a', 'e', 'i', 'o', 'u' { 'vowel' }
		'' { 'empty' }
		else { 'consonant' }
	}
}

fn log_tick(n int) {
	println('tick ${n}')
}

fn compare_len(a &string, b &string) int {
	return a.len - b.len
}

fn extra() {
	mut c := Counter.new(5)
	c.on_tick = log_tick
	c.tick()
	c.tick()
	mut root := Counter.new(0)
	c.parent = &root
	if p := c.parent {
		println('parent ${p.n}')
	}
	c.parent = none
	println('no parent ${c.parent == none}')

	s := Score(21)
	println('score ${s.doubled()} ${int(s) + 1}')
	tokens := [Token(Num{3}), Word{'go'}]
	println(tokens.map(it.text()).join(' '))

	people := [Named(Person{'ann'}), Person{'bo'}]
	for p in people {
		println('${p.name}: ${p.greet()}')
	}
	println('${unit_x} ${origin} ${fib(15)}')
	println('${kind_of('e')} ${kind_of('z')} ${kind_of('')}')

	raw := r'C:\path\n'
	esc := 'tab\there \u00e9 "q" \'s\''
	println('${raw} ${raw.len} ${esc}')

	mut words := ['ccc', 'a', 'bb']
	words.sort_with_compare(compare_len)
	println(words)
	mut matrix := [][]int{len: 2, init: []int{len: 2}}
	matrix[1][1] = 7
	matrix[0] << 3
	println('${matrix} ${Point{1, 0} == unit_x}')

	mut total := 0
	add := fn [mut total] (x int) int {
		total += x
		return total
	}
	add(2)
	println('closure copy ${add(3)} outer ${total}')
	make_adder := fn (n int) fn (int) int {
		return fn [n] (x int) int {
			return x + n
		}
	}
	plus5 := make_adder(5)
	println('adder ${plus5(10)}')

	mut by_name := map[string]&Counter{}
	by_name['c'] = &c
	by_name['c'].n += 100
	println('by name ${c.n}')

	mut hist := map[int]int{}
	for v in [1, 2, 2, 3, 3, 3] {
		hist[v]++
	}
	println(hist)
	opt_text := if v := hist[9] { 'has ${v}' } else { 'missing' }
	println(opt_text)
	arr := [10, 20, 30]
	if v := arr[1] {
		println('arr[1] ${v}')
	}
	val := arr[5] or { -1 }
	println('safe index ${val}')
}
