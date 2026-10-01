module main

// A tour of the V features game code uses. tests/run.ts runs it twice — natively (`v run`) and translated
// to JavaScript by tools/v2js — and the two outputs must be identical.
import math
import strings
import arrays

// ---------- structs ----------

struct Point {
mut:
	x int
	y int
}

fn (a Point) + (b Point) Point {
	return Point{a.x + b.x, a.y + b.y}
}

fn (a Point) == (b Point) bool {
	return a.x == b.x && a.y == b.y
}

fn (p Point) str() string {
	return 'P(${p.x}, ${p.y})'
}

fn (mut p Point) move(dx int, dy int) {
	p.x += dx
	p.y += dy
}

struct Base {
pub mut:
	id   int = 7
	name string
}

fn (b &Base) describe() string {
	return 'base ${b.id} ${b.name}'
}

struct Child {
	Base
mut:
	level int = 1
	pos   Point
	tags  []string
}

@[params]
struct Opts {
	speed f32    = 1.5
	label string = 'none'
}

fn with_opts(n int, o Opts) string {
	return '${n} ${o.speed} ${o.label}'
}

// ---------- enums, sum types, interfaces ----------

enum Dir {
	up
	down
	left = 10
	right
}

fn (d Dir) opposite() Dir {
	return match d {
		.up { .down }
		.down { .up }
		.left { .right }
		.right { .left }
	}
}

@[flag]
enum Perm {
	read
	write
	exec
}

struct Circle {
	r f64
}

struct Rect {
	w f64
	h f64
}

type Shape = Circle | Rect

fn area(s Shape) f64 {
	return match s {
		Circle { math.pi * s.r * s.r }
		Rect { s.w * s.h }
	}
}

interface Speaker {
	speak() string
}

struct Dog {
	name string
}

fn (d Dog) speak() string {
	return '${d.name}: woof'
}

struct Cat {}

fn (c Cat) speak() string {
	return 'meow'
}

// ---------- options, results ----------

fn find_even(xs []int) ?int {
	for x in xs {
		if x % 2 == 0 {
			return x
		}
	}
	return none
}

fn parse_age(s string) !int {
	if s == '' {
		return error('empty')
	}
	n := s.int()
	if n < 0 {
		return error_with_code('negative: ${n}', 42)
	}
	return n
}

fn double_age(s string) !int {
	return parse_age(s)! * 2
}

fn first_even_plus_one(xs []int) ?int {
	e := find_even(xs)?
	return e + 1
}

// ---------- generics, closures, multi-return ----------

fn biggest[T](xs []T) T {
	mut best := xs[0]
	for x in xs {
		if x > best {
			best = x
		}
	}
	return best
}

fn apply(f fn (int) int, x int) int {
	return f(x)
}

fn divmod(a int, b int) (int, int) {
	return a / b, a % b
}

fn make_counter() fn () int {
	mut state := &Point{}
	return fn [mut state] () int {
		state.x++
		return state.x
	}
}

const greeting = 'hello'
const primes = [2, 3, 5, 7, 11]

fn defer_order() string {
	mut log := []string{}
	defer {
		log << 'deferred'
	}
	log << 'body'
	return log.join(',')
}

