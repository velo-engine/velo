module core

// Behavior trees and a small state machine for game AI. Trees are built in code from closures, ticked every frame
// (BehaviorTree component, or call tick yourself), and share a Blackboard of named values.
//
//   tree := core.bt_selector([
//       core.bt_sequence([
//           core.bt_cond(fn (mut bb core.Blackboard) bool { return bb.get_bool('sees_player') }),
//           core.bt_action(fn (mut bb core.Blackboard, dt f32) core.BtStatus { chase(); return .running }),
//       ]),
//       core.bt_action(fn (mut bb core.Blackboard, dt f32) core.BtStatus { patrol(); return .running }),
//   ])
//
// A node returns success, failure or running; a running node is ticked again next time (sequences and selectors
// remember which child was running).

pub enum BtStatus {
	success
	failure
	running
}

// Blackboard — named values the tree's nodes read and write.
pub struct Blackboard {
pub mut:
	nums  map[string]f32
	bools map[string]bool
	strs  map[string]string
	vecs  map[string]Vec2
}

pub fn (b &Blackboard) get_f32(key string) f32 {
	return b.nums[key] or { 0 }
}

pub fn (mut b Blackboard) set_f32(key string, v f32) {
	b.nums[key] = v
}

pub fn (b &Blackboard) get_bool(key string) bool {
	return b.bools[key] or { false }
}

pub fn (mut b Blackboard) set_bool(key string, v bool) {
	b.bools[key] = v
}

pub fn (b &Blackboard) get_string(key string) string {
	return b.strs[key] or { '' }
}

pub fn (mut b Blackboard) set_string(key string, v string) {
	b.strs[key] = v
}

pub fn (b &Blackboard) get_vec2(key string) Vec2 {
	return b.vecs[key] or { Vec2{} }
}

pub fn (mut b Blackboard) set_vec2(key string, v Vec2) {
	b.vecs[key] = v
}

pub interface BtNode {
mut:
	tick(mut bb Blackboard, dt f32) BtStatus
	reset() // forget a running child / timer (called when a parent restarts)
}

pub type BtCondFn = fn (mut bb Blackboard) bool

pub type BtActionFn = fn (mut bb Blackboard, dt f32) BtStatus

// ---------- Leaves ----------

struct BtCond {
	f BtCondFn = unsafe { nil }
}

pub fn bt_cond(f BtCondFn) BtNode {
	return &BtCond{f}
}

fn (mut n BtCond) tick(mut bb Blackboard, _ f32) BtStatus {
	return if n.f(mut bb) { BtStatus.success } else { BtStatus.failure }
}

fn (mut n BtCond) reset() {}

struct BtAction {
	f BtActionFn = unsafe { nil }
}

// bt_action runs `f` every tick; return .running while it is busy.
pub fn bt_action(f BtActionFn) BtNode {
	return &BtAction{f}
}

fn (mut n BtAction) tick(mut bb Blackboard, dt f32) BtStatus {
	return n.f(mut bb, dt)
}

fn (mut n BtAction) reset() {}

struct BtWait {
	seconds f32
mut:
	elapsed f32
}

// bt_wait is running for `seconds`, then succeeds.
pub fn bt_wait(seconds f32) BtNode {
	return &BtWait{
		seconds: seconds
	}
}

fn (mut n BtWait) tick(mut _ Blackboard, dt f32) BtStatus {
	n.elapsed += dt
	if n.elapsed >= n.seconds {
		n.elapsed = 0
		return .success
	}
	return .running
}

fn (mut n BtWait) reset() {
	n.elapsed = 0
}

// ---------- Composites ----------

struct BtSequence {
mut:
	children []BtNode
	current  int
}

// bt_sequence ticks its children in order: fails at the first failure, succeeds when all succeeded. It remembers
// which child was running and continues there (earlier conditions are not checked again; see bt_reactive_sequence).
pub fn bt_sequence(children []BtNode) BtNode {
	return &BtSequence{
		children: children
	}
}

fn (mut n BtSequence) tick(mut bb Blackboard, dt f32) BtStatus {
	for n.current < n.children.len {
		st := n.children[n.current].tick(mut bb, dt)
		if st == .running {
			return .running
		}
		if st == .failure {
			n.reset()
			return .failure
		}
		n.current++
	}
	n.reset()
	return .success
}

fn (mut n BtSequence) reset() {
	n.current = 0
	for mut c in n.children {
		c.reset()
	}
}

struct BtReactiveSequence {
mut:
	children []BtNode
}

// bt_reactive_sequence is a sequence that starts over from its first child every tick (it does not remember which
// child was running), so its leading conditions are checked again each time and can cut a running action short:
// `reactive_sequence([cond(has_target), action(chase)])` stops chasing the moment the target is gone.
pub fn bt_reactive_sequence(children []BtNode) BtNode {
	return &BtReactiveSequence{
		children: children
	}
}

fn (mut n BtReactiveSequence) tick(mut bb Blackboard, dt f32) BtStatus {
	for i in 0 .. n.children.len {
		st := n.children[i].tick(mut bb, dt)
		if st == .running {
			return .running
		}
		if st == .failure {
			n.reset()
			return .failure
		}
	}
	n.reset()
	return .success
}