fn main() {
	// numbers
	println('${7 / 2} ${-7 / 2} ${7 % 3} ${-7 % 3} ${7.0 / 2}')
	a := 255
	println('${u8(a + 1)} ${int(3.9)} ${int(-3.9)} ${f32(3) / 2} ${a >> 2} ${a & 15} ${1 << 10} ${a ^ 0xff}')
	f := 0.1 + 0.2
	g := f32(0.1) + f32(0.2)
	println('${f:.2f} ${g} ${f32(1.0)} ${2.5} ${f64(1000)} ${math.sqrt(2):.4f}')
	println('${42:5}|${42:-5}|${42:05}|${255:x}|${3.14159:.3f}|${-1.5}')
	println('${math.max(3, 8)} ${math.min(2.5, 1.5)} ${math.abs(-4)} ${math.clamp(15, 0, 10)}')

	// strings
	s := '  Hello, World  '
	t := s.trim_space()
	println('[${t}] ${t.len} ${t.to_upper()} ${t.to_lower()}')
	println(t.split(', ').str())
	println('${t.contains('World')} ${t.starts_with('He')} ${t.ends_with('x')} ${t.index('o') or {
		-1
	}}')
	println('${t.replace('l', 'L')} ${t[0..5]} ${t[7..]} ${'ab'.repeat(3)}')
	println('${'a,b,,c'.split(',').len} ${'x=1'.all_after('=')} ${'path/to/file.v'.all_after_last('/')}')
	println('${'42'.int() + 1} ${'3.5'.f64() * 2} ${'abc' < 'abd'} ${greeting.len}')
	mut sb := strings.new_builder(16)
	sb.write_string('built')
	sb.write_string('-')
	sb.write_string('string')
	println(sb.str())
	word := 'héllo'
	println('${word.runes().len} ${word.runes().reverse().string()} ${`A`} ${rune(`é`).str()}')
	println('${'Coin: ' + 5.str()} ${true} ${!true}')

	// arrays
	mut nums := [5, 3, 8, 1]
	nums << 9
	nums << [2, 4]
	nums.insert(0, 100)
	nums.delete(1)
	println(nums.str())
	println('${nums.filter(it > 3)} ${nums.map(it * 2)} ${nums.any(it == 8)} ${nums.all(it > 0)}')
	mut sorted := nums.clone()
	sorted.sort()
	println('${sorted} ${nums.len} ${8 in nums} ${42 !in nums} ${nums.index(8)}')
	sorted.sort(a > b)
	println('${sorted} ${sorted.first()} ${sorted.last()} ${arrays.sum(sorted) or { 0 }}')
	mut grid := [][]int{len: 3, init: []int{len: 2, init: index}}
	grid[1][0] = 9
	println(grid.str())
	zeros := []f32{len: 3}
	println('${zeros} ${primes[2..4]} ${primes.reverse()}')
	mut pts := [Point{1, 2}, Point{3, 4}]
	for mut p in pts {
		p.x *= 10
	}
	pts.sort(a.x > b.x)
	println(pts.map(it.str()).join(' '))

	// maps
	mut ages := map[string]int{}
	ages['bob'] = 30
	ages['alice'] = 25
	ages['carol'] += 5
	ages['bob']++
	println('${ages['bob']} ${ages['nobody']} ${'alice' in ages} ${ages.len} ${ages.keys()}')
	ages.delete('alice')
	for k, v in ages {
		println('  ${k}=${v}')
	}
	mut groups := map[string][]int{}
	groups['odd'] << 1
	groups['odd'] << 3
	groups['even'] << 2
	println('${groups['odd']} ${groups['even'].len} ${groups['none'].len}')
	m := {
		'x': 1.5
		'y': 2.0
	}
	println('${m['x']} ${m['y']} ${m['z'] or { -1.0 }}')

	// structs: value semantics, methods, embedding, operators, params
	mut p1 := Point{1, 2}
	mut p2 := p1
	p2.x = 99
	p1.move(1, 1)
	println('${p1} ${p2} ${p1 + p2} ${p1 == Point{2, 3}} ${p1 != p2}')
	mut c := Child{
		name: 'kid'
		tags: ['a']
	}
	c.id += 1
	c.pos.move(5, 5)
	println('${c.describe()} ${c.level} ${c.pos} ${c.Base.name} ${c.tags}')
	d := Child{
		...c
		level: 9
	}
	println('${d.level} ${d.name} ${c.level}')
	println(with_opts(1))
	println(with_opts(2, speed: 3))
	println(with_opts(3, label: 'fast', speed: 9.5))

	// enums
	dir := Dir.left
	println('${dir} ${dir.opposite()} ${int(Dir.right)} ${Dir.up == .up} ${dir != .left}')
	mut perms := Perm.read | Perm.exec
	println('${perms.has(.read)} ${perms.has(.write)}')
	perms.set(.write)
	println('${perms.has(.write)} ${perms.all(.read | .exec)}')

	// sum types and interfaces
	shapes := [Shape(Circle{1}), Rect{2, 3}]
	for sh in shapes {
		kind := if sh is Circle { 'circle' } else { 'rect' }
		println('${kind} ${area(sh):.2f}')
	}
	speakers := [Speaker(Dog{'rex'}), Cat{}]
	for sp in speakers {
		println(sp.speak())
		if sp is Dog {
			println('  dog named ${sp.name}')
		}
	}

	// options and results
	println('${find_even([1, 3, 4, 6]) or { -1 }} ${find_even([1, 3]) or { -1 }}')
	if e := find_even([7, 10]) {
		println('found ${e}')
	} else {
		println('none')
	}
	println('${first_even_plus_one([2]) or { 0 }} ${first_even_plus_one([1]) or { 0 }}')
	age := parse_age('21') or { 0 }
	bad := parse_age('') or {
		println('error: ${err}')
		-1
	}
	neg := parse_age('-5') or {
		println('error: ${err.msg()} code ${err.code()}')
		-2
	}
	println('${age} ${bad} ${neg} ${double_age('4') or { 0 }} ${double_age('') or { 99 }}')
	if n := parse_age('x7') {
		println('parsed ${n}')
	}

	// generics, closures, multi-return
	println('${biggest([3, 9, 2])} ${biggest([1.5, 0.5])} ${biggest(['b', 'c', 'a'])}')
	offset := 10
	add := fn [offset] (x int) int {
		return x + offset
	}
	println('${apply(add, 5)} ${apply(fn (x int) int {
		return x * x
	}, 7)}')
	q, r := divmod(17, 5)
	mut x, mut y := 1, 2
	x, y = y, x
	println('${q} ${r} ${x} ${y}')
	counter := make_counter()
	counter()
	counter()
	println('counter ${counter()}')
	mut captured := 1
	snap := fn [captured] () int {
		return captured
	}
	captured = 50
	println('snapshot ${snap()} now ${captured}')

	// control flow
	mut total := 0
	outer: for i in 0 .. 5 {
		for j := 0; j < 5; j++ {
			if j > i {
				continue outer
			}
			if i == 4 {
				break outer
			}
			total += j
		}
	}
	println('total ${total}')
	mut k := 0
	for k < 100 {
		k += 17
	}
	grade := match k {
		0...50 { 'low' }
		51, 52, 53 { 'odd' }
		else { 'high ${k}' }
	}

	println('${grade} ${defer_order()}')
	sign := if k > 100 {
		'big'
	} else if k == 102 {
		'exact'
	} else {
		'small'
	}
	println(sign)
	for i := 3; i > 0; i-- {
		print('${i} ')
	}
	println('go')
	for ch in 'abc' {
		print('${ch} ')
	}
	println('')
	for i, v in ['x', 'y'] {
		println('${i}:${v}')
	}
	extra()
}