fn (mut n BtReactiveSequence) reset() {
	for mut c in n.children {
		c.reset()
	}
}

struct BtSelector {
mut:
	children []BtNode
	current  int
}

// bt_selector tries its children in order: succeeds at the first success, fails when all failed. Each tick starts
// over from the first child unless one is running (so a higher-priority child can interrupt a lower one).
pub fn bt_selector(children []BtNode) BtNode {
	return &BtSelector{
		children: children
	}
}

fn (mut n BtSelector) tick(mut bb Blackboard, dt f32) BtStatus {
	for i in 0 .. n.children.len {
		st := n.children[i].tick(mut bb, dt)
		if st == .running {
			if n.current != i && n.current < n.children.len {
				n.children[n.current].reset() // a different child took over
			}
			n.current = i
			return .running
		}
		if st == .success {
			n.reset()
			return .success
		}
	}
	n.reset()
	return .failure
}

fn (mut n BtSelector) reset() {
	n.current = 0
	for mut c in n.children {
		c.reset()
	}
}

// ---------- Decorators ----------

struct BtInverter {
mut:
	child BtNode
}

// bt_inverter swaps success and failure (running stays running).
pub fn bt_inverter(child BtNode) BtNode {
	return &BtInverter{child}
}

fn (mut n BtInverter) tick(mut bb Blackboard, dt f32) BtStatus {
	return match n.child.tick(mut bb, dt) {
		.success { BtStatus.failure }
		.failure { BtStatus.success }
		.running { BtStatus.running }
	}
}

fn (mut n BtInverter) reset() {
	n.child.reset()
}

struct BtSucceeder {
mut:
	child BtNode
}

// bt_succeeder always reports success once its child is done (an optional step).
pub fn bt_succeeder(child BtNode) BtNode {
	return &BtSucceeder{child}
}

fn (mut n BtSucceeder) tick(mut bb Blackboard, dt f32) BtStatus {
	return if n.child.tick(mut bb, dt) == .running { BtStatus.running } else { BtStatus.success }
}

fn (mut n BtSucceeder) reset() {
	n.child.reset()
}

struct BtRepeat {
	times int // 0 = forever
mut:
	child BtNode
	done  int
}

// bt_repeat runs its child again each time it finishes, `times` times (0 = forever, then it is always running);
// it fails as soon as the child fails.
pub fn bt_repeat(times int, child BtNode) BtNode {
	return &BtRepeat{
		times: times
		child: child
	}
}

fn (mut n BtRepeat) tick(mut bb Blackboard, dt f32) BtStatus {
	st := n.child.tick(mut bb, dt)
	if st == .running {
		return .running
	}
	if st == .failure {
		n.reset()
		return .failure
	}
	n.done++
	if n.times > 0 && n.done >= n.times {
		n.reset()
		return .success
	}
	return .running
}

fn (mut n BtRepeat) reset() {
	n.done = 0
	n.child.reset()
}

// ---------- Tree and component ----------

// BehaviorTree — runs a tree on its node every frame. Set the tree and the blackboard from code (a tree is built
// from closures, so it is not part of a .scene file):
//
//   mut bt := node.add_component(&core.BehaviorTree{})
//   bt.set_tree(core.bt_selector([...]))
//   bt.blackboard.set_bool('alert', true)
pub struct BehaviorTree {
	Component
pub mut:
	tree       BtNode     @[hide]
	has_tree   bool       @[hide]
	blackboard Blackboard @[hide]
	status     BtStatus   @[hide] // what the root returned last tick
}

pub fn (mut b BehaviorTree) set_tree(t BtNode) {
	b.tree = t
	b.has_tree = true
}

pub fn (mut b BehaviorTree) update(dt f32) {
	if b.has_tree {
		b.status = b.tree.tick(mut b.blackboard, dt)
	}
}

// ---------- State machine ----------

pub type FsmFn = fn (dt f32)

// FsmState — what to do while in a state; any of the callbacks may be left out.
pub struct FsmState {
pub:
	enter  fn () = unsafe { nil }
	update FsmFn = unsafe { nil } // return the name of the next state by calling Fsm.go() inside it
	exit   fn () = unsafe { nil }
}

// Fsm — a plain finite state machine for game logic: `fsm.add('patrol', FsmState{...})`, `fsm.go('chase')`,
// and `fsm.update(dt)` every frame. Changing state inside a callback is fine: it takes effect at once.
pub struct Fsm {
pub mut:
	states  map[string]FsmState
	current string
	time    f32 // seconds in the current state
}

pub fn (mut f Fsm) add(name string, s FsmState) {
	f.states[name] = s
}

// go leaves the current state (exit), enters `name` (enter) and resets `time`. false: no such state.
pub fn (mut f Fsm) go(name string) bool {
	next := f.states[name] or { return false }
	if cur := f.states[f.current] {
		if cur.exit != unsafe { nil } {
			cur.exit()
		}
	}
	f.current = name
	f.time = 0
	if next.enter != unsafe { nil } {
		next.enter()
	}
	return true
}

pub fn (mut f Fsm) update(dt f32) {
	f.time += dt
	if s := f.states[f.current] {
		if s.update != unsafe { nil } {
			s.update(dt)
		}
	}
}
